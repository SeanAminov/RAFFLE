--!strict
-- Sends a player their own inventory, coalesced.
--
-- ---------------------------------------------------------------------------------------
-- WHY THIS IS NOT A PUSH-ON-CHANGE SYSTEM
--
-- At 67 rolls a minute -- 133 with Auto Speed maxed -- firing a remote per credit would be
-- more than two packets a second per player, every one of them carrying a single incremented
-- number. Instead the inventory is mutated freely and this module DIFFS it on a timer.
--
-- The diff is against THIS MODULE'S OWN last-sent copy, not against a change list the
-- inventory reports. That is the important choice: a change list can be forgotten at a call
-- site and the client silently desyncs forever. A diff cannot miss anything, because it
-- re-derives the truth every flush. It costs one pass over the discovered variants -- 24
-- today, a few hundred at any plausible catalog size -- five times a second.
--
-- ---------------------------------------------------------------------------------------
-- REVISIONS, AND WHY THE CLIENT CAN ALWAYS RECOVER
--
-- Every flush that finds changes bumps a revision and sends `{ from, to, changed }`. The
-- client applies a delta ONLY if `from` matches the revision it currently holds. Any gap --
-- a dropped packet, a late join, a rejoin -- fails that check, and the client asks for a full
-- snapshot instead. There is no way to end up quietly holding a wrong number.
--
-- ---------------------------------------------------------------------------------------
-- WHAT IS SENT
--
-- One row per DISCOVERED variant. Undiscovered variants are deliberately absent: the client
-- already has the full catalog and renders those as silhouettes, so sending them would be
-- transmitting data the client can derive. Discovery is permanent, so a row persists at
-- count 0 -- that is how "discovered, none owned" is expressed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local GameState = require(script.Parent:WaitForChild("GameState"))
local BallInventoryService = require(script.Parent:WaitForChild("BallInventoryService"))

local InventoryReplicator = {}

-- Five times a second. Fast enough that a count visibly ticks up while the panel is open,
-- slow enough that a maxed Auto Speed still produces one packet rather than three.
InventoryReplicator.FLUSH_INTERVAL = 0.2

-- Past this many changed rows a delta stops being cheaper than the truth, so a full snapshot
-- is sent instead. Prevents a pathological case (a fresh profile load touching every variant)
-- from producing a delta larger than the snapshot it replaces.
InventoryReplicator.MAX_DELTA_ROWS = 12

InventoryReplicator.stats = {
	fullSnapshots = 0,
	deltas = 0,
	rowsSent = 0,
	flushesWithNoChange = 0,
	resyncRequests = 0,
}

-- player -> { revision, sent = { [key] = row }, subscribed = boolean }
local tracked: { [Player]: any } = {}
local remote: RemoteEvent? = nil

-- ---------------------------------------------------------------- rows

-- The client-visible shape of one variant. Deliberately flat and readable rather than
-- abbreviated: 24 rows of eight fields is a rounding error on the wire, and short keys would
-- make every future reader of this file guess.
local function buildRow(inventory, key: string)
	local record = inventory.collection[key]
	if not record then
		return nil
	end
	local policy = BallInventoryService.policy(inventory, key)
	return {
		count = inventory.stacks[key] or 0,
		rolled = record.rolled,
		settled = record.settled,
		firstSeen = record.firstSeen,
		autoFeed = policy.autoFeed,
		hold = policy.hold,
		favorite = policy.favorite,
		keepAtLeast = policy.keepAtLeast,
	}
end

local function rowsEqual(a, b): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.count == b.count
		and a.rolled == b.rolled
		and a.settled == b.settled
		and a.firstSeen == b.firstSeen
		and a.autoFeed == b.autoFeed
		and a.hold == b.hold
		and a.favorite == b.favorite
		and a.keepAtLeast == b.keepAtLeast
end

InventoryReplicator.buildRowForTest = buildRow
InventoryReplicator.rowsEqualForTest = rowsEqual

-- Every discovered variant, as rows. This is the whole truth; deltas are derived from it.
local function snapshotRows(inventory)
	local rows = {}
	for key in pairs(inventory.collection) do
		rows[key] = buildRow(inventory, key)
	end
	return rows
end

InventoryReplicator.snapshotRowsForTest = snapshotRows

-- ---------------------------------------------------------------- sending

local function sendFull(player: Player, entry, rows)
	entry.revision += 1
	entry.sent = rows
	local count = 0
	for _ in pairs(rows) do
		count += 1
	end
	InventoryReplicator.stats.fullSnapshots += 1
	InventoryReplicator.stats.rowsSent += count
	if remote then
		remote:FireClient(player, {
			full = true,
			revision = entry.revision,
			variants = rows,
		})
	end
end

-- THE DECISION, as a pure function: given what the client holds and what is true now, what
-- should go out? Returns "none" | "delta" | "full", the changed rows, and how many.
--
-- Pure on purpose. This is the part with the interesting behaviour -- when a delta becomes
-- more expensive than the truth, and what happens if a row vanishes -- and keeping it free of
-- Player and GameState is what lets all of that be tested exhaustively without running a game.
function InventoryReplicator.decide(rows, sent, maxDeltaRows: number)
	local changed, changedCount = {}, 0
	for key, row in pairs(rows) do
		if not rowsEqual(row, sent[key]) then
			changed[key] = row
			changedCount += 1
		end
	end

	-- A row can never legitimately disappear -- discovery is permanent -- but if one ever did,
	-- a delta could not express it. Force a full snapshot rather than leave a stale card on
	-- screen forever.
	for key in pairs(sent) do
		if rows[key] == nil then
			return "full", changed, changedCount
		end
	end

	if changedCount == 0 then
		return "none", changed, 0
	end
	if changedCount > maxDeltaRows then
		return "full", changed, changedCount
	end
	return "delta", changed, changedCount
end

-- Sends whatever changed since the last flush. Returns true if anything went out.
local function flushPlayer(player: Player): boolean
	local entry = tracked[player]
	if not entry or not entry.subscribed then
		return false
	end
	local inventory = GameState.inventory(player)
	if not inventory then
		return false
	end

	local rows = snapshotRows(inventory)
	local mode, changed, changedCount =
		InventoryReplicator.decide(rows, entry.sent, InventoryReplicator.MAX_DELTA_ROWS)

	if mode == "none" then
		InventoryReplicator.stats.flushesWithNoChange += 1
		return false
	end

	if mode == "full" then
		sendFull(player, entry, rows)
		return true
	end

	local from = entry.revision
	entry.revision += 1
	entry.sent = rows
	InventoryReplicator.stats.deltas += 1
	InventoryReplicator.stats.rowsSent += changedCount
	if remote then
		remote:FireClient(player, {
			full = false,
			from = from,
			revision = entry.revision,
			changed = changed,
		})
	end
	return true
end

InventoryReplicator.flushPlayer = flushPlayer

-- ---------------------------------------------------------------- inbound

-- The player opened Collection. Subscribes them and sends the whole truth; every later
-- packet is a delta against it.
function InventoryReplicator.requestFull(player: Player)
	local entry = tracked[player]
	if not entry then
		return
	end
	local inventory = GameState.inventory(player)
	if not inventory then
		return
	end
	if entry.subscribed then
		InventoryReplicator.stats.resyncRequests += 1
	end
	entry.subscribed = true
	sendFull(player, entry, snapshotRows(inventory))
end

-- ---------------------------------------------------------------- lifecycle

function InventoryReplicator.start(netFolder: Folder)
	local found = netFolder:FindFirstChild(Net.INVENTORY_SYNC)
	if found and found:IsA("RemoteEvent") then
		remote = found
	end

	local function track(player: Player)
		tracked[player] = { revision = 0, sent = {}, subscribed = false }
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player)
		tracked[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		track(player)
	end

	task.spawn(function()
		while true do
			task.wait(InventoryReplicator.FLUSH_INTERVAL)
			for player in pairs(tracked) do
				-- One player's failure must not stop the others being served.
				local ok, err = pcall(flushPlayer, player)
				if not ok then
					warn("[RAFFLE] InventoryReplicator: flush failed: " .. tostring(err))
				end
			end
		end
	end)
end

function InventoryReplicator.trackForTest(player: Player)
	tracked[player] = { revision = 0, sent = {}, subscribed = true }
	return tracked[player]
end

function InventoryReplicator.entryForTest(player: Player)
	return tracked[player]
end

return InventoryReplicator
