--!strict
-- THE STABLE IDENTITY OF A STORED BALL.
--
-- Storage is AGGREGATED: the game keeps a count per catalog variant, never one saved object
-- per rolled ball. This module defines what a "variant" is, how it is keyed, and what one is
-- prospectively worth -- and it is the ONLY place any of those three questions is answered.
--
-- A variant is (ballId, mutationId). "Basic" and "Charged Basic" are therefore genuinely
-- different stacks with independent counts and independent player controls, which is the
-- whole point: protecting a Charged Basic must not require protecting every ordinary Basic.
--
-- THE KEY IS BUILT FROM STABLE CATALOG IDS, never from a display name and never from a
-- floating-point value. "Basic" may be renamed and its value retuned; BASIC|NONE may not
-- change, because it is a persisted profile key.
--
-- SIZE. The profile scales with the number of CATALOG VARIANTS, not with the number of balls
-- owned. Twelve balls x two mutation states is 24 keys today; a million identical Basics is
-- still one key with the count 1000000 beside it.

local BallCatalog = require(script.Parent:WaitForChild("BallCatalog"))
local MutationCatalog = require(script.Parent:WaitForChild("MutationCatalog"))

local BallVariant = {}

-- A pipe cannot occur in a catalog id (the validator below proves it), so splitting is
-- unambiguous and no escaping is ever required.
BallVariant.SEPARATOR = "|"
BallVariant.NO_MUTATION = "NONE"

-- ---------------------------------------------------------------- keys

function BallVariant.key(ballId: string, mutationId: string?): string
	return ballId .. BallVariant.SEPARATOR .. (mutationId or BallVariant.NO_MUTATION)
end

function BallVariant.split(key: string): (string?, string?)
	local ballId, mutationId = key:match("^([^|]+)|([^|]+)$")
	if not ballId then
		return nil, nil
	end
	return ballId, mutationId
end

function BallVariant.isMutated(key: string): boolean
	local _, mutationId = BallVariant.split(key)
	return mutationId ~= nil and mutationId ~= BallVariant.NO_MUTATION
end

-- ---------------------------------------------------------------- the variant table
--
-- Enumerated ONCE at load from the two catalogs, so a new ball or a new mutation produces
-- its variants automatically and no list anywhere needs hand-editing.

local ORDER: { string } = {}
local INFO: { [string]: any } = {}

local function ballList()
	local out = { BallCatalog.BASIC }
	for _, entry in ipairs(BallCatalog.BALLS) do
		table.insert(out, entry)
	end
	return out
end

local function build()
	local mutations = { MutationCatalog.NONE }
	for _, mutation in ipairs(MutationCatalog.MUTATIONS) do
		table.insert(mutations, mutation)
	end

	for _, ball in ipairs(ballList()) do
		for _, mutation in ipairs(mutations) do
			local key = BallVariant.key(ball.id, mutation.id)
			-- oneIn is the CANONICAL denominator and stays exactly what the catalog says.
			-- Basic deliberately has none: it is the remainder, not a denominator. sortRarity
			-- exists only so ordering has a total, defined answer for Basic too.
			local band = ball.oneIn and BallCatalog.bandFor(ball.oneIn) or BallCatalog.BASIC_BAND
			INFO[key] = table.freeze({
				key = key,
				ballId = ball.id,
				mutationId = mutation.id,
				ballName = ball.name,
				mutationName = mutation.name,
				displayName = mutation.id == BallVariant.NO_MUTATION
					and ball.name
					or (mutation.name .. " " .. ball.name),
				oneIn = ball.oneIn,
				sortRarity = ball.oneIn or 1,
				category = band.name,
				tint = band.tint,
				colour = ball.colour,
				material = ball.material,
				mutationTint = mutation.tint,
				baseValue = ball.value,
				mutationMultiplier = mutation.valueMultiplier,
				mutated = mutation.id ~= BallVariant.NO_MUTATION,
				ballIndex = ball.index or 0,
				mutationIndex = mutation.index or 0,
			})
			table.insert(ORDER, key)
		end
	end
end

build()

BallVariant.ORDER = ORDER

function BallVariant.all(): { string }
	return ORDER
end

function BallVariant.count(): number
	return #ORDER
end

function BallVariant.info(key: string)
	return INFO[key]
end

function BallVariant.isValid(key: any): boolean
	return type(key) == "string" and INFO[key] ~= nil
end

-- Every variant of one ball, normal first. Drives the Collection card sub-stacks.
function BallVariant.variantsOfBall(ballId: string): { string }
	local out = {}
	for _, key in ipairs(ORDER) do
		if INFO[key].ballId == ballId then
			table.insert(out, key)
		end
	end
	return out
end

-- ---------------------------------------------------------------- prospective value
--
-- WHAT A STORED BALL WOULD BE WORTH IF IT DROPPED RIGHT NOW.
--
-- Rarity and mutation were fixed at roll time and live in the key. Ball Value is the
-- player's CURRENT global multiplier and is deliberately NOT fixed at roll time: a stored
-- ball benefits from a later Ball Value purchase, and is only frozen when it is reserved for
-- physical play. That is the one place the number stops moving.
--
-- This is the same function the server feed comparator, the Prize Sorter and the Collection
-- card all call, so a displayed value can never drift from the sorted one.
function BallVariant.prospectiveValue(key: string, ballValueUpgrade: number): number
	local info = INFO[key]
	if not info then
		return 0
	end
	return info.baseValue * info.mutationMultiplier * (ballValueUpgrade or 1)
end

-- Strict "is A better than B", total and DETERMINISTIC. The tie-break chain is fixed:
--   1. prospective value (base x mutation x current Ball Value)
--   2. rarity -- the rarer canonical denominator wins
--   3. stable catalog key, lexicographic -- so equal balls still have one defined winner
--
-- A total order matters more than it looks: without the final key tie-break, "best eligible"
-- would depend on table iteration order and the Prize Sorter would be untestable.
function BallVariant.isBetter(a: string, b: string, ballValueUpgrade: number): boolean
	if a == b then
		return false
	end
	local av = BallVariant.prospectiveValue(a, ballValueUpgrade)
	local bv = BallVariant.prospectiveValue(b, ballValueUpgrade)
	if av ~= bv then
		return av > bv
	end
	local ai, bi = INFO[a], INFO[b]
	if ai.sortRarity ~= bi.sortRarity then
		return ai.sortRarity > bi.sortRarity
	end
	return a < b
end

-- ---------------------------------------------------------------- validation

local function validate()
	assert(#ORDER > 0, "BallVariant: no variants were built")

	local seen: { [string]: boolean } = {}
	for _, key in ipairs(ORDER) do
		assert(not seen[key], "BallVariant: duplicate variant key " .. key)
		seen[key] = true

		-- The separator must not appear inside an id, or split() would be ambiguous and a
		-- persisted key could decode to the wrong ball.
		local info = INFO[key]
		assert(not info.ballId:find(BallVariant.SEPARATOR, 1, true),
			"BallVariant: ball id " .. info.ballId .. " contains the key separator")
		assert(not info.mutationId:find(BallVariant.SEPARATOR, 1, true),
			"BallVariant: mutation id " .. info.mutationId .. " contains the key separator")

		local ballId, mutationId = BallVariant.split(key)
		assert(ballId == info.ballId and mutationId == info.mutationId,
			"BallVariant: key " .. key .. " does not round-trip through split()")

		-- A mutation may never reduce what a ball is worth; MutationCatalog asserts the same
		-- thing about its own rows, and this proves the product respects it.
		assert(info.mutationMultiplier >= 1,
			"BallVariant: " .. key .. " has a mutation multiplier below 1")
		assert(BallVariant.prospectiveValue(key, 1) >= info.baseValue,
			"BallVariant: " .. key .. " is worth less than its unmutated form")
	end

	-- Basic must exist unmutated AND mutated: the minimum requirement is that Normal Basic
	-- and Charged Basic are independently addressable stacks.
	assert(INFO[BallVariant.key("BASIC", "NONE")], "BallVariant: BASIC|NONE is missing")
	assert(INFO[BallVariant.key("BASIC", "CHARGED")], "BallVariant: BASIC|CHARGED is missing")
	assert(BallVariant.key("BASIC", "NONE") ~= BallVariant.key("BASIC", "CHARGED"),
		"BallVariant: Basic and Charged Basic collapsed to one key")

	-- The comparator must be a STRICT TOTAL ORDER. Checked exhaustively rather than assumed,
	-- because "best eligible ball" is only meaningful if exactly one variant can win.
	for _, a in ipairs(ORDER) do
		assert(not BallVariant.isBetter(a, a, 1), "BallVariant: comparator is not irreflexive")
		for _, b in ipairs(ORDER) do
			if a ~= b then
				local ab = BallVariant.isBetter(a, b, 1)
				local ba = BallVariant.isBetter(b, a, 1)
				assert(ab ~= ba,
					("BallVariant: comparator is not antisymmetric for %s vs %s"):format(a, b))
			end
		end
	end
end

validate()

return BallVariant
