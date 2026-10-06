--!strict
-- The ball catalog. ONE row per ball; adding a rarity is a row edit and nothing else.
--
-- A ball's IDENTITY is its exact denominator. "1 IN 25,000" is the canonical thing shown
-- to the player, and at x1.00 Luck it is literally the chance of getting it. The category
-- name (MYTHIC) is derived FROM that denominator and controls presentation intensity only
-- -- it never participates in the probability calculation. There are no nested tier rolls
-- and no independent rarity checks that would make the printed number a lie.
--
-- Basic is the FALLBACK. It deliberately has no denominator of its own: it receives
-- exactly whatever probability the named balls leave over, and is displayed as "BASIC".
--
-- PHYSICS IS IDENTICAL FOR EVERY BALL. Radius, density, friction and elasticity live here
-- once, at the top, and no row may override them. Rarity changes colour, material, trail
-- and economic value -- never how the ball behaves on the table.

local LuckMath = require(script.Parent:WaitForChild("LuckMath"))

local BallCatalog = {}

-- ---------------------------------------------------------------- shared physics

-- Matches the tuned prototype ball exactly. Every rarity uses these values verbatim.
BallCatalog.PHYSICS = {
	radius = 0.75,
	density = 3.2,
	friction = 0.22,
	elasticity = 0.55,
}

-- ---------------------------------------------------------------- category bands

-- Derived from the denominator, never used to compute it.
local BANDS = {
	{ name = "COMMON", max = 9, tint = Color3.fromRGB(176, 196, 222) },
	{ name = "UNCOMMON", max = 49, tint = Color3.fromRGB(96, 214, 140) },
	{ name = "RARE", max = 249, tint = Color3.fromRGB(78, 158, 246) },
	{ name = "EPIC", max = 2499, tint = Color3.fromRGB(178, 108, 246) },
	{ name = "LEGENDARY", max = 24999, tint = Color3.fromRGB(248, 182, 46) },
	{ name = "MYTHIC", max = 99999, tint = Color3.fromRGB(248, 92, 92) },
	{ name = "SECRET", max = 1000000, tint = Color3.fromRGB(252, 232, 120) },
}

BallCatalog.BASIC_BAND = { name = "BASIC", tint = Color3.fromRGB(206, 214, 230) }

function BallCatalog.bandFor(oneIn: number)
	for _, band in ipairs(BANDS) do
		if oneIn <= band.max then
			return band
		end
	end
	-- Reserved for denominators above a million, added later.
	return BANDS[#BANDS]
end

BallCatalog.BANDS = BANDS

-- ---------------------------------------------------------------- the fallback

BallCatalog.BASIC = {
	id = "BASIC",
	name = "Basic",
	oneIn = nil, -- deliberately absent: Basic is the remainder, not a denominator
	value = 1.00,
	colour = Color3.fromRGB(226, 234, 246),
	material = Enum.Material.Metal,
}

-- ---------------------------------------------------------------- named balls
--
-- MUST stay ordered common -> rare: LuckMath builds its cumulative tails off this order.

local BALLS = {
	{ id = "DOTTED", name = "Dotted", oneIn = 5, value = 1.15,
		colour = Color3.fromRGB(212, 226, 246), material = Enum.Material.Metal },
	{ id = "MINT", name = "Mint", oneIn = 12, value = 1.30,
		colour = Color3.fromRGB(126, 232, 186), material = Enum.Material.Metal },
	{ id = "SUNSET", name = "Sunset", oneIn = 30, value = 1.60,
		colour = Color3.fromRGB(250, 156, 92), material = Enum.Material.Metal },
	{ id = "RUBY", name = "Ruby", oneIn = 75, value = 2.00,
		colour = Color3.fromRGB(226, 62, 82), material = Enum.Material.Metal },
	{ id = "SAPPHIRE", name = "Sapphire", oneIn = 200, value = 2.70,
		colour = Color3.fromRGB(70, 132, 244), material = Enum.Material.Metal },
	{ id = "AMETHYST", name = "Amethyst", oneIn = 600, value = 4.00,
		colour = Color3.fromRGB(168, 96, 240), material = Enum.Material.Metal },
	{ id = "GOLDEN", name = "Golden", oneIn = 2000, value = 6.00,
		colour = Color3.fromRGB(248, 196, 62), material = Enum.Material.Metal },
	{ id = "PRISM", name = "Prism", oneIn = 7500, value = 9.00,
		colour = Color3.fromRGB(150, 240, 236), material = Enum.Material.Glass },
	{ id = "VOID", name = "Void", oneIn = 25000, value = 14.00,
		colour = Color3.fromRGB(48, 40, 78), material = Enum.Material.Metal },
	{ id = "CELESTIAL", name = "Celestial", oneIn = 100000, value = 25.00,
		colour = Color3.fromRGB(198, 226, 255), material = Enum.Material.Metal },
	{ id = "RAFFLE_CROWN", name = "Raffle Crown", oneIn = 1000000, value = 75.00,
		colour = Color3.fromRGB(255, 226, 120), material = Enum.Material.Metal },
}

BallCatalog.BALLS = BALLS

-- Presentation intensity, derived. Kept restrained on purpose: the table's own lighting
-- was tuned down deliberately and a Neon ball would undo that.
function BallCatalog.presentationFor(entry): { trail: boolean, sparkle: boolean, reveal: number }
	if not entry.oneIn then
		return { trail = false, sparkle = false, reveal = 0.25 }
	end
	return {
		trail = entry.oneIn >= 75,
		sparkle = entry.oneIn >= 2000,
		reveal = entry.oneIn >= 25000 and 1.10 or (entry.oneIn >= 600 and 0.70 or 0.35),
	}
end

local byId: { [string]: any } = {}
for index, entry in ipairs(BALLS) do
	entry.index = index
	byId[entry.id] = entry
end
byId[BallCatalog.BASIC.id] = BallCatalog.BASIC

function BallCatalog.get(id: string)
	return byId[id]
end

function BallCatalog.indexOf(id: string): number?
	local entry = byId[id]
	return entry and entry.index or nil
end

-- Exact chance of each ball at a Luck value, keyed by id, plus Basic.
function BallCatalog.chancesById(luck: number): { [string]: number }
	local chances, basic = LuckMath.chances(BALLS, luck)
	local out: { [string]: number } = {}
	for i, entry in ipairs(BALLS) do
		out[entry.id] = chances[i]
	end
	out[BallCatalog.BASIC.id] = basic
	return out
end

function BallCatalog.chanceOf(id: string, luck: number): number
	return BallCatalog.chancesById(luck)[id] or 0
end

function BallCatalog.chanceOfThisOrBetter(id: string, luck: number): number
	local index = BallCatalog.indexOf(id)
	if not index then
		return 1 -- Basic or better is everything
	end
	return LuckMath.chanceOfThisOrBetter(BALLS, index, luck)
end

-- Picks a ball from a uniform sample. The SERVER is the only caller.
function BallCatalog.select(luck: number, sample: number)
	local index = LuckMath.selectIndex(BALLS, luck, sample)
	if not index then
		return BallCatalog.BASIC
	end
	return BALLS[index]
end

-- ---------------------------------------------------------------- validation
--
-- Refuses to load rather than shipping a catalog whose printed odds are unreachable.

local function validate()
	assert(#BALLS >= 1, "BallCatalog: catalog is empty")
	local seen: { [string]: boolean } = { [BallCatalog.BASIC.id] = true }
	local sum = 0
	local previous = 0
	for i, entry in ipairs(BALLS) do
		local where = ("BallCatalog.BALLS[%d] (%s)"):format(i, tostring(entry.id))
		assert(type(entry.id) == "string" and #entry.id > 0, where .. ": id must be a non-empty string")
		assert(not seen[entry.id], where .. ": duplicate id")
		seen[entry.id] = true
		assert(type(entry.oneIn) == "number" and entry.oneIn > 0, where .. ": oneIn must be > 0")
		assert(entry.oneIn > previous, where .. ": catalog must be ordered common -> rare")
		previous = entry.oneIn
		assert(type(entry.value) == "number" and entry.value > 0, where .. ": value must be > 0")
		assert(typeof(entry.colour) == "Color3", where .. ": colour must be a Color3")
		sum += 1 / entry.oneIn
	end
	-- Basic must have real room left. If the named odds ever summed to >= 1 the fallback
	-- would be impossible and every printed denominator would be a lie.
	assert(sum < 1, ("BallCatalog: named probabilities sum to %.6f, leaving no room for Basic"):format(sum))
	assert(BallCatalog.BASIC.oneIn == nil, "BallCatalog: Basic must not be given a denominator")
end

validate()

return BallCatalog
