--!strict
-- ACHIEVEMENTS: what is met, and what has been paid for.
--
-- ---------------------------------------------------------------------------------------
-- PROGRESS IS DERIVED, NEVER ACCUMULATED
--
-- Nothing here counts anything. Every metric is READ from state the profile already keeps --
-- lifetime rolls, the collection table, the sum of purchased ranks -- and recomputed on
-- demand. A separate per-achievement counter would be a second source of truth that can
-- disagree with the first, and it would need a migration every time an achievement is added.
--
-- The consequence worth stating: achievements are RETROACTIVE by construction. A player with
-- 900 rolls the day this ships unlocks the 100-roll achievement on their next evaluation,
-- because there was never a counter that started at zero.
--
-- ---------------------------------------------------------------------------------------
-- UNLOCKING IS STICKY, CLAIMING IS ONCE
--
-- `unlocked` is written once and never cleared. It is technically derivable from progress,
-- and it is stored anyway: if a threshold is ever lowered, or a metric is ever redefined, an
-- achievement the player has already been shown must not silently re-lock.
--
-- `claimed` is the only thing that MUST survive exactly. It gates a ticket grant, so the
-- claim path is written the way every other grant in this codebase is written -- consume
-- before paying, with no yield in between, so a duplicated packet finds the flag already set
-- and pays nothing.
--
-- ---------------------------------------------------------------------------------------
-- EVALUATION IS CHEAP AND HAPPENS ON EVENTS, NOT ON A HEARTBEAT
--
-- Eight definitions, each a table read and a comparison. It runs on the events that can
-- possibly have changed a metric, and on load. It does not poll.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AchievementConfig = require(Shared:WaitForChild("AchievementConfig"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local BallVariant = require(Shared:WaitForChild("BallVariant"))

local GameState = require(script.Parent:WaitForChild("GameState"))
local EventBus = require(script.Parent:WaitForChild("EventBus"))

local AchievementService = {}

AchievementService.stats = {
	evaluated = 0,
	unlocked = 0,
	claimed = 0,
	claimRefusedUnknown = 0,
	claimRefusedLocked = 0,
	claimRefusedAlready = 0,
}

-- ---------------------------------------------------------------- metrics

-- ONE function per metric, each a pure read of session state. They must not mutate anything:
-- evaluation runs inside an event dispatch, and a metric with a side effect would change the
-- state the emitter is midway through updating.
local METRIC_READERS: { [string]: (any) -> number } = {}

METRIC_READERS[AchievementConfig.METRIC_ROLLS] = function(state): number
	return state.rolls or 0
end

METRIC_READERS[AchievementConfig.METRIC_BUMPER_HITS] = function(state): number
	return state.bumperHits or 0
end

METRIC_READERS[AchievementConfig.METRIC_SETTLED] = function(state): number
	return state.lifetimeSettled or 0
end

METRIC_READERS[AchievementConfig.METRIC_TICKETS_EARNED] = function(state): number
	return state.lifetimeTickets or 0
end

-- The COLLECTION table, not the stacks. A variant is discovered by rolling it once and stays
-- discovered after every copy has been fed to the table.
METRIC_READERS[AchievementConfig.METRIC_VARIANTS] = function(state): number
	local inventory = state.inventory
	if not inventory or type(inventory.collection) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(inventory.collection) do
		n += 1
	end
	return n
end

-- DISTINCT mutations, not mutated variants. A player who has seen a Charged Basic and a
-- Charged Rare has discovered one mutation, not two.
METRIC_READERS[AchievementConfig.METRIC_MUTATIONS] = function(state): number
	local inventory = state.inventory
	if not inventory or type(inventory.collection) ~= "table" then
		return 0
	end
	local seen: { [string]: boolean } = {}
	local n = 0
	for key in pairs(inventory.collection) do
		local _, mutationId = BallVariant.split(key)
		if mutationId and mutationId ~= BallVariant.NO_MUTATION and not seen[mutationId] then
			seen[mutationId] = true
			n += 1
		end
	end
	return n
end

-- The SUM of ranks, so buying Luck twice counts twice. "Buy any upgrade" is then simply a
-- threshold of one, and a future "own 20 ranks" needs no new metric.
METRIC_READERS[AchievementConfig.METRIC_UPGRADES] = function(state): number
	local total = 0
	for _, rank in pairs(state.ranks or {}) do
		if type(rank) == "number" then
			total += rank
		end
	end
	return total
end

-- Exposed for the validator and for tests.
AchievementService.METRIC_READERS = METRIC_READERS

function AchievementService.metricValue(state, metric: string): number
	local reader = METRIC_READERS[metric]
	if not reader then
		return 0
	end
	return reader(state)
end

-- ---------------------------------------------------------------- state access

-- Session records made before achievements existed, and any state whose profile load failed,
-- must still be safe to evaluate. This is the only place that assumes the shape.
local function ensure(state)
	local existing = state.achievements
	if type(existing) ~= "table" then
		existing = { progress = {}, unlocked = {}, claimed = {} }
		state.achievements = existing
		return existing
	end
	existing.progress = type(existing.progress) == "table" and existing.progress or {}
	existing.unlocked = type(existing.unlocked) == "table" and existing.unlocked or {}
	existing.claimed = type(existing.claimed) == "table" and existing.claimed or {}
	return existing
end

AchievementService.ensure = ensure

-- ---------------------------------------------------------------- evaluation

-- Raised for each newly unlocked achievement. Bootstrap bridges it to the bus; this module
-- does not emit directly so that the "producers raise hooks, Bootstrap bridges" layering
-- holds for achievements too.
AchievementService.onUnlocked = nil

-- Returns the ids unlocked BY THIS CALL, so a caller can toast exactly what just happened
-- rather than everything that is unlocked.
function AchievementService.evaluate(player: Player): { string }
	local state = GameState.get(player)
	if not state then
		return {}
	end
	local record = ensure(state)
	AchievementService.stats.evaluated += 1

	local newly = {}
	for _, def in ipairs(AchievementConfig.all()) do
		if not record.unlocked[def.id] then
			if AchievementService.metricValue(state, def.metric) >= def.threshold then
				record.unlocked[def.id] = true
				AchievementService.stats.unlocked += 1
				table.insert(newly, def.id)
			end
		end
	end

	if #newly > 0 and AchievementService.onUnlocked then
		for _, id in ipairs(newly) do
			AchievementService.onUnlocked(player, id, AchievementConfig.get(id))
		end
	end
	return newly
end

-- ---------------------------------------------------------------- claiming

AchievementService.onClaimed = nil

-- Returns (ok, rewardOrNil, reason).
--
-- THE ORDER IS THE WHOLE POINT. `claimed` is set BEFORE the tickets are granted, with no
-- yield between, so a duplicated or forged packet arriving in the same frame finds the flag
-- already true and is refused. Granting first and flagging second is the shape that pays
-- twice.
function AchievementService.claim(player: Player, achievementId: any): (boolean, number?, string?)
	local state = GameState.get(player)
	if not state then
		return false, nil, nil
	end

	local def = AchievementConfig.get(achievementId)
	if not def then
		AchievementService.stats.claimRefusedUnknown += 1
		return false, nil, nil   -- say nothing; only a forged packet gets here
	end

	local record = ensure(state)

	-- Re-evaluated rather than trusted. A claim for something that is genuinely met but whose
	-- unlock event was missed -- a listener that errored, an achievement added mid-session --
	-- should succeed, not be refused for bookkeeping the player cannot see.
	if not record.unlocked[def.id] then
		if AchievementService.metricValue(state, def.metric) >= def.threshold then
			record.unlocked[def.id] = true
			AchievementService.stats.unlocked += 1
		else
			AchievementService.stats.claimRefusedLocked += 1
			return false, nil, "Not unlocked yet"
		end
	end

	if record.claimed[def.id] then
		AchievementService.stats.claimRefusedAlready += 1
		return false, nil, "Already claimed"
	end

	-- --- consume, then pay. No yield between these two lines. ---
	record.claimed[def.id] = true
	local granted = GameState.addTickets(player, def.reward)
	-- --- end ---
	--
	-- Lifetime earnings are NOT incremented here. GameState.addTickets is the single grant
	-- point and counts them itself, so doing it again would count an achievement reward twice
	-- and let the TICKETS_EARNED achievement disagree with the wallet.

	AchievementService.stats.claimed += 1
	if AchievementService.onClaimed then
		AchievementService.onClaimed(player, def.id, granted)
	end
	return true, granted, nil
end

-- ---------------------------------------------------------------- replication

-- The compact per-player view the client draws from. Progress is sent as a NUMBER rather than
-- a percentage so the panel can render "412 / 1000" without the server deciding a format.
function AchievementService.snapshot(player: Player)
	local state = GameState.get(player)
	if not state then
		return nil
	end
	local record = ensure(state)
	local progress: { [string]: number } = {}
	local unlocked: { [string]: boolean } = {}
	local claimed: { [string]: boolean } = {}
	local claimable = 0

	for _, def in ipairs(AchievementConfig.all()) do
		local value = AchievementService.metricValue(state, def.metric)
		-- Clamped to the threshold: the panel wants "how close", and an unbounded 47,000 / 1000
		-- is noise once it is met.
		progress[def.id] = math.min(value, def.threshold)
		if record.unlocked[def.id] then
			unlocked[def.id] = true
		end
		if record.claimed[def.id] then
			claimed[def.id] = true
		elseif record.unlocked[def.id] then
			claimable += 1
		end
	end

	return { progress = progress, unlocked = unlocked, claimed = claimed, claimable = claimable }
end

-- ---------------------------------------------------------------- wiring

-- Subscribes to every event that can move a metric. Deliberately NOT subscribed to everything:
-- BallReserved and BallActivated change no metric, and a listener that runs on every one of
-- them to discover nothing changed is pure cost on the hottest paths.
--
-- Returns the unsubscribe functions, so a test can tear the service down.
function AchievementService.start(): { () -> boolean }
	local function reevaluate(payload)
		if payload and payload.player then
			AchievementService.evaluate(payload.player)
		end
	end

	return {
		EventBus.on(GameEvents.BALL_ROLLED, reevaluate),
		EventBus.on(GameEvents.BALL_DISCOVERED, reevaluate),
		EventBus.on(GameEvents.MUTATION_DISCOVERED, reevaluate),
		EventBus.on(GameEvents.BUMPER_HIT, reevaluate),
		EventBus.on(GameEvents.BALL_SETTLED, reevaluate),
		EventBus.on(GameEvents.UPGRADE_PURCHASED, reevaluate),
	}
end

return AchievementService
