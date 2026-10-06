-- Per-player authoritative session state.
--
-- The shape is deliberately one flat record per player with NO references to Instances, so
-- persisting it is a serialise/deserialise rather than a rewrite of the game loop.
--
-- THERE IS NO QUEUE. Rolled balls go straight into the player's virtual inventory
-- (BallInventoryService) as aggregated counts, and the hopper reserves from there when a
-- physical slot opens. Rolling and feeding no longer share a structure, which is why a full
-- table can never reject or delay a roll.
--
-- Every value here is owned and mutated exclusively by the server. The client receives
-- copies through StateUpdate and can never write one back: the inbound remotes carry
-- intent only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))
local UpgradeConfig = require(Shared:WaitForChild("UpgradeConfig"))
local RebirthConfig = require(Shared:WaitForChild("RebirthConfig"))
local FeedPolicy = require(Shared:WaitForChild("FeedPolicy"))
local Settings = require(Shared:WaitForChild("Settings"))
local Net = require(Shared:WaitForChild("Net"))

local BallInventoryService = require(script.Parent:WaitForChild("BallInventoryService"))

local GameState = {}

local states: { [Player]: any } = {}
local remotes: { [string]: RemoteEvent } = {}

local function newState(player: Player?)
	local ranks: { [string]: number } = {}
	for _, upgrade in ipairs(UpgradeConfig.all()) do
		ranks[upgrade.id] = upgrade.ownedFromStart and 0 or 0
	end
	return {
		tickets = 0,
		ranks = ranks,
		autoRoll = false,
		rebirths = 0,
		tokens = 0,

		-- THE virtual inventory: aggregated stacks, per-variant policies, bounded
		-- reservations and the permanent collection record. Owned exclusively by
		-- BallInventoryService; nothing here mutates it directly.
		inventory = BallInventoryService.new(player and player.UserId or 0),

		-- Bumped on every inventory change so the client can tell a stale delta from a
		-- fresh one without diffing the whole table.
		inventoryRevision = 0,

		-- PRESENTATION ONLY. Stored so it can be persisted and handed back on the next join;
		-- NOTHING on the server may branch on it.
		settings = Settings.normalise(nil),

		activeBalls = 0,
		rolls = 0,
		bumperHits = 0,
		starterBonusGiven = false,

		-- ACHIEVEMENTS. Defaulted here rather than only in ProfileService.apply, because a
		-- session whose profile load FAILED still has to be safe to evaluate -- a blocked
		-- player should be unable to save, not unable to play.
		achievements = { progress = {}, unlocked = {}, claimed = {} },

		-- LIFETIME TOTALS, which survive across sessions and only ever go up. These were
		-- loaded and saved but never incremented, so every profile's lifetime stats were
		-- frozen at whatever the first save happened to contain.
		lifetimeSettled = 0,
		lifetimeTickets = 0,
		sessions = 0,

		lastClaim = 0,

		-- rate limiting, server-side only
		lastRoll = 0,
		lastPurchase = 0,
		lastAutoToggle = 0,
		lastInventoryRequest = 0,
		lastPolicyEdit = 0,
		lastRebirth = -math.huge,
		-- Idempotency: the token of the last ACCEPTED purchase, so a duplicated packet
		-- carrying the same token cannot buy a second rank.
		lastAcceptedPurchaseToken = nil,
		lastAcceptedRebirthToken = nil,

		-- Studio-only overrides. Nil in production; DevTools is the only writer and it
		-- cannot exist outside Studio.
		forcedBallId = nil,
		forcedMutationId = nil,
		feedPaused = false,
	}
end

function GameState.get(player: Player)
	return states[player]
end

function GameState.all()
	return states
end

-- ---------------------------------------------------------------- derived stats

-- Resolves a stat from the player's purchased ranks. ONE place computes effects, so a rank
-- and its effect can never disagree.
--
-- AGGREGATED, not read from a single node: a stat may be fed by several nodes in one family
-- (Luck I, Luck II, ...), and the total is always RECOMPUTED from the full rank table rather
-- than accumulated by applying purchase deltas. That is what makes a reloaded profile
-- reproduce the identical total.
function GameState.stat(player: Player, statKey: string)
	local state = states[player]
	if not state then
		return nil
	end
	return UpgradeConfig.statTotal(statKey, state.ranks)
end

function GameState.luck(player: Player): number
	local state = states[player]
	local upgradeLuck = GameState.stat(player, UpgradeConfig.STAT_LUCK) or 1
	-- Rebirth Luck is permanent and additive. It is derived from the saved Rebirth count,
	-- never accumulated as a second mutable stat, so load and live play resolve identically.
	return upgradeLuck + RebirthConfig.luckBonus(state and state.rebirths or 0)
end

function GameState.ballValue(player: Player): number
	return GameState.stat(player, UpgradeConfig.STAT_BALL_VALUE) or 1
end

-- Seconds between HOPPER releases. Feed Speed owns this; it is the number that actually
-- decides how many balls physically resolve per minute.
function GameState.feedInterval(player: Player): number
	local value = GameState.stat(player, UpgradeConfig.STAT_FEED_INTERVAL)
	if type(value) ~= "number" then
		value = PinballTuning.DROP_INTERVAL
	end
	-- Never below the proven-safe release interval, whatever a future config says.
	return math.max(value, PinballTuning.DROP_INTERVAL_MIN)
end

-- Seconds between AUTO ROLLS. Its OWN stat now, not derived from the feed interval: Auto
-- Speed owns how fast balls enter storage, Feed Speed owns how fast they reach the table.
-- Auto Roll never pauses for a full table -- there is nothing to fill up.
function GameState.autoRollInterval(player: Player): number
	local value = GameState.stat(player, UpgradeConfig.STAT_AUTO_INTERVAL)
	if type(value) ~= "number" then
		value = 0.90
	end
	return value
end

function GameState.autoRollUnlocked(player: Player): boolean
	return GameState.stat(player, UpgradeConfig.STAT_AUTO_ROLL) == true
end

function GameState.mutationRank(player: Player): number
	local value = GameState.stat(player, UpgradeConfig.STAT_MUTATION_RANK)
	return type(value) == "number" and value or 0
end

function GameState.prizeSorter(player: Player): boolean
	return GameState.stat(player, UpgradeConfig.STAT_PRIZE_SORTER) == true
end

-- ---------------------------------------------------------------- tickets

-- THE SINGLE GRANT POINT, which is why the lifetime total is counted here and nowhere else.
-- Counting at each call site instead would mean every future source of tickets has to
-- remember to do it, and the one that forgets is invisible until an achievement disagrees
-- with the wallet.
function GameState.addTickets(player: Player, amount: number): number
	local state = states[player]
	if not state or amount <= 0 then
		return 0
	end
	local granted = math.floor(amount)
	state.tickets += granted
	state.lifetimeTickets = (state.lifetimeTickets or 0) + granted
	return granted
end

-- One ball finished its run. Separate from the ticket grant because a settle can pay the
-- floor amount but is still a settle.
function GameState.noteSettled(player: Player)
	local state = states[player]
	if state then
		state.lifetimeSettled = (state.lifetimeSettled or 0) + 1
	end
end

-- Spend-if-affordable. Deducts BEFORE the caller grants anything, with no yield between,
-- so a duplicated request finds the tickets already gone.
function GameState.trySpend(player: Player, amount: number): boolean
	local state = states[player]
	if not state or amount < 0 then
		return false
	end
	if state.tickets < amount then
		return false
	end
	state.tickets -= amount
	return true
end

-- ---------------------------------------------------------------- inventory
--
-- Thin, named accessors over BallInventoryService so callers never reach into the record
-- directly. Every mutation bumps the replication revision in ONE place, which is what makes
-- coalesced client deltas safe: a revision can never advance without a real change.

function GameState.inventory(player: Player)
	local state = states[player]
	return state and state.inventory or nil
end

-- Raised whenever anything in the inventory changes. Bootstrap wires this to the profile's
-- dirty flag; GameState cannot call ProfileService directly because ProfileService requires
-- GameState, and a require cycle would break both.
GameState.onInventoryChanged = nil

-- Supplies the achievement block of the snapshot. Same cycle problem, same shape of answer:
-- AchievementService requires GameState, so GameState cannot require it back. Bootstrap sets
-- this to AchievementService.snapshot. Nil until then, and the snapshot simply omits the
-- block rather than erroring -- a server that has not finished starting should not crash the
-- first push.
GameState.achievementSnapshot = nil

function GameState.touchInventory(player: Player)
	local state = states[player]
	if state then
		state.inventoryRevision += 1
		if GameState.onInventoryChanged then
			GameState.onInventoryChanged(player)
		end
	end
end

-- How many balls the player owns in total. Display only -- selection always works from
-- per-variant counts, never from this.
function GameState.storedCount(player: Player): number
	local state = states[player]
	if not state then
		return 0
	end
	return BallInventoryService.totalStored(state.inventory)
end

function GameState.storedVariantCount(player: Player): number
	local state = states[player]
	if not state then
		return 0
	end
	local n = 0
	for _ in pairs(state.inventory.stacks) do
		n += 1
	end
	return n
end

-- Which selection rule the hopper uses for this player right now. The Prize Sorter is a
-- plain capability: own it and every automatic feed takes the best ball you own.
function GameState.selectionMode(player: Player): string
	return FeedPolicy.selectionMode(GameState.prizeSorter(player))
end

-- True when the player owns something the hopper is actually allowed to take. Drives the
-- honest "no eligible balls" message rather than a silent idle hopper.
function GameState.hasEligibleBalls(player: Player): boolean
	local state = states[player]
	if not state then
		return false
	end
	return #BallInventoryService.autoEligible(state.inventory) > 0
end

-- ---------------------------------------------------------------- active balls

function GameState.reserveBall(player: Player, cap: number): boolean
	local state = states[player]
	if not state or state.activeBalls >= cap then
		return false
	end
	state.activeBalls += 1
	return true
end

function GameState.releaseBall(player: Player)
	local state = states[player]
	if not state then
		return
	end
	state.activeBalls = math.max(0, state.activeBalls - 1)
end

-- ---------------------------------------------------------------- replication

-- The full client-visible snapshot. Everything the HUD and the upgrade board need, and
-- nothing the client could use to forge a request.
function GameState.snapshot(player: Player)
	local state = states[player]
	if not state then
		return nil
	end
	local ranks = {}
	for id, rank in pairs(state.ranks) do
		ranks[id] = rank
	end
	return {
		tickets = state.tickets,
		luck = GameState.luck(player),
		ballValue = GameState.ballValue(player),
		feedInterval = GameState.feedInterval(player),
		autoRollInterval = GameState.autoRollInterval(player),
		autoRollUnlocked = GameState.autoRollUnlocked(player),
		mutationRank = GameState.mutationRank(player),
		prizeSorter = GameState.prizeSorter(player),
		autoRoll = state.autoRoll,
		ranks = ranks,
		-- STORAGE, not a queue. There is no cap to report and nothing can be "full".
		stored = GameState.storedCount(player),
		storedVariants = GameState.storedVariantCount(player),
		hasEligibleBalls = GameState.hasEligibleBalls(player),
		inventoryRevision = state.inventoryRevision,
		reservations = BallInventoryService.reservationCount(state.inventory),
		dropNext = state.inventory.dropNext,
		selectionMode = GameState.selectionMode(player),
		-- Echoed so a returning player gets their saved choices back. The CLIENT applies this
		-- once, on the first snapshot after joining, and ignores it thereafter -- otherwise a
		-- live edit would be overwritten by the next push before it round-tripped.
		settings = state.settings,
		activeBalls = state.activeBalls,
		activeCap = PinballTuning.MAX_ACTIVE_BALLS,
		rolls = state.rolls,
		-- { progress, unlocked, claimed, claimable }. Eight small entries; the same order of
		-- size as `ranks`, which this snapshot already carries at the same rate.
		achievements = GameState.achievementSnapshot and GameState.achievementSnapshot(player) or nil,
		-- Cost, reward and eligibility come from the same shared config the server transaction
		-- uses. The panel presents this object; it never recomputes or submits an outcome.
		rebirth = RebirthConfig.snapshot(state.rebirths, state.tokens, state.tickets),
	}
end

function GameState.push(player: Player)
	local remote = remotes[Net.STATE_UPDATE]
	local snapshot = GameState.snapshot(player)
	if remote and snapshot then
		remote:FireClient(player, snapshot)
	end
end

function GameState.pushAll()
	for player in pairs(states) do
		GameState.push(player)
	end
end

function GameState.toast(player: Player, kind: string, text: string)
	local remote = remotes[Net.TOAST]
	if remote then
		remote:FireClient(player, kind, text)
	end
end

function GameState.remote(name: string): RemoteEvent?
	return remotes[name]
end

-- ---------------------------------------------------------------- lifecycle

GameState.onPlayerAdded = nil
GameState.onPlayerRemoving = nil

function GameState.start(netFolder: Folder)
	for _, child in ipairs(netFolder:GetChildren()) do
		if child:IsA("RemoteEvent") then
			remotes[child.Name] = child
		end
	end

	local function onAdded(player: Player)
		states[player] = newState(player)
		if GameState.onPlayerAdded then
			GameState.onPlayerAdded(player)
		end
		GameState.push(player)
	end

	Players.PlayerAdded:Connect(onAdded)
	Players.PlayerRemoving:Connect(function(player)
		if GameState.onPlayerRemoving then
			GameState.onPlayerRemoving(player)
		end
		states[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		onAdded(player)
	end
end

return GameState
