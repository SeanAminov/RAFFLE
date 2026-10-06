--!strict
-- THE ACHIEVEMENT DEFINITIONS. Pure data: no state, no server dependency, no logic beyond
-- validation. The client requires this to draw the list; the server requires it to decide
-- what is met. One definition, two readers, so a displayed requirement is the enforced one.
--
-- ---------------------------------------------------------------------------------------
-- EVERY METRIC IS DERIVED FROM STATE THE PROFILE ALREADY KEEPS
--
-- No achievement has its own counter. `metric` names something the profile already stores or
-- can compute from what it stores -- lifetime rolls, the size of the collection, the sum of
-- purchased ranks -- and progress is recomputed from that on demand.
--
-- That is what makes drift impossible. A separate per-achievement counter can disagree with
-- the thing it counts (the profile says 412 rolls, the achievement says 397, and nobody can
-- say which is right); a derived one cannot. It also makes achievements RETROACTIVE for free:
-- a player with 900 rolls when this ships unlocks the 100-roll achievement on their next
-- load, without a migration.
--
-- The cost is that an achievement whose condition is not a running total -- "three mutations
-- inside one minute" -- cannot be expressed this way. When one is wanted, it gets a real
-- counter in `achievements.progress`, which the schema already carries and nothing currently
-- writes. That field exists for exactly that day.
--
-- ---------------------------------------------------------------------------------------
-- UNLOCKING IS NOT CLAIMING
--
-- Crossing the threshold UNLOCKS. Claiming is a separate, deliberate player action that pays
-- the reward exactly once, ever. They are separate because a reward that lands silently while
-- the player is looking at the machine is a reward they never saw.

local AchievementConfig = {}

-- ---------------------------------------------------------------- metrics

-- The names an achievement may be measured against. The SERVER maps each to a value; this
-- file only declares which ones exist, so a typo in a definition fails the validator here
-- rather than silently measuring nothing.
AchievementConfig.METRIC_ROLLS = "ROLLS"
AchievementConfig.METRIC_VARIANTS = "VARIANTS_DISCOVERED"
AchievementConfig.METRIC_MUTATIONS = "MUTATIONS_DISCOVERED"
AchievementConfig.METRIC_BUMPER_HITS = "BUMPER_HITS"
AchievementConfig.METRIC_SETTLED = "BALLS_SETTLED"
AchievementConfig.METRIC_TICKETS_EARNED = "TICKETS_EARNED"
AchievementConfig.METRIC_UPGRADES = "UPGRADE_RANKS"

AchievementConfig.METRICS = table.freeze({
	AchievementConfig.METRIC_ROLLS,
	AchievementConfig.METRIC_VARIANTS,
	AchievementConfig.METRIC_MUTATIONS,
	AchievementConfig.METRIC_BUMPER_HITS,
	AchievementConfig.METRIC_SETTLED,
	AchievementConfig.METRIC_TICKETS_EARNED,
	AchievementConfig.METRIC_UPGRADES,
})

-- ---------------------------------------------------------------- the seed eight
--
-- Deliberately shaped as a ladder rather than eight equivalent tasks:
--
--   TWO are reachable in the first minute. They exist to teach that achievements are a thing
--   and that claiming is an action you take -- a player who never notices the panel never
--   claims anything, and a first reward that arrives before they have gone looking is the
--   cheapest way to make them look.
--
--   THREE land inside a first session.
--
--   THREE are a reason to come back.
--
-- Rewards are small on purpose. Tier I upgrade costs run 400-2800 tickets, so the whole set
-- claimed is worth roughly one mid-tier upgrade -- a nudge, not a shortcut past the economy.
--
-- `order` is display order and is independent of difficulty, so the list can be re-ordered
-- without renumbering thresholds.
local DEFINITIONS = {
	{
		id = "FIRST_ROLL",
		displayName = "First Pull",
		description = "Roll your first ball.",
		metric = AchievementConfig.METRIC_ROLLS,
		threshold = 1,
		reward = 50,
		order = 1,
	},
	{
		id = "FIRST_DROP",
		displayName = "Down the Drain",
		description = "Watch one ball finish its run.",
		metric = AchievementConfig.METRIC_SETTLED,
		threshold = 1,
		reward = 50,
		order = 2,
	},
	{
		id = "FIRST_UPGRADE",
		displayName = "Reinvested",
		description = "Buy any upgrade.",
		metric = AchievementConfig.METRIC_UPGRADES,
		threshold = 1,
		reward = 100,
		order = 3,
	},
	{
		id = "HUNDRED_ROLLS",
		displayName = "Warmed Up",
		description = "Roll 100 balls.",
		metric = AchievementConfig.METRIC_ROLLS,
		threshold = 100,
		reward = 250,
		order = 4,
	},
	{
		id = "FIRST_MUTATION",
		displayName = "Something's Different",
		description = "Discover your first mutation.",
		metric = AchievementConfig.METRIC_MUTATIONS,
		threshold = 1,
		reward = 300,
		order = 5,
	},
	{
		id = "TEN_VARIANTS",
		displayName = "Collector",
		description = "Discover 10 different balls.",
		metric = AchievementConfig.METRIC_VARIANTS,
		threshold = 10,
		reward = 400,
		order = 6,
	},
	{
		id = "THOUSAND_HITS",
		displayName = "Bumper Car",
		description = "Land 1,000 bumper hits.",
		metric = AchievementConfig.METRIC_BUMPER_HITS,
		threshold = 1000,
		reward = 500,
		order = 7,
	},
	{
		id = "TEN_THOUSAND_TICKETS",
		displayName = "Rolling In It",
		description = "Earn 10,000 Tickets.",
		metric = AchievementConfig.METRIC_TICKETS_EARNED,
		threshold = 10000,
		reward = 1000,
		order = 8,
	},
}

local BY_ID: { [string]: any } = {}
local ORDERED: { any } = {}
for _, def in ipairs(DEFINITIONS) do
	table.freeze(def)
	BY_ID[def.id] = def
	table.insert(ORDERED, def)
end
table.sort(ORDERED, function(a, b)
	if a.order == b.order then
		return a.id < b.id
	end
	return a.order < b.order
end)
table.freeze(BY_ID)
table.freeze(ORDERED)

function AchievementConfig.get(id: any)
	if type(id) ~= "string" then
		return nil
	end
	return BY_ID[id]
end

function AchievementConfig.all()
	return ORDERED
end

function AchievementConfig.count(): number
	return #ORDERED
end

-- ---------------------------------------------------------------- validator

-- Everything a malformed definition could break, checked once at startup rather than
-- discovered by a player whose achievement never moves.
function AchievementConfig.validate(): (boolean, { string })
	local problems = {}

	local metricValid: { [string]: boolean } = {}
	for _, name in ipairs(AchievementConfig.METRICS) do
		metricValid[name] = true
	end

	local seenId: { [string]: boolean } = {}
	local seenOrder: { [number]: string } = {}

	for _, def in ipairs(ORDERED) do
		if seenId[def.id] then
			table.insert(problems, ("duplicate id %q"):format(def.id))
		end
		seenId[def.id] = true

		if seenOrder[def.order] then
			table.insert(problems, ("order %d is used by both %s and %s")
				:format(def.order, seenOrder[def.order], def.id))
		end
		seenOrder[def.order] = def.id

		if not metricValid[def.metric] then
			table.insert(problems, ("%s measures unknown metric %q"):format(def.id, tostring(def.metric)))
		end
		-- A zero or negative threshold would be met by a brand new profile, so the whole set
		-- would unlock before the player had done anything.
		if type(def.threshold) ~= "number" or def.threshold < 1 or def.threshold % 1 ~= 0 then
			table.insert(problems, ("%s has a non-positive-integer threshold"):format(def.id))
		end
		-- A zero reward makes claiming pointless and a negative one would take tickets away.
		if type(def.reward) ~= "number" or def.reward < 1 or def.reward % 1 ~= 0 then
			table.insert(problems, ("%s has a non-positive-integer reward"):format(def.id))
		end
		if type(def.displayName) ~= "string" or #def.displayName == 0 then
			table.insert(problems, ("%s has no displayName"):format(def.id))
		end
		if type(def.description) ~= "string" or #def.description == 0 then
			table.insert(problems, ("%s has no description"):format(def.id))
		end
	end

	return #problems == 0, problems
end

-- Total tickets available from claiming everything. Used by the pacing check to keep the set
-- an incentive rather than a bypass of the economy.
function AchievementConfig.totalReward(): number
	local total = 0
	for _, def in ipairs(ORDERED) do
		total += def.reward
	end
	return total
end

return AchievementConfig
