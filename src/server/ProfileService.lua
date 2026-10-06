--!strict
-- WHEN a profile is read and written, and the guarantee that only one write is ever in
-- flight for a player.
--
-- ProfileSchema says what a profile is; ProfileStore says where it lives; this says when.
--
-- ---------------------------------------------------------------------------------------
-- ONE SERIALIZED PIPELINE PER PLAYER
--
-- Every save for a player goes through `flush`, which holds a per-player `saving` flag. A
-- save requested while one is in flight does not queue up behind it -- it sets `pending` and
-- returns. When the in-flight save finishes it notices `pending` and runs exactly once more.
--
-- That bound matters: an autosave, a purchase and a disconnect can all ask to save within the
-- same second, and three overlapping UpdateAsync calls on one key is precisely the
-- interleaving the lease exists to prevent. One in flight, at most one queued, never more.
--
-- ---------------------------------------------------------------------------------------
-- DIRTY, NOT WRITE-THROUGH
--
-- Nothing writes a DataStore per roll or per drop. Gameplay mutates the loaded profile in
-- memory and calls `markDirty`; the autosave loop coalesces whatever accumulated into one
-- snapshot. At ~67 rolls a minute a write-through design would issue more than a request per
-- second per player and be throttled into uselessness.
--
-- ---------------------------------------------------------------------------------------
-- FAIL CLOSED
--
-- A player whose profile could not be READ is marked `blocked`: they play a session that is
-- never saved, rather than being handed a blank writable profile that would overwrite their
-- real one on the first autosave. Losing a session is recoverable. Overwriting a save is not.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProfileSchema = require(Shared:WaitForChild("ProfileSchema"))

local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))
local GameState = require(script.Parent:WaitForChild("GameState"))

local ProfileService = {}

-- Autosave cadence. JITTER IS NOT COSMETIC: a fixed interval synchronises every server in the
-- game onto the same DataStore second, which turns a comfortable request rate into a
-- thundering herd. The spread is a third of the interval.
ProfileService.AUTOSAVE_SECONDS = 60
ProfileService.AUTOSAVE_JITTER = 20

ProfileService.stats = {
	loaded = 0, created = 0, blocked = 0, quarantined = 0,
	saves = 0, saveFailures = 0, coalesced = 0,
	reservationsRecovered = 0,
}

-- player -> { profile, sessionId, dirty, saving, pending, blocked, nextSave }
local sessions: { [Player]: any } = {}
local random = Random.new()
local nextSessionId = 0

local function newSessionId(userId: number): string
	nextSessionId += 1
	return ("%s:%d:%d"):format(tostring(game.JobId), userId, nextSessionId)
end

function ProfileService.sessionOf(player: Player)
	return sessions[player]
end

function ProfileService.isBlocked(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.blocked == true
end

-- ---------------------------------------------------------------- apply / capture

-- Writes a loaded profile INTO the live session record. Called once, before the player is
-- allowed to do anything, so no gameplay can race the load.
function ProfileService.applyToState(state: any, profile: any)
	state.tickets = profile.tickets
	state.rebirths = profile.rebirth.count
	state.tokens = profile.rebirth.tokens
	for id, rank in pairs(profile.ranks) do
		state.ranks[id] = rank
	end

	local inventory = state.inventory
	for key, count in pairs(profile.inventory.stacks) do
		inventory.stacks[key] = count
	end
	for key, policy in pairs(profile.inventory.policies) do
		inventory.policies[key] = policy
	end
	for key, record in pairs(profile.collection) do
		inventory.collection[key] = {
			firstSeen = record.firstSeen,
			rolled = record.rolled,
			settled = record.settled,
		}
	end

	-- SAVED RESERVATIONS COME BACK AS STOCK. Their physical Instances cannot have survived
	-- the server that died holding them, so the only honest thing is to return the balls.
	-- They are added to the stack directly rather than re-created as reservations: a
	-- reservation with no ball attached would never resolve.
	local recovered = 0
	for _, entry in ipairs(profile.inventory.reservations) do
		local current = inventory.stacks[entry.variantKey] or 0
		inventory.stacks[entry.variantKey] = current + entry.count
		recovered += entry.count
	end
	if recovered > 0 then
		ProfileService.stats.reservationsRecovered += recovered
	end

	state.achievements = {
		progress = profile.achievements.progress,
		unlocked = profile.achievements.unlocked,
		claimed = profile.achievements.claimed,
	}
	state.settings = profile.settings
	state.rolls = profile.stats.rolls
	state.bumperHits = profile.stats.bumperHits
	state.lifetimeSettled = profile.stats.settled
	state.lifetimeTickets = profile.stats.ticketsEarned
	state.sessions = profile.stats.sessions + 1

	return recovered
end

-- ---------------------------------------------------------------- load

function ProfileService.load(player: Player): (string, string?)
	local state = GameState.get(player)
	if not state then
		return "failed", "no session state"
	end

	local sessionId = newSessionId(player.UserId)
	local now = os.time()
	local status, profile, err = ProfileStore.load(player.UserId, sessionId, ProfileSchema, now)

	if status == "failed" or status == "locked" or status == "quarantine" then
		-- BLOCKED. The player plays; nothing is ever written for them this session.
		sessions[player] = {
			sessionId = sessionId, blocked = true, reason = status, profile = nil,
			dirty = false, saving = false, pending = false,
		}
		if status == "quarantine" then
			ProfileService.stats.quarantined += 1
		end
		ProfileService.stats.blocked += 1
		warn(("[RAFFLE] ProfileService: %s is playing UNSAVED (%s: %s)")
			:format(player.Name, status, tostring(err)))
		return status, err
	end

	if status == "new" then
		ProfileService.stats.created += 1
	else
		ProfileService.stats.loaded += 1
	end

	ProfileService.applyToState(state, profile)
	sessions[player] = {
		sessionId = sessionId,
		profile = profile,
		blocked = false,
		dirty = status == "new",
		saving = false,
		pending = false,
		nextSave = os.clock() + ProfileService.AUTOSAVE_SECONDS
			+ random:NextNumber(0, ProfileService.AUTOSAVE_JITTER),
	}
	GameState.touchInventory(player)
	GameState.push(player)
	return status, nil
end

-- ---------------------------------------------------------------- dirty / save

-- The leave path, called by Bootstrap AFTER the player's in-flight balls have been returned
-- to storage. Blocking on purpose: the player is going, so it is safe to wait for the write,
-- and not waiting would let the session be dropped mid-save.
function ProfileService.release(player: Player): boolean
	local saved = ProfileService.flush(player, true)
	sessions[player] = nil
	return saved
end

function ProfileService.markDirty(player: Player)
	local session = sessions[player]
	if session and not session.blocked then
		session.dirty = true
	end
end

-- THE only write path. Serialized per player by the `saving` flag; at most one further save
-- is remembered while one is in flight.
function ProfileService.flush(player: Player, release: boolean?): boolean
	local session = sessions[player]
	if not session or session.blocked then
		return false
	end
	local state = GameState.get(player)
	if not state then
		return false
	end

	if session.saving then
		-- Coalesce rather than queue. One remembered follow-up is enough: whatever changes
		-- during the in-flight save will be captured by that single extra pass.
		session.pending = true
		ProfileService.stats.coalesced += 1
		return false
	end

	session.saving = true
	local ok = false
	repeat
		session.pending = false
		local now = os.time()
		local profile = ProfileSchema.fromSession(state, now)
		profile.createdAt = (session.profile and session.profile.createdAt) or now
		profile.updatedAt = now
		session.profile = profile

		local saved, err = ProfileStore.save(player.UserId, session.sessionId, profile, now, release)
		ProfileService.stats.saves += 1
		if saved then
			session.dirty = false
			ok = true
		else
			ProfileService.stats.saveFailures += 1
			warn(("[RAFFLE] ProfileService: save failed for %s: %s"):format(player.Name, tostring(err)))
			-- A failed save leaves `dirty` set, so the next autosave tries again rather than
			-- assuming the data reached the store.
		end
	until not session.pending
	session.saving = false
	return ok
end

-- ---------------------------------------------------------------- lifecycle

local started = false

function ProfileService.start(requestedMode: string?)
	if started then
		return
	end
	started = true

	-- MOCK IN STUDIO, ALWAYS, unless something explicitly asks for the isolated dev store.
	-- Production is not selectable here at all: ProfileStore refuses it under IsStudio, and
	-- this never passes it.
	local mode = requestedMode
	if not mode then
		mode = RunService:IsStudio() and ProfileStore.MODE_MOCK or ProfileStore.MODE_PRODUCTION
	end
	local ok, err = ProfileStore.setMode(mode)
	if not ok then
		warn(("[RAFFLE] ProfileService: %s; falling back to Mock"):format(tostring(err)))
		ProfileStore.setMode(ProfileStore.MODE_MOCK)
	end

	-- Autosave, jittered per player.
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for player, session in pairs(sessions) do
				if not session.blocked and session.dirty and now >= (session.nextSave or 0) then
					session.nextSave = now + ProfileService.AUTOSAVE_SECONDS
						+ random:NextNumber(0, ProfileService.AUTOSAVE_JITTER)
					task.spawn(ProfileService.flush, player, false)
				end
			end
		end
	end)

	-- NO PlayerRemoving CONNECTION HERE, deliberately. The leave sequence has a required
	-- ORDER -- refund the player's in-flight balls, THEN save -- and a connection made here
	-- would race the one that does the refunding. Bootstrap owns that order and calls
	-- `release` below. See ProfileService.release.

	-- SHUTDOWN. Every live profile is written CONCURRENTLY -- one task each -- because
	-- BindToClose has a hard budget and saving twenty players in series would exhaust it.
	game:BindToClose(function()
		local pending = 0
		local done = 0
		for player in pairs(sessions) do
			pending += 1
			task.spawn(function()
				ProfileService.flush(player, true)
				done += 1
			end)
		end
		local deadline = os.clock() + 25
		while done < pending and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

-- ---------------------------------------------------------------- diagnostics

function ProfileService.report(player: Player): string
	local session = sessions[player]
	if not session then
		return "no profile session"
	end
	if session.blocked then
		return ("BLOCKED (%s) -- this session will not be saved"):format(tostring(session.reason))
	end
	local bytes = session.profile and ProfileSchema.estimateBytes(session.profile) or -1
	return ("mode=%s dirty=%s saving=%s bytes=%d variants=%d")
		:format(ProfileStore.mode(), tostring(session.dirty), tostring(session.saving),
			bytes, (function()
				local n = 0
				for _ in pairs(session.profile and session.profile.collection or {}) do n += 1 end
				return n
			end)())
end

return ProfileService
