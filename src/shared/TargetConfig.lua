--!strict
-- The scoring ATTRIBUTE CONTRACT.
--
-- This module used to also hold target placements, which duplicated what TableSpec now
-- owns. Placement, scoring values and cooldowns live in TableSpec alongside the rest of
-- the layout; this file is only the shared vocabulary for stamping and reading them.
--
-- Why the split matters: geometry stamps these attributes onto parts, and the scoring
-- service reads ONLY these attributes. Neither side needs a per-target branch, so adding
-- a future bumper or target is a TableSpec row plus a rebuild.
--
-- No scoring logic exists yet. The current stage builds an inert table that already
-- carries the contract, so wiring it later requires no geometry changes.

local TargetConfig = {}

TargetConfig.ATTR_ID = "TargetId"
TargetConfig.ATTR_SCORE = "BaseScore"
TargetConfig.ATTR_COOLDOWN = "HitCooldown"
TargetConfig.ATTR_ENABLED = "Enabled"
TargetConfig.ATTR_STYLE = "Style"

TargetConfig.ATTRIBUTES = {
	TargetConfig.ATTR_ID,
	TargetConfig.ATTR_SCORE,
	TargetConfig.ATTR_COOLDOWN,
	TargetConfig.ATTR_ENABLED,
	TargetConfig.ATTR_STYLE,
}

export type Scorable = {
	id: string,
	score: number,
	cooldown: number,
	style: string,
	enabled: boolean?,
}

-- Refuses malformed scoring metadata rather than stamping a part that would later either
-- score nothing or score continuously.
function TargetConfig.validate(row: Scorable, where: string)
	assert(type(row.id) == "string" and #row.id > 0, where .. ": id must be a non-empty string")
	assert(type(row.score) == "number" and row.score == math.floor(row.score),
		where .. ": score must be an integer")
	-- Every contact is positive; this design has no penalties.
	assert(row.score > 0, where .. ": score must be > 0")
	assert(type(row.cooldown) == "number" and row.cooldown > 0,
		where .. ": cooldown must be > 0, or a resting ball would score continuously")
	assert(type(row.style) == "string" and #row.style > 0, where .. ": style must be a non-empty string")
end

-- Stamps a built part with everything a scoring service needs. Keeping this here means the
-- geometry builder cannot forget an attribute or invent a different name.
function TargetConfig.applyAttributes(part: Instance, row: Scorable, where: string?)
	TargetConfig.validate(row, where or row.id)
	part:SetAttribute(TargetConfig.ATTR_ID, row.id)
	part:SetAttribute(TargetConfig.ATTR_SCORE, row.score)
	part:SetAttribute(TargetConfig.ATTR_COOLDOWN, row.cooldown)
	part:SetAttribute(TargetConfig.ATTR_ENABLED, row.enabled ~= false)
	part:SetAttribute(TargetConfig.ATTR_STYLE, row.style)
end

function TargetConfig.isStamped(part: Instance): boolean
	for _, attr in ipairs(TargetConfig.ATTRIBUTES) do
		if part:GetAttribute(attr) == nil then
			return false
		end
	end
	return true
end

return TargetConfig
