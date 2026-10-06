--!strict
-- MUTATIONS: a second, independent property a rolled ball may carry.
--
-- A mutation is NOT a rarity. The ball's identity -- its "1 IN X" -- is decided first and is
-- never touched by this file. The mutation roll happens once, immediately afterwards, inside
-- the same immutable record, and only ever ADDS a value multiplier.
--
-- ONE ROLL, ONE SNAPSHOT. RollService calls `roll` exactly once per record and freezes the
-- result. Nothing rerolls a mutation: not the hopper, not a bumper, not a drain, not cleanup,
-- and not a later Mutations purchase.
--
-- ADDING A MUTATION IS A ROW. The selector below is the same tail-walk LuckMath already uses
-- for the ball catalog, so a second and third mutation slot in without RollService, the queue
-- or settlement changing at all: order them common -> rare, give each a per-rank denominator,
-- and the maths stays exact.
--
-- LUCK APPLIES, BUT LUCK IS STILL THE PRIME STAT FOR RARITY. Effective mutation chance is
--     E(L) = 1 - (1 - BaseChance)^L
-- which is the identical formula, and the identical code path, used for ball tails.

local LuckMath = require(script.Parent:WaitForChild("LuckMath"))

local MutationCatalog = {}

-- Rank 0 is DISABLED: index 1 of `oneInByRank` is rank 0 and is deliberately `nil`, so a
-- player who has not bought Mutations cannot roll one at any Luck.
--
-- Ordered COMMON -> RARE, like BallCatalog. With one entry that ordering is trivial; it is
-- declared anyway so the invariant is already enforced when a second mutation arrives.
local MUTATIONS = {
	{
		id = "CHARGED",
		name = "Charged",
		valueMultiplier = 3.0,
		oneInByRank = { nil, 40, 32, 25, 18, 12 },
		tint = Color3.fromRGB(120, 214, 255),
		rim = Color3.fromRGB(168, 236, 255),
		blurb = "Crackling with stored charge. Triples what the ball settles for.",
	},
}

MutationCatalog.MUTATIONS = MUTATIONS
MutationCatalog.MAX_RANK = 5

-- The identity used by every record that did not mutate. Kept as a real object rather than
-- nil so callers never branch on nil-ness and accidentally skip the multiplier.
MutationCatalog.NONE = table.freeze({
	id = "NONE",
	name = "",
	valueMultiplier = 1.0,
	tint = Color3.fromRGB(206, 214, 230),
})

local byId: { [string]: any } = { NONE = MutationCatalog.NONE }
for index, entry in ipairs(MUTATIONS) do
	entry.index = index
	byId[entry.id] = entry
end

function MutationCatalog.get(id: string?)
	if not id then
		return MutationCatalog.NONE
	end
	return byId[id] or MutationCatalog.NONE
end

-- The entries available at a rank, as LuckMath-shaped rows. A mutation with no denominator
-- at this rank is simply absent, so rank 0 yields an empty list and can never select.
local function entriesAtRank(rank: number)
	local out = {}
	for _, entry in ipairs(MUTATIONS) do
		local oneIn = entry.oneInByRank[math.clamp(rank, 0, MutationCatalog.MAX_RANK) + 1]
		if oneIn then
			table.insert(out, { oneIn = oneIn, source = entry })
		end
	end
	return out
end

MutationCatalog.entriesAtRank = entriesAtRank

-- Base (Luck x1) chance of a specific mutation at a rank. 0 when it cannot occur.
function MutationCatalog.baseChance(id: string, rank: number): number
	local entries = entriesAtRank(rank)
	for _, row in ipairs(entries) do
		if row.source.id == id then
			return 1 / row.oneIn
		end
	end
	return 0
end

-- Effective chance at a Luck value: E(L) = 1 - (1 - base)^L, evaluated by the same
-- expm1/log1p path the ball tails use so tiny chances keep their precision.
function MutationCatalog.effectiveChance(id: string, rank: number, luck: number): number
	local entries = entriesAtRank(rank)
	if #entries == 0 then
		return 0
	end
	local index = nil
	for i, row in ipairs(entries) do
		if row.source.id == id then
			index = i
		end
	end
	if not index then
		return 0
	end
	local chances = LuckMath.chances(entries, luck)
	return chances[index]
end

-- Chance that a roll at this rank and Luck mutates AT ALL.
function MutationCatalog.anyChance(rank: number, luck: number): number
	local entries = entriesAtRank(rank)
	if #entries == 0 then
		return 0
	end
	return LuckMath.chanceOfThisOrBetter(entries, 1, luck)
end

-- THE selection. `sample` is a uniform [0,1) drawn by the server and nothing else.
-- Returns (entry, baseChance, effectiveChance) -- always a real entry, NONE when it misses.
function MutationCatalog.roll(rank: number, luck: number, sample: number)
	local entries = entriesAtRank(rank)
	if #entries == 0 then
		return MutationCatalog.NONE, 0, 0
	end
	local index = LuckMath.selectIndex(entries, luck, sample)
	if not index then
		return MutationCatalog.NONE, 0, 0
	end
	local row = entries[index]
	local chances = LuckMath.chances(entries, luck)
	return row.source, 1 / row.oneIn, chances[index]
end

-- ---------------------------------------------------------------- validation

local function validate()
	local seen: { [string]: boolean } = { NONE = true }
	for index, entry in ipairs(MUTATIONS) do
		local where = ("MutationCatalog.MUTATIONS[%d] (%s)"):format(index, tostring(entry.id))
		assert(type(entry.id) == "string" and #entry.id > 0, where .. ": id must be a non-empty string")
		assert(not seen[entry.id], where .. ": duplicate id")
		seen[entry.id] = true
		assert(type(entry.valueMultiplier) == "number" and entry.valueMultiplier >= 1,
			where .. ": valueMultiplier must be >= 1 -- a mutation may never reduce a payout")
		assert(#entry.oneInByRank == MutationCatalog.MAX_RANK + 1,
			where .. (": oneInByRank needs %d entries (index 1 is rank 0)")
				:format(MutationCatalog.MAX_RANK + 1))
		assert(entry.oneInByRank[1] == nil, where .. ": rank 0 must be disabled")
		local previous = math.huge
		for rank = 1, MutationCatalog.MAX_RANK do
			local oneIn = entry.oneInByRank[rank + 1]
			assert(type(oneIn) == "number" and oneIn > 1,
				where .. (": rank %d denominator must be a number > 1"):format(rank))
			assert(oneIn < previous,
				where .. (": rank %d must be more likely than rank %d"):format(rank, rank - 1))
			previous = oneIn
		end
	end

	-- Ordered common -> rare at every rank, and never able to consume the whole space.
	for rank = 0, MutationCatalog.MAX_RANK do
		local entries = entriesAtRank(rank)
		local previous, sum = 0, 0
		for i, row in ipairs(entries) do
			assert(row.oneIn > previous,
				("MutationCatalog: rank %d is not ordered common -> rare at entry %d"):format(rank, i))
			previous = row.oneIn
			sum += 1 / row.oneIn
		end
		assert(sum < 1,
			("MutationCatalog: rank %d mutation chances sum to %.4f, leaving no unmutated result")
				:format(rank, sum))
	end
end

validate()

return MutationCatalog
