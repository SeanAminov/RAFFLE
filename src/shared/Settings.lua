--!strict
-- CLIENT PRESENTATION SETTINGS. Session-local, never replicated, never authoritative.
--
-- Every value here changes only what is DRAWN. None of it reaches the server, and none of it
-- can reach RNG, physics, hopper cadence, reward totals, settlement, or the number of server
-- instances -- the server has no inbound remote for any of it and never asks the client what
-- its settings are. A Minimal-effects client and a Full-effects client produce byte-identical
-- authoritative ledgers; that equivalence is a required test, not an aspiration.
--
-- This module holds the ENUMS and the POLICY (what each level suppresses). The client
-- Presenter is the single consumer -- no other file may branch on a settings value, so
-- "does this effect play?" has exactly one answer in exactly one place.

local Settings = {}

-- ---------------------------------------------------------------- enumerations

Settings.HIT_NUMBERS = { ALL = "ALL", IMPORTANT = "IMPORTANT", OFF = "OFF" }
Settings.HIT_NUMBERS_ORDER = { "ALL", "IMPORTANT", "OFF" }

Settings.EFFECTS = { FULL = "FULL", REDUCED = "REDUCED", MINIMAL = "MINIMAL" }
Settings.EFFECTS_ORDER = { "FULL", "REDUCED", "MINIMAL" }

Settings.DEFAULTS = {
	hitNumbers = Settings.HIT_NUMBERS.ALL,
	effects = Settings.EFFECTS.FULL,
	reducedMotion = false,
	sound = true,
}

-- ---------------------------------------------------------------- importance

-- What counts as IMPORTANT. A hit number survives the IMPORTANT filter when it is a drain
-- settlement, a mutation, a rare ball, or simply a big number -- the moments a player would
-- be annoyed to miss. Ordinary repeated bumper trickle is what gets suppressed.
Settings.IMPORTANT_MIN_POINTS = 150
Settings.IMPORTANT_MIN_ONE_IN = 200

-- kind is "hit" | "drain" | "mutation" | "bonus"
function Settings.isImportant(kind: string, points: number, oneIn: number?): boolean
	if kind == "drain" or kind == "mutation" or kind == "bonus" then
		return true
	end
	if oneIn and oneIn >= Settings.IMPORTANT_MIN_ONE_IN then
		return true
	end
	return points >= Settings.IMPORTANT_MIN_POINTS
end

-- ---------------------------------------------------------------- policy
--
-- One table, read top to bottom, rather than a scatter of `if level == "MINIMAL"` branches.
-- `popupCap` is also the hard ceiling on live floating labels at that level.

local POLICY = {
	FULL = {
		impactParticles = true,
		ballTrails = true,
		bumperFlash = true,
		sparks = true,
		popupCap = 14,
		bounceScale = 1.00,
		-- Minimum seconds between two hit numbers for the SAME target. Coalescing merges
		-- the visuals; it never merges or drops the server's actual award.
		coalesceWindow = 0.00,
	},
	REDUCED = {
		impactParticles = false,
		ballTrails = true,
		bumperFlash = true,
		sparks = false,
		popupCap = 8,
		bounceScale = 0.60,
		coalesceWindow = 0.18,
	},
	MINIMAL = {
		impactParticles = false,
		ballTrails = false,
		bumperFlash = false,
		sparks = false,
		popupCap = 4,
		bounceScale = 0.00,
		coalesceWindow = 0.35,
	},
}

function Settings.policy(effects: string)
	return POLICY[effects] or POLICY.FULL
end

-- Reduced Motion is a separate axis from Effects: it flattens UI motion without touching
-- world effects, because the two disable for different reasons.
function Settings.bounceScale(effects: string, reducedMotion: boolean): number
	if reducedMotion then
		return 0
	end
	return Settings.policy(effects).bounceScale
end

-- ---------------------------------------------------------------- never hidden
--
-- Declared as data so the required "never hide" list is checkable rather than a comment.
-- The Presenter asserts against this: anything named here is drawn at EVERY level.
Settings.ALWAYS_VISIBLE = {
	"physical balls",
	"rolled ball identity",
	"mutation badge",
	"Tickets balance",
	"queue state",
	"purchase confirmation",
	"drain settlement",
}

function Settings.normalise(raw)
	local out = {}
	for key, fallback in pairs(Settings.DEFAULTS) do
		local value = raw and raw[key]
		if typeof(value) == typeof(fallback) then
			out[key] = value
		else
			out[key] = fallback
		end
	end
	if not Settings.HIT_NUMBERS[out.hitNumbers] then
		out.hitNumbers = Settings.DEFAULTS.hitNumbers
	end
	if not Settings.EFFECTS[out.effects] then
		out.effects = Settings.DEFAULTS.effects
	end
	return out
end

-- ---------------------------------------------------------------- validation

local function validate()
	for _, name in ipairs(Settings.EFFECTS_ORDER) do
		local policy = POLICY[name]
		assert(policy, "Settings: no policy for effects level " .. name)
		assert(type(policy.popupCap) == "number" and policy.popupCap >= 1,
			"Settings: " .. name .. " popupCap must be >= 1")
	end
	-- Each step down must be no more permissive than the one above it, so "Reduced" can
	-- never accidentally show more than "Full".
	for i = 2, #Settings.EFFECTS_ORDER do
		local above = POLICY[Settings.EFFECTS_ORDER[i - 1]]
		local here = POLICY[Settings.EFFECTS_ORDER[i]]
		for _, key in ipairs({ "impactParticles", "ballTrails", "bumperFlash", "sparks" }) do
			assert(not (here[key] and not above[key]),
				("Settings: %s enables %s but %s does not")
					:format(Settings.EFFECTS_ORDER[i], key, Settings.EFFECTS_ORDER[i - 1]))
		end
		assert(here.popupCap <= above.popupCap, "Settings: popupCap must not rise as effects fall")
		assert(here.bounceScale <= above.bounceScale, "Settings: bounceScale must not rise as effects fall")
		assert(here.coalesceWindow >= above.coalesceWindow,
			"Settings: coalesceWindow must not shrink as effects fall")
	end
end

validate()

return Settings
