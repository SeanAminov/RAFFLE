-- Studio-only development controls.
--
-- This module is required ONLY when RunService:IsStudio() is true, and the DEV remote it
-- listens on is likewise only created in Studio. In production the remote does not exist,
-- so there is no permissive path to share with the real ones -- a forged DevAction has
-- nothing to arrive at.
--
-- Forcing a ball sets a one-shot override consumed by the very next roll. The resulting
-- record is stamped `forced = true` and the reveal renders it as a DEV result, so a forced
-- outcome can never be mistaken for, or presented as, a natural one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BallCatalog = require(Shared:WaitForChild("BallCatalog"))
local MutationCatalog = require(Shared:WaitForChild("MutationCatalog"))
local Net = require(Shared:WaitForChild("Net"))
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))

local GameState = require(script.Parent:WaitForChild("GameState"))
local BallService = require(script.Parent:WaitForChild("BallService"))
local BallInventoryService = require(script.Parent:WaitForChild("BallInventoryService"))
local RollService = require(script.Parent:WaitForChild("RollService"))
local ScoreService = require(script.Parent:WaitForChild("ScoreService"))
local UpgradeService = require(script.Parent:WaitForChild("UpgradeService"))
local FeedService = require(script.Parent:WaitForChild("FeedService"))
local DropperService = require(script.Parent:WaitForChild("DropperService"))

local DevTools = {}

local handlers = {}

handlers.FORCE_BALL = function(player, ballId)
	if type(ballId) ~= "string" or not BallCatalog.get(ballId) then
		return
	end
	local state = GameState.get(player)
	if state then
		state.forcedBallId = ballId
		RollService.roll(player, { skipRateLimit = true })
	end
end

-- Forces the NEXT roll to carry this mutation. The record still stores the mutation's TRUE
-- base and effective odds for the player's current rank, and is stamped forcedMutation, so a
-- forced result is always rendered as forced and never as a natural one.
handlers.FORCE_MUTATION = function(player, mutationId)
	if type(mutationId) ~= "string" then
		return
	end
	local mutation = MutationCatalog.get(mutationId)
	if mutation.id == "NONE" then
		return
	end
	local state = GameState.get(player)
	if state then
		state.forcedMutationId = mutation.id
		RollService.roll(player, { skipRateLimit = true })
	end
end

handlers.TOGGLE_HOPPER_RECORDING = function(player)
	DropperService.setRecording(not DropperService.isRecording())
	print(("[RAFFLE DEV] hopper recording = %s"):format(tostring(DropperService.isRecording())))
end

handlers.HOPPER_REPORT = function(player)
	print(DevTools.hopperReport())
end

handlers.GRANT_TICKETS = function(player, amount)
	if type(amount) ~= "number" then
		return
	end
	GameState.addTickets(player, math.clamp(math.floor(amount), 0, 1e9))
	GameState.push(player)
end

handlers.ROLL = function(player)
	RollService.roll(player, { skipRateLimit = true })
end

handlers.TOGGLE_FEED = function(player)
	local state = GameState.get(player)
	if state then
		state.feedPaused = not state.feedPaused
		GameState.push(player)
	end
end

handlers.CLEAR_BALLS = function(player)
	BallService.removeAllOwnedBy(player)
	GameState.push(player)
end

handlers.RESET_UPGRADES = function(player)
	local state = GameState.get(player)
	if state then
		for id in pairs(state.ranks) do
			state.ranks[id] = 0
		end
		state.autoRoll = false
		GameState.push(player)
	end
end

handlers.DUMP_STATS = function(player)
	local state = GameState.get(player)
	print(("[RAFFLE DEV] tickets=%d luck=%.2f stored=%d variants=%d active=%d rolls=%d autoRoll=%s")
		:format(state.tickets, GameState.luck(player), GameState.storedCount(player),
			GameState.storedVariantCount(player), state.activeBalls, state.rolls,
			tostring(state.autoRoll)))
	print(("[RAFFLE DEV] feed=%.2fs auto=%.2fs mutRank=%d sorter=%s mode=%s reserved=%d")
		:format(GameState.feedInterval(player), GameState.autoRollInterval(player),
			GameState.mutationRank(player), tostring(GameState.prizeSorter(player)),
			GameState.selectionMode(player),
			BallInventoryService.reservationCount(state.inventory)))
	print(("[RAFFLE DEV] mutated rolls=%d forcedMutations=%d settledMutated=%d")
		:format(RollService.stats.mutated, RollService.stats.forcedMutations,
			ScoreService.stats.settledMutated))
	print("[RAFFLE DEV] roll:", RollService.stats.rolled,
		"rateBlocked:", RollService.stats.blockedByRate, "forced:", RollService.stats.forced)
	print("[RAFFLE DEV] balls:", BallService.stats.spawned, "drained:", BallService.stats.drained,
		"oob:", BallService.stats.outOfBounds, "settled:", ScoreService.stats.settled,
		"fallbackSettled:", ScoreService.stats.settledByFallback)
	print("[RAFFLE DEV] tickets from hits:", ScoreService.stats.ticketsFromHits,
		"from drains:", ScoreService.stats.ticketsFromDrains)
	print("[RAFFLE DEV] purchases:", UpgradeService.stats.purchased,
		"released:", FeedService.stats.released)
end

-- Cohort summary of recorded releases. Reported per cohort rather than pooled, because the
-- whole point of the measurement is that the turnarounds behave differently from the cruise.
function DevTools.hopperReport(): string
	local samples = DropperService.samples
	local cohorts = {}
	local order = { "leftTurnaround", "travelLeft", "centre", "travelRight", "rightTurnaround" }
	for _, name in ipairs(order) do
		cohorts[name] = { n = 0, offset = 0, maxOffset = 0, speed = 0, maxSpeed = 0,
			lateral = 0, maxLateral = 0, blocked = 0, contact = 0, contacts = 0 }
	end

	for _, sample in ipairs(samples) do
		local bucket = cohorts[sample.cohort]
		if bucket then
			bucket.n += 1
			bucket.offset += sample.spawnOffset
			bucket.maxOffset = math.max(bucket.maxOffset, sample.spawnOffset)
			bucket.speed += sample.peakSpeed
			bucket.maxSpeed = math.max(bucket.maxSpeed, sample.peakSpeed)
			local lateral = math.abs(sample.initialVelocity.Magnitude)
			bucket.lateral += lateral
			bucket.maxLateral = math.max(bucket.maxLateral, lateral)
			if not sample.clearAtSpawn then
				bucket.blocked += 1
			end
			if sample.firstContactAt then
				bucket.contact += sample.firstContactAt
				bucket.contacts += 1
			end
		end
	end

	local lines = { ("[RAFFLE DEV] hopper: %d releases recorded"):format(#samples) }
	table.insert(lines, "  cohort              n   offset  maxOff   |v0|  max|v0|  peak.25  maxPeak  1stHit  blocked")
	for _, name in ipairs(order) do
		local b = cohorts[name]
		if b.n > 0 then
			table.insert(lines, ("  %-18s %3d  %6.3f  %6.3f  %5.1f  %7.1f  %7.1f  %7.1f  %6.3f  %7d")
				:format(name, b.n, b.offset / b.n, b.maxOffset, b.lateral / b.n, b.maxLateral,
					b.speed / b.n, b.maxSpeed,
					b.contacts > 0 and (b.contact / b.contacts) or -1, b.blocked))
		else
			table.insert(lines, ("  %-18s   0"):format(name))
		end
	end
	table.insert(lines, ("  deferred(mouth blocked)=%d longestDeferral=%.3fs overlapChecks=%d")
		:format(FeedService.stats.deferredBlockedMouth, FeedService.stats.longestDeferral,
			DropperService.stats.overlapChecks))
	return table.concat(lines, "\n")
end

DevTools.BRIDGE_NAME = "RaffleDevBridge"

-- Fixed command set rather than an eval hook: every operation a test may perform is named
-- here and returns plain, serialisable data.
function DevTools.dispatch(command: string, a: any, b: any)
	local player = Players:GetPlayers()[1]
	local state = player and GameState.get(player)

	if command == "ping" then
		return { ok = true, players = #Players:GetPlayers(), hasState = state ~= nil }

	elseif command == "setRank" and state then
		state.ranks[a] = b
		if not GameState.autoRollUnlocked(player) then
			state.autoRoll = false
		end
		GameState.push(player)
		return { ok = true, rank = state.ranks[a] }

	elseif command == "setTickets" and state then
		state.tickets = a
		GameState.push(player)
		return { ok = true, tickets = state.tickets }

	elseif command == "setAutoRoll" and state then
		state.autoRoll = a and true or false
		GameState.push(player)
		return { ok = true, autoRoll = state.autoRoll }

	elseif command == "setTuning" then
		local previous = PinballTuning[a]
		PinballTuning[a] = b
		return { ok = true, key = a, from = previous, to = PinballTuning[a] }

	elseif command == "getTuning" then
		return { ok = true, value = PinballTuning[a] }

	elseif command == "record" then
		DropperService.setRecording(a and true or false)
		return { ok = true, recording = DropperService.isRecording(), samples = #DropperService.samples }

	elseif command == "hopper" then
		return { ok = true, report = DevTools.hopperReport(), samples = #DropperService.samples }

	elseif command == "hopperRaw" then
		-- Flat, serialisable rows so the caller can do its own statistics.
		local rows = {}
		for _, s in ipairs(DropperService.samples) do
			table.insert(rows, {
				cohort = s.cohort, localX = s.localX, localVX = s.localVX,
				toTurnaround = s.toTurnaround, spawnOffset = s.spawnOffset,
				v0 = s.initialVelocity.Magnitude, peak = s.peakSpeed,
				clear = s.clearAtSpawn, firstContactAt = s.firstContactAt,
				firstContact = s.firstContact,
			})
		end
		return { ok = true, rows = rows }

	elseif command == "stats" and state then
		return {
			ok = true,
			tickets = state.tickets,
			luck = GameState.luck(player),
			mutationRank = GameState.mutationRank(player),
			prizeSorter = GameState.prizeSorter(player),
			feedInterval = GameState.feedInterval(player),
			autoRollInterval = GameState.autoRollInterval(player),
			stored = GameState.storedCount(player),
			storedVariants = GameState.storedVariantCount(player),
			reservations = BallInventoryService.reservationCount(state.inventory),
			selectionMode = GameState.selectionMode(player),
			hasEligibleBalls = GameState.hasEligibleBalls(player),
			activeBalls = state.activeBalls,
			rolls = state.rolls,
			ranks = state.ranks,
			roll = RollService.stats,
			ball = BallService.stats,
			score = ScoreService.stats,
			feed = FeedService.stats,
			upgrade = UpgradeService.stats,
			dropper = DropperService.stats,
		}

	elseif command == "inventory" and state then
		-- Flat, serialisable view of storage: what is owned, what the hopper may take, and
		-- what is in flight. Replaces the old "queue" dump, which no longer exists.
		local stacks = {}
		for key, count in pairs(state.inventory.stacks) do
			local policy = BallInventoryService.policy(state.inventory, key)
			table.insert(stacks, {
				key = key, count = count,
				autoFeed = policy.autoFeed, hold = policy.hold,
				favorite = policy.favorite, keepAtLeast = policy.keepAtLeast,
			})
		end
		table.sort(stacks, function(a, b) return a.key < b.key end)
		local eligible = {}
		for _, row in ipairs(BallInventoryService.autoEligible(state.inventory)) do
			table.insert(eligible, { key = row.key, available = row.available })
		end
		local reservations = {}
		for dropId, entry in pairs(state.inventory.reservations) do
			table.insert(reservations, {
				dropId = dropId, key = entry.snapshot.variantKey, state = entry.state,
				ballValueUpgrade = entry.snapshot.ballValueUpgrade,
				prospectiveValue = entry.snapshot.prospectiveValue,
			})
		end
		table.sort(reservations, function(a, b) return a.dropId < b.dropId end)
		local conservationOk, rows = BallInventoryService.conservation(state.inventory)
		return { ok = true, stacks = stacks, eligible = eligible, reservations = reservations,
			total = BallInventoryService.totalStored(state.inventory),
			dropNext = state.inventory.dropNext,
			selectionMode = GameState.selectionMode(player),
			conservationOk = conservationOk, conservation = rows }

	elseif command == "setPolicy" and state then
		local ok, policy, reason = BallInventoryService.setPolicy(state.inventory, a, b)
		GameState.touchInventory(player)
		GameState.push(player)
		return { ok = ok, policy = policy, reason = reason }

	elseif command == "grantBalls" and state then
		-- Forces inventory for a test. DEV-forced balls are excluded from achievements and
		-- permanent progression by the event pipeline, so this cannot fake real progress.
		local added = BallInventoryService.credit(state.inventory, a, b or 1)
		GameState.touchInventory(player)
		GameState.push(player)
		return { ok = added > 0, added = added,
			stack = BallInventoryService.stack(state.inventory, a) }

	elseif command == "dropNext" and state then
		local ok, reason = BallInventoryService.requestDropNext(state.inventory, a)
		GameState.push(player)
		return { ok = ok, reason = reason, dropNext = state.inventory.dropNext }

	elseif command == "purchase" and player then
		local ok, reason = UpgradeService.purchase(player, a, b)
		return { ok = ok, reason = reason, ranks = state and state.ranks }

	elseif command == "forceBall" and state then
		state.forcedBallId = a
		if b then state.forcedMutationId = b end
		local ok, reason = RollService.roll(player, { skipRateLimit = true })
		return { ok = ok, reason = reason }

	elseif command == "roll" and player then
		local ok, reason = RollService.roll(player, { skipRateLimit = true })
		return { ok = ok, reason = reason }

	elseif command == "clearBalls" and player then
		BallService.removeAllOwnedBy(player)
		return { ok = true }

	elseif command == "reset" and state then
		-- A TRUE fresh session, not just zeroed counters. Balls in play are removed FIRST so
		-- their settlements cannot land after the reset and hand the "new" session a
		-- starting balance; the starter-bonus flag and roll count go back to their initial
		-- values; and storage is preloaded exactly as GameState.onPlayerAdded does it.
		-- Without all four, a second scripted session inherits the first one's income and its
		-- pacing numbers are meaningless.
		BallService.removeAllOwnedBy(player)
		for id in pairs(state.ranks) do state.ranks[id] = 0 end
		state.autoRoll = false
		state.tickets = 0
		state.inventory = BallInventoryService.new(player.UserId)
		state.inventoryRevision = 0
		state.bumperHits = 0
		state.starterBonusGiven = false
		state.rolls = 0
		state.forcedBallId = nil
		state.forcedMutationId = nil
		state.lastAcceptedPurchaseToken = nil
		RollService.preload(player)
		GameState.push(player)
		return { ok = true, tickets = state.tickets, stored = GameState.storedCount(player) }
	end

	return { ok = false, reason = "unknown command " .. tostring(command) }
end

function DevTools.start(netFolder: Folder)
	if not RunService:IsStudio() then
		return
	end
	local remote = netFolder:FindFirstChild(Net.DEV_ACTION)
	if not remote or not remote:IsA("RemoteEvent") then
		return
	end
	-- STUDIO-ONLY MEASUREMENT BRIDGE.
	--
	-- A command-bar / MCP context runs in its OWN Lua VM: `require` there returns fresh module
	-- instances and `_G` is a different table, so a test driven that way silently operates on
	-- an empty parallel copy of the game. A BindableFunction is the one thing that crosses
	-- into THIS VM, so measurement commands are dispatched through it and return plain data.
	--
	-- This sits inside the same IsStudio guard as the rest of the file and behind the DEV
	-- remote's existence check, so it cannot be created in production.
	local bridge = Instance.new("BindableFunction")
	bridge.Name = DevTools.BRIDGE_NAME
	bridge.OnInvoke = function(command, a, b)
		return DevTools.dispatch(command, a, b)
	end
	bridge.Parent = game:GetService("ServerStorage")

	remote.OnServerEvent:Connect(function(player, action, value)
		-- Belt and braces: even though the remote cannot exist outside Studio, refuse to
		-- act if this somehow runs elsewhere.
		if not RunService:IsStudio() then
			return
		end
		local handler = type(action) == "string" and handlers[action]
		if handler then
			local ok, err = pcall(handler, player, value)
			if not ok then
				warn("[RAFFLE DEV] " .. tostring(action) .. " failed: " .. tostring(err))
			end
		end
	end)
end

return DevTools
