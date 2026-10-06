-- The hopper. Reserves one ball out of a player's stored inventory and materialises it.
--
-- The hopper is FULLY AUTOMATIC and physically unchanged from the prototype: it sweeps,
-- it drops, and nothing the player does drives it directly. What changed is where its
-- balls come from -- it no longer invents one, it reserves one out of stored inventory.
-- If nobody owns an eligible ball the hopper simply has nothing to drop.
--
-- The TABLE IS SHARED but the economy is per player, so the hopper must not favour anyone.
-- It serves players ROUND-ROBIN: the cursor advances past whoever was served last, so with
-- two players each gets alternate drops rather than the first one in the table hogging
-- every slot.
--
-- ---------------------------------------------------------------------------------------
-- STAGE 2.1
--
-- * FEED SPEED is per player, so each player has their own release cadence. A single global
--   floor still applies on top, because both players' balls come out of the same physical
--   hopper and that hopper has one proven-safe minimum spacing.
--
-- * STORAGE-BACKED, not queue-backed. There is no queue and no release backlog. When a
--   physical slot opens the hopper asks the inventory to RESERVE one ball, which atomically
--   moves a single unit from stored to reserved and returns an immutable DropSnapshot with
--   the player's Ball Value frozen into it.
--
--   Which ball comes out is the inventory's decision, not this file's: count-weighted
--   normally, or the single best ball the player owns once the Prize Sorter is bought. A
--   held, reserve-protected or Auto-Feed-off variant is never offered.
--
-- * REFUND EXACTLY ONCE. If the spawn fails after the reservation, the ball goes straight
--   back to storage via a refund keyed on the drop id. A second refund finds nothing.
--
-- * SAFE RELEASE. The mouth is checked for clearance BEFORE anything is reserved. If it is
--   blocked the release is deferred and tried again shortly; the inventory is not touched at
--   all, so there is nothing to refund or lose. The deferral is bounded and counted.
--
-- * ONE SCHEDULER. This runs on Heartbeat, the same clock that poses the carriage, and reads
--   the carriage's published per-frame pose rather than sampling it independently.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))

local GameState = require(script.Parent:WaitForChild("GameState"))
local BallService = require(script.Parent:WaitForChild("BallService"))
local BallInventoryService = require(script.Parent:WaitForChild("BallInventoryService"))
local DropperService = require(script.Parent:WaitForChild("DropperService"))

local FeedService = {}

-- Per-player cadence, plus one global floor shared by everyone.
local nextDrop: { [Player]: number } = {}
local nextGlobalRelease = 0
local deferringSince = 0
local cursor = 1
local random = Random.new()

FeedService.onReleased = nil

FeedService.stats = {
	released = 0,
	blockedByCap = 0,
	blockedByNoneEligible = 0,
	blockedByPause = 0,
	deferredBlockedMouth = 0,
	longestDeferral = 0,
	refundedOnSpawnFailure = 0,
	bestDrops = 0,
	manualDrops = 0,
}

-- (player, snapshot, ball) raised after a successful activation. Wired by Bootstrap.
FeedService.onBallActivated = nil

-- (player, snapshot) raised the instant a ball leaves storage, BEFORE it is materialised.
-- Separate from onBallActivated because the two can diverge: a reservation whose spawn fails
-- is refunded and never activates, and a listener counting "balls taken from storage" must
-- see that as a reserve that did not become an activation rather than not see it at all.
FeedService.onBallReserved = nil

-- Reserves and materialises one stored ball for this player. Returns the ball, or nil.
function FeedService.releaseOne(player: Player): BasePart?
	local state = GameState.get(player)
	if not state or state.feedPaused then
		return nil
	end
	if state.activeBalls >= PinballTuning.MAX_ACTIVE_BALLS then
		FeedService.stats.blockedByCap += 1
		return nil
	end
	-- Nothing the hopper is ALLOWED to take is not the same as owning nothing: a player may
	-- hold a thousand balls and have every one of them protected. Either way the hopper idles
	-- honestly rather than reaching past a protection.
	if not GameState.hasEligibleBalls(player) then
		FeedService.stats.blockedByNoneEligible += 1
		return nil
	end

	-- CHECK THE MOUTH FIRST. Doing this before the reservation means a blocked release never
	-- touches the inventory: there is no ball in flight to refund, and no count to restore.
	local clear = DropperService.releaseIsClear()
	if not clear then
		-- Counted once per DEFERRAL EPISODE, not once per frame. On Heartbeat the latter
		-- would tick 60 times a second and make the diagnostic meaningless.
		if deferringSince == 0 then
			deferringSince = os.clock()
			FeedService.stats.deferredBlockedMouth += 1
		end
		local held = os.clock() - deferringSince
		FeedService.stats.longestDeferral = math.max(FeedService.stats.longestDeferral, held)
		-- Bounded. If the mouth somehow stays blocked past the budget the release proceeds
		-- anyway rather than starving the feed; the ball is still created inside the
		-- CanCollide-false carriage and simply falls, and the event is counted above.
		if held < PinballTuning.RELEASE_DEFER_MAX then
			return nil
		end
	end
	deferringSince = 0

	-- RESERVE only once the table has room AND the mouth is clear. This is the atomic
	-- stored -> reserved transition; it also FREEZES the player's current Ball Value into the
	-- snapshot, which is the number settlement will use however the stat moves afterwards.
	local inventory = GameState.inventory(player)
	local snapshot = BallInventoryService.reserve(inventory, {
		mode = GameState.selectionMode(player),
		ballValueUpgrade = GameState.ballValue(player),
		sample = random:NextNumber(),
	})
	if not snapshot then
		FeedService.stats.blockedByNoneEligible += 1
		return nil
	end
	GameState.touchInventory(player)
	if FeedService.onBallReserved then
		FeedService.onBallReserved(player, snapshot)
	end
	if snapshot.source == BallInventoryService.SOURCE_MANUAL then
		FeedService.stats.manualDrops += 1
	elseif GameState.prizeSorter(player) then
		FeedService.stats.bestDrops += 1
	end

	-- Position AND velocity come from the carriage's single published pose, so the ball can
	-- never be given a velocity that belongs to a different frame than its position.
	local ball = BallService.spawn(player, snapshot,
		DropperService.releaseCFrame(), DropperService.releaseVelocity())
	if not ball then
		-- The spawn failed BEFORE activation, so the ball is returned to storage exactly
		-- once. Keyed on the drop id, so a retry cannot refund it twice.
		BallInventoryService.refund(inventory, snapshot.dropId)
		GameState.touchInventory(player)
		FeedService.stats.refundedOnSpawnFailure += 1
		FeedService.stats.blockedByCap += 1
		return nil
	end

	-- RESERVED -> ACTIVE. Only now can the ball settle; a drop that never reached the table
	-- has nothing to settle through and the inventory refuses to pay it.
	BallInventoryService.activate(inventory, snapshot.dropId)
	if FeedService.onBallActivated then
		FeedService.onBallActivated(player, snapshot, ball)
	end

	DropperService.recordRelease(ball, clear)
	if DropperService.isRecording() then
		-- FIRST LEGITIMATE CONTACT. A single Touched connection per RECORDED ball, held only
		-- until the first hit lands and then disconnected. This exists solely for the hopper
		-- measurement harness and is unreachable outside Studio, because recording can only
		-- be armed through the Studio-only DEV remote.
		local connection
		connection = ball.Touched:Connect(function(other)
			if connection then
				connection:Disconnect()
				connection = nil
			end
			DropperService.noteContact(ball, other.Name)
		end)
	end

	FeedService.stats.released += 1
	if FeedService.onReleased then
		FeedService.onReleased(player, ball)
	end
	GameState.push(player)
	return ball
end

-- Ordered player list, so the round-robin cursor is stable rather than depending on
-- pairs() iteration order.
local function orderedPlayers()
	local list = Players:GetPlayers()
	table.sort(list, function(a, b) return a.UserId < b.UserId end)
	return list
end

-- How long to wait before retrying when nothing could be released. Without it, tick() would
-- run a spatial overlap query on every one of the 60 Heartbeats a second while the table is
-- full or nobody has an eligible ball -- which is most of the time at the active-ball cap.
local IDLE_RETRY = 0.05

local function tick()
	local now = os.clock()
	if now < nextGlobalRelease then
		return
	end

	local list = orderedPlayers()
	if #list == 0 then
		nextGlobalRelease = now + IDLE_RETRY
		return
	end

	-- Try each player exactly once, starting after whoever was served last. The first one
	-- that is both DUE and servable takes this drop slot.
	if cursor > #list then
		cursor = 1
	end
	for offset = 0, #list - 1 do
		local index = ((cursor - 1 + offset) % #list) + 1
		local player = list[index]
		local due = nextDrop[player]
		if not due or now >= due then
			if FeedService.releaseOne(player) then
				cursor = index + 1
				nextDrop[player] = now + GameState.feedInterval(player)
				-- The shared physical floor: whatever any one player's Feed Speed says, two
				-- balls never leave the same hopper closer together than the proven-safe
				-- release interval.
				nextGlobalRelease = now + PinballTuning.DROP_INTERVAL_MIN
				return
			end
		end
	end

	-- Nobody could be served this frame. Check again shortly rather than every frame.
	nextGlobalRelease = now + IDLE_RETRY
end

function FeedService.start()
	Players.PlayerRemoving:Connect(function(player)
		nextDrop[player] = nil
	end)
	RunService.Heartbeat:Connect(tick)
end

return FeedService
