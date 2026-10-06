--!strict
-- ONE BOUNDED, REUSABLE 2D BALL RENDERER.
--
-- This is the only module that turns BallVisualSpec into GuiObjects. It is used by both the
-- virtualised Collection and the roll reveal. `props.info` and `props.discovered` may be plain
-- values or Vide sources/derives. All motif layers always exist and only their properties
-- change, so a pooled Collection card can safely rebind from any variant to any other.
--
-- Instance cost is fixed: one icon is 22 GuiObjects/effects whether it shows Basic, a future
-- elaborate ball, or a locked silhouette. There are no events, loops or per-icon animation
-- connections here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BallVisualSpec = require(Shared:WaitForChild("BallVisualSpec"))
local vide = require(Shared:WaitForChild("Vide"))

local create = vide.create
local derive = vide.derive

local BallIcon = {}

local function read(value)
	if type(value) == "function" then
		return value()
	end
	return value
end

local function round()
	return create("UICorner") { CornerRadius = UDim.new(1, 0) }
end

local function pip(style, x: number, y: number, zindex: number)
	return create("Frame") {
		Name = "Pip",
		BackgroundColor3 = function() return style().pip end,
		BackgroundTransparency = function() return style().pipTransparency end,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(0.13, 0.13),
		ZIndex = zindex,
		round(),
	}
end

function BallIcon.new(props)
	local zindex = props.zindex or 3
	local style = derive(function()
		return BallVisualSpec.resolve(read(props.info), read(props.discovered))
	end)

	return create("Frame") {
		Name = props.name or "BallIcon",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = props.anchor or Vector2.new(0.5, 0),
		Position = props.position,
		Size = props.size or UDim2.fromOffset(62, 62),
		ZIndex = zindex,

		create("UIAspectRatioConstraint") { AspectRatio = 1 },

		-- Rarity glow plus mutation identity ring. The ring is result information, not an
		-- optional effect, so it stays visible independently of the Effects setting.
		create("Frame") {
			Name = "Aura",
			BackgroundColor3 = function() return style().glow end,
			BackgroundTransparency = function() return style().glowTransparency end,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			ZIndex = zindex,
			round(),
			create("UIStroke") {
				Thickness = 3,
				Color = function() return style().mutationRing end,
				Transparency = function() return style().mutationRingTransparency end,
			},
		},

		-- A shallow offset shadow grounds the token without needing an image asset.
		create("Frame") {
			Name = "Shadow",
			BackgroundColor3 = Color3.fromRGB(5, 6, 12),
			BackgroundTransparency = 0.18,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.56),
			Size = UDim2.fromScale(0.84, 0.84),
			ZIndex = zindex + 1,
			round(),
		},

		create("Frame") {
			Name = "Shell",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ClipsDescendants = true,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.84, 0.84),
			ZIndex = zindex + 2,
			round(),
			create("UIStroke") {
				Thickness = 3,
				Color = function() return style().rim end,
			},
			create("UIGradient") {
				Rotation = function() return style().gradientRotation end,
				Color = function()
					local current = style()
					return ColorSequence.new({
						ColorSequenceKeypoint.new(0, current.highlight),
						ColorSequenceKeypoint.new(0.43, current.body),
						ColorSequenceKeypoint.new(1, current.shade),
					})
				end,
			},

			-- Fixed motif slots. They are invisible in the baseline and become the vocabulary
			-- for the next, per-ball redesign step without rebuilding pooled cards.
			create("Frame") {
				Name = "AccentBand",
				BackgroundColor3 = function() return style().accent end,
				BackgroundTransparency = function() return style().accentTransparency end,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Rotation = function() return style().accentRotation end,
				Size = function() return UDim2.fromScale(style().accentWidth, 1.45) end,
				ZIndex = zindex + 3,
			},
			create("Frame") {
				Name = "Core",
				BackgroundColor3 = function() return style().core end,
				BackgroundTransparency = function() return style().coreTransparency end,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = function()
					local scale = style().coreScale
					return UDim2.fromScale(scale, scale)
				end,
				ZIndex = zindex + 4,
				round(),
			},
			pip(style, 0.34, 0.36, zindex + 5),
			pip(style, 0.65, 0.46, zindex + 5),
			pip(style, 0.43, 0.68, zindex + 5),

			-- One restrained specular glint makes even the baseline shell read as a material,
			-- not a flat coloured circle.
			create("Frame") {
				Name = "Glint",
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = function() return style().glintTransparency end,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.32, 0.27),
				Rotation = -24,
				Size = UDim2.fromScale(0.28, 0.12),
				ZIndex = zindex + 6,
				round(),
			},
		},
	}
end

return BallIcon
