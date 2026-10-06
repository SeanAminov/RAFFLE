--!strict
-- Upgrade DEFINITIONS: what an upgrade costs, what it requires, and what it contributes.
--
-- Deliberately separate from UpgradeGraph, which owns only where the nodes sit on screen.
-- Nothing here knows about pixels, and nothing in the graph knows about prices. A UI
-- button never holds a cost or a prerequisite rule -- it reads them from here, and the
-- server validates against this same table.
--
-- ---------------------------------------------------------------------------------------
-- FAMILIES AND TIERS
--
-- Several nodes may feed ONE underlying stat: Luck I, Luck II, Luck III. Each node declares
-- a `family`, and the family declares how its members combine. Effective values are always
-- RECOMPUTED from the full set of owned ranks -- never mutated by applying a purchase delta
-- -- so reloading a profile reproduces exactly the same totals.
--
-- Tiers ADD, they do not multiply. Multiplying Luck I by Luck II would make totals explode
-- and would make the ORDER of purchases matter, which is indefensible for a player.
--
-- STABLE IDS ARE PERMANENT. `LUCK` is the id; "Luck I" is only what it is called on screen.
-- An id is never derived from display text, a Roman numeral, graph position, a parent node
-- or branch order, because all of those change and a saved profile key may not.
--
-- `contributions` is indexed by RANK, where contributions[1] is rank 0 (always 0). The
-- validator asserts that, for a single-tier family, base + contribution reproduces the
-- legacy `values` table exactly -- so this refactor cannot silently move a number.

local UpgradeConfig = {}

-- Stat keys the server resolves for a player. One key per gameplay effect.
UpgradeConfig.STAT_LUCK = "luck"
UpgradeConfig.STAT_FEED_INTERVAL = "feedInterval"
UpgradeConfig.STAT_AUTO_INTERVAL = "autoRollInterval"
UpgradeConfig.STAT_BALL_VALUE = "ballValue"
UpgradeConfig.STAT_AUTO_ROLL = "autoRollUnlocked"
UpgradeConfig.STAT_MUTATION_RANK = "mutationRank"
UpgradeConfig.STAT_PRIZE_SORTER = "prizeSorter"

-- Default prerequisite level when an edge does not name one.
UpgradeConfig.DEFAULT_REQUIRED_LEVEL = 1

-- Availability. PREVIEW nodes are visible, honest and unpurchasable: no cost, no remote
-- path, no gameplay effect, and excluded from affordability badges.
UpgradeConfig.AVAILABLE = "AVAILABLE"
UpgradeConfig.PREVIEW = "PREVIEW"

-- ---------------------------------------------------------------- families
--
-- `combine` says how member contributions become one effective value:
--   ADD        total = base + sum(contributions), optionally clamped
--   SUBTRACT   total = base - sum(contributions), floored (used for an interval)
--   CAPABILITY total = true if any member is owned
--
-- The FEED floor is not a taste decision. Balls resolved per minute were measured against
-- feed interval from a cleared, settled table: 1.20s -> 43.9/min, 1.02s -> 55.7, 0.88s ->
-- 57.6, and then 0.76 / 0.65 / 0.55 all flat at 45-50. Throughput saturates at 0.88s because
-- the active-ball cap of 10 binds; below it the extra releases only add crowding. Selling a
-- rank into that flat region would be a placebo, so the floor is enforced here and the
-- ladder stops at it.
UpgradeConfig.FAMILIES = {
	LUCK = { stat = UpgradeConfig.STAT_LUCK, base = 1.0, combine = "ADD" },
	VALUE = { stat = UpgradeConfig.STAT_BALL_VALUE, base = 1.0, combine = "ADD" },
	MUTATION = { stat = UpgradeConfig.STAT_MUTATION_RANK, base = 0, combine = "ADD", max = 5 },
	FEED = { stat = UpgradeConfig.STAT_FEED_INTERVAL, base = 1.20, combine = "SUBTRACT", floor = 0.88 },
	-- Seconds between AUTO ROLLS. Base 0.90 is exactly the old derived value (1.20 * 0.75),
	-- so rank 0 reproduces the pacing everything was measured against.
	--
	-- The floor is 0.45s, not zero. Rolling is pure computation with no physics limit, but an
	-- unbounded roll rate would trivialise the Collection: discovery is the scarce thing, and
	-- a 1-in-1,000,000 ball should stay a story rather than a matter of waiting. 0.45s is
	-- 133 rolls/min, double the base rate.
	AUTOSPEED = { stat = UpgradeConfig.STAT_AUTO_INTERVAL, base = 0.90, combine = "SUBTRACT", floor = 0.45 },
	AUTO = { stat = UpgradeConfig.STAT_AUTO_ROLL, combine = "CAPABILITY" },
	SORTER = { stat = UpgradeConfig.STAT_PRIZE_SORTER, combine = "CAPABILITY" },
	ROOT = { combine = "CAPABILITY" },
	LOCKED = { combine = "CAPABILITY" },
}

local UPGRADES = {
	{
		id = "STARTER_MACHINE",
		displayName = "Starter Machine",
		short = "START",
		family = "ROOT",
		tier = 0,
		blurb = "The machine you already own. Everything branches from here.",
		icon = "machine",
		maxRank = 0,
		costs = {},
		requires = {},
		ownedFromStart = true,
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
	},

	{
		id = "AUTO_ROLL",
		displayName = "Auto Roll",
		short = "AUTO",
		family = "AUTO",
		tier = 1,
		blurb = "Keeps rolling new balls into your collection on its own. Never stops for a full table.",
		icon = "auto",
		maxRank = 1,
		costs = { 100 },
		-- The root is an owned, rank-0 node, so its edges are the one place a level of 0 is
		-- correct. Stated explicitly rather than defaulted, so it reads as deliberate.
		requires = { { id = "STARTER_MACHINE", level = 0 } },
		stat = UpgradeConfig.STAT_AUTO_ROLL,
		values = { false, true },
		contributions = { 0, 1 },
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
	},

	{
		id = "LUCK",
		displayName = "Luck I",
		short = "LUCK",
		family = "LUCK",
		tier = 1,
		blurb = "Every roll takes the rarest of more attempts. The single most valuable upgrade.",
		icon = "clover",
		maxRank = 5,
		costs = { 110, 320, 700, 1700, 4200 },
		requires = { { id = "STARTER_MACHINE", level = 0 } },
		stat = UpgradeConfig.STAT_LUCK,
		values = { 1.00, 1.35, 1.75, 2.25, 3.00, 4.00 },
		contributions = { 0, 0.35, 0.75, 1.25, 2.00, 3.00 },
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
		spine = true,
	},

	{
		id = "FEED_SPEED",
		displayName = "Feed Speed I",
		short = "FEED",
		family = "FEED",
		tier = 1,
		-- Renamed from ROLL_SPEED after measurement: rolling faster into an already-full
		-- queue changed nothing a player could see. Rolled/min and resolved/min were
		-- IDENTICAL at every Roll Speed rank. This rank moves the HOPPER's release interval
		-- instead, which is what decides how many balls are actually on the table.
		--
		-- TWO RANKS, because the family floor of 0.88s is where measured throughput stops
		-- rising. The former third rank at 0.78s sat below that floor and measured no better
		-- than 0.88s, so it is removed rather than clamped into a rank that charges for
		-- nothing. Raising the ceiling is MORE BALLS's job.
		blurb = "The hopper releases balls sooner, so more balls are on the table at once.",
		icon = "speed",
		maxRank = 2,
		costs = { 150, 480 },
		requires = { { id = "AUTO_ROLL", level = 1 } },
		stat = UpgradeConfig.STAT_FEED_INTERVAL,
		values = { 1.20, 1.02, 0.88 },
		-- Seconds shaved off the base interval. Combined by subtraction, then floored.
		contributions = { 0, 0.18, 0.32 },
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
	},

	{
		id = "AUTO_SPEED",
		-- A NEW STABLE ID, deliberately not reusing ROLL_SPEED. That id belonged to the Stage
		-- 2.1 placebo that became FEED_SPEED; resurrecting it would silently hand ranks of
		-- this upgrade to any profile still carrying the retired one.
		displayName = "Auto Speed I",
		short = "RATE",
		family = "AUTOSPEED",
		tier = 1,
		-- HONEST, UNLIKE ITS ANCESTOR. Stage 2.1 killed ROLL_SPEED because rolling faster into
		-- a capped queue changed nothing a player could see. There is no queue now: a faster
		-- roll rate genuinely means more balls owned, more discoveries, and a Collection that
		-- fills sooner. It does NOT raise Ticket income -- that is bounded by the ten-ball
		-- table and Feed Speed, which is exactly the separation this upgrade exists to make.
		blurb = "Auto Roll adds balls to your collection faster. Does not change odds or how fast the table pays.",
		icon = "auto",
		maxRank = 3,
		costs = { 400, 1100, 2800 },
		requires = { { id = "AUTO_ROLL", level = 1 } },
		stat = UpgradeConfig.STAT_AUTO_INTERVAL,
		values = { 0.90, 0.72, 0.58, 0.45 },
		contributions = { 0, 0.18, 0.32, 0.45 },
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
	},

	{
		id = "BALL_VALUE",
		displayName = "Ball Value I",
		short = "VALUE",
		family = "VALUE",
		tier = 1,
		blurb = "Multiplies what every ball settles for when it drains.",
		icon = "coin",
		maxRank = 5,
		costs = { 230, 620, 1450, 3500, 8500 },
		requires = { { id = "STARTER_MACHINE", level = 0 } },
		stat = UpgradeConfig.STAT_BALL_VALUE,
		values = { 1.00, 1.30, 1.65, 2.05, 2.50, 3.00 },
		contributions = { 0, 0.30, 0.65, 1.05, 1.50, 2.00 },
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
	},

	{
		id = "MUTATIONS",
		displayName = "Mutations I",
		short = "MUTATE",
		family = "MUTATION",
		tier = 1,
		blurb = "Rolled balls can come out Charged, worth 3x when they settle. Luck improves the odds.",
		icon = "mutation",
		maxRank = 5,
		costs = { 310, 760, 1700, 4000, 9500 },
		-- TWO parents, each at Level 1, neither at MAX.
		requires = {
			{ id = "BALL_VALUE", level = 1 },
			{ id = "LUCK", level = 1 },
		},
		stat = UpgradeConfig.STAT_MUTATION_RANK,
		values = { 0, 1, 2, 3, 4, 5 },
		-- A RANK, not a percentage. Tiers add ranks; the normalised probability model in
		-- MutationCatalog then turns the combined rank into odds. Raw mutation percentages
		-- from separate tiers are never added together.
		contributions = { 0, 1, 2, 3, 4, 5 },
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
	},

	{
		id = "PRIZE_SORTER",
		-- NO NUMERAL, deliberately. Its siblings are "Luck I", "Ball Value I" and so on
		-- because each has a real Tier II planned behind it. This one is a single paid
		-- capability with no ladder, and calling it "I" would promise a sequel that does not
		-- exist. The stable id is unchanged, which is the part a profile depends on.
		displayName = "Prize Sorter",
		short = "SORTER",
		family = "SORTER",
		tier = 1,
		blurb = "Always drops the most valuable ball in your whole collection first. Never changes odds, creates balls or removes them.",
		icon = "sorter",
		maxRank = 1,
		costs = { 2200 },
		requires = {
			{ id = "AUTO_ROLL", level = 1 },
			{ id = "LUCK", level = 1 },
		},
		stat = UpgradeConfig.STAT_PRIZE_SORTER,
		values = { false, true },
		contributions = { 0, 1 },
		resetGroup = "UPGRADES",
		availability = UpgradeConfig.AVAILABLE,
	},

	-- ------------------------------------------------------------------ previews
	--
	-- Visible, honest and unpurchasable. They extend their family's branch so the shape of
	-- the tree is legible, and they carry no cost, no stat and no remote path.

	{
		id = "LUCK_II",
		displayName = "Luck II",
		short = "LUCK",
		family = "LUCK",
		tier = 2,
		blurb = "A second Luck line, adding to your total rather than multiplying it. Coming later.",
		icon = "clover",
		maxRank = 0,
		costs = {},
		requires = { { id = "LUCK", level = 1 } },
		preview = true,
		availability = UpgradeConfig.PREVIEW,
		resetGroup = "UPGRADES",
	},
	{
		id = "BALL_VALUE_II",
		displayName = "Ball Value II",
		short = "VALUE",
		family = "VALUE",
		tier = 2,
		blurb = "A second Ball Value line, adding to your total. Coming later.",
		icon = "coin",
		maxRank = 0,
		costs = {},
		requires = { { id = "BALL_VALUE", level = 1 } },
		preview = true,
		availability = UpgradeConfig.PREVIEW,
		resetGroup = "UPGRADES",
	},
	{
		id = "MULTI_ROLL",
		displayName = "Multi-Roll",
		short = "MULTI",
		family = "LOCKED",
		tier = 1,
		blurb = "Coming later.",
		icon = "multi",
		maxRank = 0,
		costs = {},
		requires = {
			{ id = "AUTO_ROLL", level = 1 },
			{ id = "LUCK", level = 1 },
		},
		preview = true,
		availability = UpgradeConfig.PREVIEW,
		resetGroup = "UPGRADES",
	},
	{
		id = "MORE_BALLS",
		displayName = "More Balls",
		short = "BALLS",
		family = "LOCKED",
		tier = 1,
		blurb = "Raises the ten-ball ceiling that currently bounds Feed Speed. Coming later.",
		icon = "balls",
		maxRank = 0,
		costs = {},
		requires = { { id = "FEED_SPEED", level = 1 } },
		preview = true,
		availability = UpgradeConfig.PREVIEW,
		resetGroup = "UPGRADES",
	},
}

UpgradeConfig.UPGRADES = UPGRADES

local byId: { [string]: any } = {}
local byFamily: { [string]: { any } } = {}
for _, upgrade in ipairs(UPGRADES) do
	byId[upgrade.id] = upgrade
	byFamily[upgrade.family] = byFamily[upgrade.family] or {}
	table.insert(byFamily[upgrade.family], upgrade)
end

function UpgradeConfig.get(id: string)
	return byId[id]
end

function UpgradeConfig.all()
	return UPGRADES
end

function UpgradeConfig.membersOf(family: string)
	return byFamily[family] or {}
end

function UpgradeConfig.isPreview(id: string): boolean
	local upgrade = byId[id]
	return upgrade ~= nil and upgrade.availability == UpgradeConfig.PREVIEW
end

-- ---------------------------------------------------------------- levels and costs

-- The level an edge demands. ONE resolver, used by the server validator, the board's node
-- states and the connector rendering, so the picture and the rule cannot drift.
function UpgradeConfig.requiredLevel(requirement): number
	if requirement.level ~= nil then
		return requirement.level
	end
	return UpgradeConfig.DEFAULT_REQUIRED_LEVEL
end

-- Price of moving from `rank` to `rank + 1`. nil when maxed or not purchasable.
function UpgradeConfig.costOfNext(id: string, rank: number): number?
	local upgrade = byId[id]
	if not upgrade or upgrade.availability == UpgradeConfig.PREVIEW then
		return nil
	end
	if rank >= upgrade.maxRank then
		return nil
	end
	return upgrade.costs[rank + 1]
end

-- What this node ALONE would produce at a rank. Kept for display and for the validator's
-- identity check; effective gameplay values come from `aggregate`.
function UpgradeConfig.valueAt(id: string, rank: number)
	local upgrade = byId[id]
	if not upgrade or not upgrade.values then
		return nil
	end
	return upgrade.values[math.clamp(rank + 1, 1, #upgrade.values)]
end

-- This node's cumulative contribution to its family at a rank.
function UpgradeConfig.contributionAt(id: string, rank: number): number
	local upgrade = byId[id]
	if not upgrade or not upgrade.contributions then
		return 0
	end
	local value = upgrade.contributions[math.clamp(rank + 1, 1, #upgrade.contributions)]
	return type(value) == "number" and value or 0
end

-- What the NEXT rank would add, for a detail panel that should say "+0.50 Luck".
function UpgradeConfig.nextContribution(id: string, rank: number): number?
	local upgrade = byId[id]
	if not upgrade or rank >= upgrade.maxRank then
		return nil
	end
	return UpgradeConfig.contributionAt(id, rank + 1) - UpgradeConfig.contributionAt(id, rank)
end

-- ---------------------------------------------------------------- aggregation

-- THE effective value of a family, recomputed from every owned rank. Never a running total
-- mutated by purchase deltas: a reload recomputes this from the stored ranks and must land
-- on exactly the same number.
function UpgradeConfig.aggregate(family: string, ranks: { [string]: number })
	local spec = UpgradeConfig.FAMILIES[family]
	if not spec then
		return nil
	end

	if spec.combine == "CAPABILITY" then
		for _, upgrade in ipairs(byFamily[family] or {}) do
			if (ranks[upgrade.id] or 0) > 0 then
				return true
			end
		end
		return false
	end

	local sum = 0
	for _, upgrade in ipairs(byFamily[family] or {}) do
		sum += UpgradeConfig.contributionAt(upgrade.id, ranks[upgrade.id] or 0)
	end

	if spec.combine == "SUBTRACT" then
		local total = (spec.base or 0) - sum
		if spec.floor then
			total = math.max(total, spec.floor)
		end
		return total
	end

	local total = (spec.base or 0) + sum
	if spec.max then
		total = math.min(total, spec.max)
	end
	return total
end

-- Resolve a stat key to its family total.
local statToFamily: { [string]: string } = {}
for family, spec in pairs(UpgradeConfig.FAMILIES) do
	if spec.stat then
		statToFamily[spec.stat] = family
	end
end

function UpgradeConfig.statTotal(statKey: string, ranks: { [string]: number })
	local family = statToFamily[statKey]
	if not family then
		return nil
	end
	return UpgradeConfig.aggregate(family, ranks)
end

function UpgradeConfig.familyOfStat(statKey: string): string?
	return statToFamily[statKey]
end

-- ---------------------------------------------------------------- prerequisites

-- Returns (met, reasonText, unmetRequirement).
function UpgradeConfig.requirementsMet(id: string, ranks: { [string]: number }): (boolean, string?, any?)
	local upgrade = byId[id]
	if not upgrade then
		return false, "unknown upgrade", nil
	end
	for _, requirement in ipairs(upgrade.requires) do
		local need = UpgradeConfig.requiredLevel(requirement)
		if (ranks[requirement.id] or 0) < need then
			local parent = byId[requirement.id]
			return false, ("Requires %s Lv %d"):format(
				parent and parent.displayName or requirement.id, need), requirement
		end
	end
	return true, nil, nil
end

function UpgradeConfig.unmetRequirements(id: string, ranks: { [string]: number })
	local upgrade = byId[id]
	local out = {}
	if not upgrade then
		return out
	end
	for _, requirement in ipairs(upgrade.requires) do
		local need = UpgradeConfig.requiredLevel(requirement)
		if (ranks[requirement.id] or 0) < need then
			local parent = byId[requirement.id]
			table.insert(out, {
				id = requirement.id,
				level = need,
				title = parent and parent.displayName or requirement.id,
			})
		end
	end
	return out
end

-- ---------------------------------------------------------------- marginal efficiency
--
-- Tiers must not make each other pointless. If Luck II rank 1 delivered more Luck per Ticket
-- than every remaining Luck I rank, those ranks would become dead content the moment Luck II
-- unlocked -- the player would simply stop buying them.
--
-- The intended shape is the opposite: remaining Tier I ranks stay the CHEAPER efficient
-- option, while a higher tier offers larger but less efficient jumps. This report makes that
-- checkable rather than a matter of opinion, and `dominates` names any node that beats every
-- cheaper same-family rank on both axes at once.

-- Contribution gained per Ticket spent, for each purchasable rank of a family.
function UpgradeConfig.marginalReport(family: string)
	local rows = {}
	for _, upgrade in ipairs(byFamily[family] or {}) do
		for rank = 0, upgrade.maxRank - 1 do
			local cost = upgrade.costs[rank + 1]
			local delta = UpgradeConfig.contributionAt(upgrade.id, rank + 1)
				- UpgradeConfig.contributionAt(upgrade.id, rank)
			if cost and cost > 0 then
				table.insert(rows, {
					id = upgrade.id,
					displayName = upgrade.displayName,
					tier = upgrade.tier,
					toRank = rank + 1,
					cost = cost,
					delta = delta,
					perTicket = delta / cost,
				})
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.perTicket ~= b.perTicket then
			return a.perTicket > b.perTicket
		end
		return a.cost < b.cost
	end)
	return rows
end

-- A node DOMINATES if some rank of it is both cheaper than and more efficient than every
-- remaining rank of a lower tier in the same family. Returns a list of offending ids.
function UpgradeConfig.dominatingNodes(family: string)
	local rows = UpgradeConfig.marginalReport(family)
	local offenders = {}
	for _, row in ipairs(rows) do
		if row.tier > 1 then
			local beatsAll, sawLower = true, false
			for _, other in ipairs(rows) do
				if other.tier < row.tier then
					sawLower = true
					if not (row.cost <= other.cost and row.perTicket >= other.perTicket) then
						beatsAll = false
					end
				end
			end
			if sawLower and beatsAll then
				table.insert(offenders, ("%s -> rank %d"):format(row.id, row.toRank))
			end
		end
	end
	return offenders
end

-- ---------------------------------------------------------------- validation

local function validate()
	local seen: { [string]: boolean } = {}
	for index, upgrade in ipairs(UPGRADES) do
		local where = ("UpgradeConfig.UPGRADES[%d] (%s)"):format(index, tostring(upgrade.id))
		assert(type(upgrade.id) == "string" and #upgrade.id > 0, where .. ": id must be a non-empty string")
		assert(not seen[upgrade.id], where .. ": duplicate id")
		seen[upgrade.id] = true
		assert(type(upgrade.displayName) == "string" and #upgrade.displayName > 0,
			where .. ": displayName is required")
		assert(type(upgrade.short) == "string" and #upgrade.short > 0 and #upgrade.short <= 7,
			where .. ": short must be a 1-7 character board label")
		assert(UpgradeConfig.FAMILIES[upgrade.family], where .. ": unknown family " .. tostring(upgrade.family))
		assert(type(upgrade.tier) == "number" and upgrade.tier >= 0, where .. ": tier must be >= 0")
		assert(upgrade.availability == UpgradeConfig.AVAILABLE
			or upgrade.availability == UpgradeConfig.PREVIEW, where .. ": bad availability")
		assert(type(upgrade.resetGroup) == "string", where .. ": resetGroup is required")

		assert(type(upgrade.maxRank) == "number" and upgrade.maxRank >= 0, where .. ": maxRank must be >= 0")
		assert(#upgrade.costs == upgrade.maxRank,
			where .. (": needs exactly %d costs for %d ranks, has %d")
				:format(upgrade.maxRank, upgrade.maxRank, #upgrade.costs))
		for rank, cost in ipairs(upgrade.costs) do
			assert(type(cost) == "number" and cost > 0 and cost == math.floor(cost),
				where .. (": cost %d must be a positive integer"):format(rank))
			if rank > 1 then
				assert(cost > upgrade.costs[rank - 1],
					where .. (": cost %d must exceed the previous rank"):format(rank))
			end
		end

		if upgrade.availability == UpgradeConfig.PREVIEW then
			assert(upgrade.maxRank == 0 and not upgrade.stat and #upgrade.costs == 0,
				where .. ": a preview node must have no ranks, no stat and no costs")
		end

		if upgrade.values then
			assert(#upgrade.values == upgrade.maxRank + 1,
				where .. ": values must have one more entry than maxRank (index 1 is rank 0)")
		end
		if upgrade.contributions then
			assert(#upgrade.contributions == upgrade.maxRank + 1,
				where .. ": contributions must have one more entry than maxRank")
			assert(upgrade.contributions[1] == 0, where .. ": rank 0 must contribute nothing")
			for rank = 2, #upgrade.contributions do
				assert(upgrade.contributions[rank] >= upgrade.contributions[rank - 1],
					where .. (": contribution %d must not decrease"):format(rank - 1))
			end
		end
		if upgrade.stat then
			assert(upgrade.contributions, where .. ": an upgrade with a stat must define contributions")
		end
	end

	-- IDENTITY CHECK. For a family with exactly ONE ranked member, the aggregate must
	-- reproduce that member's legacy `values` table at every rank. This is what proves the
	-- family refactor did not move a single number.
	for family, members in pairs(byFamily) do
		local spec = UpgradeConfig.FAMILIES[family]
		local ranked = {}
		for _, upgrade in ipairs(members) do
			if upgrade.maxRank > 0 then
				table.insert(ranked, upgrade)
			end
		end
		if #ranked == 1 and spec.combine ~= "CAPABILITY" and ranked[1].values then
			local only = ranked[1]
			for rank = 0, only.maxRank do
				local aggregated = UpgradeConfig.aggregate(family, { [only.id] = rank })
				local legacy = only.values[rank + 1]
				assert(math.abs(aggregated - legacy) < 1e-9,
					("UpgradeConfig: %s rank %d aggregates to %.4f but its legacy value is %.4f")
						:format(only.id, rank, aggregated, legacy))
			end
		end
	end

	-- Every requirement must name a real upgrade at a reachable, explicitly-legal level.
	for _, upgrade in ipairs(UPGRADES) do
		for _, requirement in ipairs(upgrade.requires) do
			local target = byId[requirement.id]
			assert(target, ("%s requires unknown upgrade %s"):format(upgrade.id, tostring(requirement.id)))
			local need = UpgradeConfig.requiredLevel(requirement)
			assert(type(need) == "number" and need >= 0 and need == math.floor(need),
				("%s requires %s at a non-integer level"):format(upgrade.id, requirement.id))
			assert(need <= target.maxRank,
				("%s requires %s Lv %d, above its cap of %d")
					:format(upgrade.id, requirement.id, need, target.maxRank))

			-- NO IMPLICIT MAX GATE. A multi-rank parent may never be required at its final
			-- rank: children must reveal while the parent is still worth levelling. Binary
			-- (maxRank 1) unlocks are exempt because owning them IS level 1.
			if target.maxRank > 1 then
				assert(need <= target.maxRank - 1,
					("%s requires %s at its MAX rank (%d). Prerequisites must unlock before MAX.")
						:format(upgrade.id, requirement.id, need))
			end
		end
	end

	-- NO CYCLES. A prerequisite loop would make every node in it permanently unreachable.
	local state: { [string]: number } = {}
	local function visit(id: string)
		if state[id] == 2 then
			return
		end
		assert(state[id] ~= 1, "UpgradeConfig: prerequisite cycle through " .. id)
		state[id] = 1
		for _, requirement in ipairs(byId[id].requires) do
			visit(requirement.id)
		end
		state[id] = 2
	end
	for _, upgrade in ipairs(UPGRADES) do
		visit(upgrade.id)
	end

	-- One family may own a stat, and a stat may be owned by one family.
	local statOwner: { [string]: string } = {}
	for family, spec in pairs(UpgradeConfig.FAMILIES) do
		if spec.stat then
			local owner = statOwner[spec.stat]
			if owner then
				error(("UpgradeConfig: families %s and %s both drive stat %s")
					:format(owner, family, spec.stat), 0)
			end
			statOwner[spec.stat] = family
		end
	end
	-- A node's own stat must match its family's stat, or aggregation would silently ignore it.
	for _, upgrade in ipairs(UPGRADES) do
		if upgrade.stat then
			local spec = UpgradeConfig.FAMILIES[upgrade.family]
			assert(spec.stat == upgrade.stat,
				("%s declares stat %s but its family %s drives %s")
					:format(upgrade.id, upgrade.stat, upgrade.family, tostring(spec.stat)))
		end
	end

	-- NO TIER MAY DOMINATE. A higher tier that is both cheaper and more efficient than every
	-- remaining lower-tier rank would turn those ranks into dead content on the day it
	-- unlocked. Caught here rather than discovered by a player who stopped buying Luck I.
	for family in pairs(UpgradeConfig.FAMILIES) do
		local offenders = UpgradeConfig.dominatingNodes(family)
		assert(#offenders == 0,
			("UpgradeConfig: %s dominates every cheaper rank in family %s")
				:format(table.concat(offenders, ", "), family))
	end
end

validate()

return UpgradeConfig
