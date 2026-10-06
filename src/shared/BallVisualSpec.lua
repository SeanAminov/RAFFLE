--!strict
-- THE PRESENTATION CONTRACT FOR A BALL.
--
-- BallCatalog owns identity, odds, value and physical material. This module owns none of
-- those things: it translates an already-resolved ball/variant into semantic visual roles
-- that any client renderer can consume. Collection cards, roll reveals and (later) physical
-- ball cosmetics therefore cannot quietly invent three different versions of the same ball.
--
-- The contract deliberately includes dormant motif slots (accent, core and pips). BallIcon
-- always creates those bounded layers and toggles their transparency, which preserves Vide's
-- pooled-card invariant: rebinding a card changes properties, never its instance tree. The
-- next design pass can give each catalog ball its own motif by editing BALL_SPECS here.

local BallVisualSpec = {}

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)

local SILHOUETTE = Color3.fromRGB(30, 33, 48)
local SILHOUETTE_RIM = Color3.fromRGB(18, 20, 30)
local SILHOUETTE_GLOW = Color3.fromRGB(44, 48, 66)

-- Every ball currently uses this polished-shell baseline. Per-ball entries will be filled in
-- during the dedicated redesign step; keeping the table here now makes that work data-only.
local DEFAULT_SPEC = table.freeze({
	gradientRotation = 115,
	accentTransparency = 1,
	accentRotation = 22,
	accentWidth = 0.22,
	coreTransparency = 1,
	coreScale = 0.42,
	pipTransparency = 1,
})

local BALL_SPECS: { [string]: any } = table.freeze({})

BallVisualSpec.DEFAULT = DEFAULT_SPEC
BallVisualSpec.BALLS = BALL_SPECS

local function shifted(base: Color3, target: Color3, amount: number): Color3
	return base:Lerp(target, math.clamp(amount, 0, 1))
end

function BallVisualSpec.forBall(ballId: string?)
	if ballId then
		return BALL_SPECS[ballId] or DEFAULT_SPEC
	end
	return DEFAULT_SPEC
end

-- Produces colours and visibility in the exact shape BallIcon consumes. This is intentionally
-- allocation-light: BallIcon wraps it in one Vide derive, so it runs only when a pooled slot
-- is rebound or a reveal changes, never every frame.
function BallVisualSpec.resolve(info, discovered: boolean?)
	local isDiscovered = discovered ~= false and info ~= nil
	local spec = BallVisualSpec.forBall(info and info.ballId)

	if not isDiscovered then
		return {
			body = SILHOUETTE,
			shade = shifted(SILHOUETTE, BLACK, 0.28),
			highlight = shifted(SILHOUETTE, WHITE, 0.18),
			rim = SILHOUETTE_RIM,
			glow = SILHOUETTE_GLOW,
			glowTransparency = 0.88,
			mutationRing = WHITE,
			mutationRingTransparency = 1,
			accent = SILHOUETTE_GLOW,
			accentTransparency = 1,
			accentRotation = spec.accentRotation,
			accentWidth = spec.accentWidth,
			core = SILHOUETTE_RIM,
			coreTransparency = 1,
			coreScale = spec.coreScale,
			pip = SILHOUETTE_GLOW,
			pipTransparency = 1,
			gradientRotation = spec.gradientRotation,
			glintTransparency = 0.82,
		}
	end

	local body = info.colour or Color3.fromRGB(206, 214, 230)
	local tint = info.tint or body
	local mutationId = info.mutationId or "NONE"
	local mutated = info.mutated == true or mutationId ~= "NONE"

	return {
		body = body,
		shade = shifted(body, BLACK, 0.34),
		highlight = shifted(body, WHITE, 0.42),
		rim = shifted(body, BLACK, 0.58),
		glow = tint,
		glowTransparency = 0.62,
		mutationRing = info.mutationTint or tint,
		mutationRingTransparency = mutated and 0.12 or 1,
		accent = spec.accent or shifted(body, WHITE, 0.28),
		accentTransparency = spec.accentTransparency,
		accentRotation = spec.accentRotation,
		accentWidth = spec.accentWidth,
		core = spec.core or shifted(body, BLACK, 0.18),
		coreTransparency = spec.coreTransparency,
		coreScale = spec.coreScale,
		pip = spec.pip or shifted(body, WHITE, 0.55),
		pipTransparency = spec.pipTransparency,
		gradientRotation = spec.gradientRotation,
		glintTransparency = 0.28,
	}
end

return BallVisualSpec
