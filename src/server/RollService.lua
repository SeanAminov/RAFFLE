-- ROLL: choose a ball identity from the player's current Luck and credit it to storage.
--
-- A roll does NOT launch, drop or physically create anything. It resolves rarity and
-- mutation exactly once, credits the resulting VARIANT to the player's virtual inventory,
-- and updates permanent discovery statistics. The ball then waits in storage until the
-- hopper chooses it.
--
-- A ROLL CAN NO LONGER FAIL FOR CAPACITY. There is no queue and no ownership cap, so a full
-- table never rejects, discards or delays a legitimate roll, and Auto Roll never pauses. The
-- only refusals left are "no session" and the anti-spam rate limit on MANUAL presses.
--
-- The reveal payload is IMMUTABLE and is built from the same resolved outcome that was
-- credited, so a displayed odd can never drift from the rolled one. Note what is NOT kept:
-- because storage is aggregated by variant, there is no per-ball record after the credit --
-- the roll-time odds are shown once, in the reveal, and the ball becomes one unit of a stack.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BallCatalog = require(Shared:WaitForChild("BallCatalog"))
local MutationCatalog = require(Shared:WaitForChild("MutationCatalog"))
local Economy = require(Shared:WaitForChild("Economy"))
local BallVariant = require(Shared:WaitForChild("BallVariant"))
local Net = require(Shared:WaitForChild("Net"))

local GameState = require(script.Parent:WaitForChild("GameState"))
local BallInventoryService = require(script.Parent:WaitForChild("BallInventoryService"))

local RollService = {}

-- Config version stamped into every record, so a future retune is distinguishable from
-- results produced under the current numbers.
RollService.CONFIG_VERSION = 2

local nextRollId = 0
local random = Random.new()

-- (player, record, creditInfo) -- raised AFTER the ball is safely in storage, so a listener
-- can never observe a roll that was not credited. Wired by Bootstrap.
RollService.onBallRolled = nil

RollService.stats = {
	rolled = 0,
	blockedByRate = 0,
	forced = 0,
	forcedMutations = 0,
	mutated = 0,
	starterBonuses = 0,
}

-- Builds the immutable record. `forcedEntry` / `forcedMutationId` are Studio-only and are
-- marked as such so a forced result can never be presented as a natural one.
--
-- TWO ROLLS, IN ORDER, EXACTLY ONCE EACH:
--   1. the ball IDENTITY, from Luck, against the ball catalog
--   2. the MUTATION, from the player's Mutations rank and the same Luck
--
-- The mutation is decided here and nowhere else. It never touches the ball's canonical
-- "1 IN X", and nothing downstream may reroll it -- the record is frozen before it returns.
local function buildRecord(player: Player, luck: number, mutationRank: number, forcedEntry, forcedMutationId)
	nextRollId += 1

	local entry = forcedEntry
	if not entry then
		entry = BallCatalog.select(luck, random:NextNumber())
	end

	local exact = BallCatalog.chanceOf(entry.id, luck)
	local tail = BallCatalog.chanceOfThisOrBetter(entry.id, luck)

	-- The mutation roll. A forced mutation still records its TRUE base and effective odds,
	-- so the detail panel never invents numbers to match a forced outcome.
	local mutation, mutationBase, mutationEffective
	if forcedMutationId then
		mutation = MutationCatalog.get(forcedMutationId)
		mutationBase = MutationCatalog.baseChance(mutation.id, mutationRank)
		mutationEffective = MutationCatalog.effectiveChance(mutation.id, mutationRank, luck)
	else
		mutation, mutationBase, mutationEffective =
			MutationCatalog.roll(mutationRank, luck, random:NextNumber())
	end

	return table.freeze({
		rollId = nextRollId,
		variantKey = BallVariant.key(entry.id, mutation.id),
		ballId = entry.id,
		ownerUserId = player.UserId,
		luckAtRoll = luck,
		baseOneIn = entry.oneIn, -- nil for Basic, which is a remainder and not a denominator
		effectiveExactChanceAtRoll = exact,
		effectiveTailChanceAtRoll = tail,
		valueMultiplierAtRoll = entry.value,

		mutationId = mutation.id,
		mutationRankAtRoll = mutationRank,
		mutationBaseChance = mutationBase,
		mutationEffectiveChance = mutationEffective,
		mutationMultiplierAtRoll = mutation.valueMultiplier,

		-- Rarity x mutation at roll time. The player's Ball Value is deliberately NOT folded
		-- in here: it is applied when the ball is RESERVED for play and frozen there, so a
		-- stored ball benefits from a later Ball Value purchase.
		totalValueAtRoll = entry.value * mutation.valueMultiplier,

		configVersion = RollService.CONFIG_VERSION,
		timestamp = os.time(),
		forced = forcedEntry ~= nil,
		forcedMutation = forcedMutationId ~= nil,
	})
end

RollService.buildRecordForTest = buildRecord

-- The payload the client needs to render a truthful reveal. Derived from the SAME record
-- the server credited, so the displayed odds cannot drift from the rolled odds.
function RollService.revealPayload(record)
	local entry = BallCatalog.get(record.ballId)
	local band = record.baseOneIn and BallCatalog.bandFor(record.baseOneIn) or BallCatalog.BASIC_BAND
	local mutation = MutationCatalog.get(record.mutationId)
	local mutated = mutation.id ~= "NONE"

	-- The exact chance of THIS ball carrying THIS mutation, computed honestly from the two
	-- snapshotted probabilities rather than from a headline number. Independent rolls, so the
	-- combined chance is their product.
	local combined = nil
	if mutated and record.effectiveExactChanceAtRoll > 0 then
		combined = record.effectiveExactChanceAtRoll * record.mutationEffectiveChance
	end

	return {
		rollId = record.rollId,
		ballId = record.ballId,
		name = entry.name,
		baseOneIn = record.baseOneIn,
		category = band.name,
		tint = band.tint,
		colour = entry.colour,
		luckAtRoll = record.luckAtRoll,
		exactChance = record.effectiveExactChanceAtRoll,
		tailChance = record.effectiveTailChanceAtRoll,
		value = record.valueMultiplierAtRoll,
		presentation = BallCatalog.presentationFor(entry),
		forced = record.forced,

		mutationId = mutation.id,
		mutationName = mutation.name,
		mutationTint = mutation.tint,
		mutationRim = mutation.rim,
		mutationValue = record.mutationMultiplierAtRoll,
		mutationBaseChance = record.mutationBaseChance,
		mutationChance = record.mutationEffectiveChance,
		mutationRank = record.mutationRankAtRoll,
		combinedChance = combined,
		totalValue = record.totalValueAtRoll,
		forcedMutation = record.forcedMutation,
	}
end

-- Performs one roll. Returns (ok, reason). The ONLY place a ball identity is chosen.
function RollService.roll(player: Player, options): (boolean, string?)
	options = options or {}
	local state = GameState.get(player)
	if not state then
		return false, "no session"
	end

	if not options.skipRateLimit then
		local now = os.clock()
		if now - state.lastRoll < Economy.ROLL_COOLDOWN then
			RollService.stats.blockedByRate += 1
			return false, "too fast"
		end
		state.lastRoll = now
	end

	local forcedEntry = nil
	if state.forcedBallId then
		forcedEntry = BallCatalog.get(state.forcedBallId)
		state.forcedBallId = nil
		RollService.stats.forced += 1
	end

	local forcedMutationId = nil
	if state.forcedMutationId then
		forcedMutationId = state.forcedMutationId
		state.forcedMutationId = nil
		RollService.stats.forcedMutations += 1
	end

	local record = buildRecord(player, GameState.luck(player), GameState.mutationRank(player),
		forcedEntry, forcedMutationId)
	-- CREDIT TO STORAGE. This is the one place a rolled ball enters the inventory, and the
	-- one place a discovery is recorded -- rolling counts it, dropping never counts it again.
	local inventory = GameState.inventory(player)
	local added, info = BallInventoryService.credit(inventory, record.variantKey, 1)
	if added <= 0 then
		-- Only reachable at the arithmetic-safety ceiling, which is ~28 million years of
		-- play away. Reported rather than swallowed so it can never be silent.
		return false, "Storage is full"
	end
	GameState.touchInventory(player)

	-- A newly discovered variant that is MUTATED arrives protected by FeedPolicy's defaults,
	-- so a rare mutation cannot be fed to the table before the player has seen it.
	if RollService.onBallRolled then
		RollService.onBallRolled(player, record, info)
	end

	if not options.silent then
		state.rolls += 1
	end
	RollService.stats.rolled += 1
	if record.mutationId ~= "NONE" then
		RollService.stats.mutated += 1
	end

	local remote = GameState.remote(Net.ROLL_RESULT)
	if remote and not options.silent then
		remote:FireClient(player, RollService.revealPayload(record))
	end

	-- ONBOARDING: RNG must not decide whether the player can afford Auto Roll. After the
	-- first genuine reveal they are topped up to its price if short. Labelled plainly as a
	-- starter bonus, and completely separate from what they rolled.
	if not state.starterBonusGiven and not options.silent then
		state.starterBonusGiven = true
		local shortfall = Economy.STARTER_TOPUP_TO - state.tickets
		if shortfall > 0 then
			GameState.addTickets(player, shortfall)
			RollService.stats.starterBonuses += 1
			GameState.toast(player, "starter",
				("STARTER BONUS  +%d %s"):format(shortfall, Economy.CURRENCY_NAME))
		end
	end

	GameState.push(player)
	return true, nil
end

-- Auto Roll: one tick per player, paced by their own interval. It never checks capacity.
local nextAuto: { [Player]: number } = {}

local function autoTick()
	local now = os.clock()
	for player, state in pairs(GameState.all()) do
		if state.autoRoll and GameState.autoRollUnlocked(player) then
			local due = nextAuto[player]
			if not due or now >= due then
				nextAuto[player] = now + GameState.autoRollInterval(player)
				-- NO CAPACITY CHECK. Auto Roll keeps running at its server-controlled cadence
				-- whatever the table is doing: storage is unbounded, so there is nothing to
				-- fill and nothing to pause for. This is the whole point of separating
				-- rolling from feeding.
				RollService.roll(player, { skipRateLimit = true })
			end
		else
			nextAuto[player] = nil
		end
	end
end

function RollService.start()
	-- Own cleanup via the service directly rather than claiming GameState's single
	-- onPlayerRemoving slot, which another service would silently overwrite.
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		nextAuto[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(0.05)
			autoTick()
		end
	end)
end

-- Session opens with a few balls already in storage so the machine is alive before the
-- first roll. Silent: no reveal, no starter bonus, no roll count.
function RollService.preload(player: Player)
	for _ = 1, Economy.PRELOADED_BALLS do
		RollService.roll(player, { skipRateLimit = true, silent = true })
	end
end

return RollService
