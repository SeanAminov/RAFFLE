--!strict
-- The reusable right-hand navigation button.
--
-- Saturated fill, thick dark border, chunky outlined text and a faint inset stud grid --
-- the reference's signature treatment, built from UI primitives so it needs no asset.
--
-- Driven entirely by DATA (label, accent, order, icon, badge). Adding Inventory, Zones,
-- Rebirth, Shop, Index or Achievements later is one more table row, not another script.
-- This stage deliberately creates only UPGRADES; the component simply exists so those
-- later buttons cannot drift into a different look.

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))

local NavButton = {}
NavButton.__index = NavButton

-- config: { label, accent, order, icon?, onActivated }
function NavButton.new(parent: Instance, config)
	local self = setmetatable({}, NavButton)

	local button = Instance.new("TextButton")
	button.Name = config.label
	button.AutoButtonColor = false
	button.BackgroundColor3 = config.accent
	button.BorderSizePixel = 0
	button.Size = UDim2.new(1, 0, 0, 58)
	button.LayoutOrder = config.order or 1
	button.Text = ""
	button.Parent = parent
	UITheme.corner(button, UITheme.CORNER.large)
	UITheme.stroke(button, UITheme.STROKE.thick)

	-- moulded-plastic inset grid
	UITheme.studPattern(button, 9, 3, 0.9)

	local label = UITheme.label(button, config.label:upper(), UITheme.TEXT_SIZE.large)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.ZIndex = 3

	-- Affordance badge. Hidden until the server says something is buyable.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -6, 0, -6)
	badge.Size = UDim2.fromOffset(22, 22)
	badge.BackgroundColor3 = UITheme.COLOR.green
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 5
	badge.Parent = button
	UITheme.corner(badge, UITheme.CORNER.pill)
	UITheme.stroke(badge, UITheme.STROKE.normal)

	local badgeText = UITheme.label(badge, "!", UITheme.TEXT_SIZE.small)
	badgeText.Size = UDim2.fromScale(1, 1)
	badgeText.TextXAlignment = Enum.TextXAlignment.Center
	badgeText.ZIndex = 6

	self.instance = button
	self.badge = badge
	self.accent = config.accent
	self.selected = false

	local function tint(colour: Color3)
		TweenService:Create(button, UITheme.EASE_PRESS, { BackgroundColor3 = colour }):Play()
	end
	local function lighten(colour: Color3, amount: number)
		return Color3.new(
			math.clamp(colour.R + amount, 0, 1),
			math.clamp(colour.G + amount, 0, 1),
			math.clamp(colour.B + amount, 0, 1))
	end

	button.MouseEnter:Connect(function()
		if not self.selected then
			tint(lighten(self.accent, 0.06))
		end
	end)
	button.MouseLeave:Connect(function()
		if not self.selected then
			tint(self.accent)
		end
	end)
	-- The nav tiles are the one place the imperative press survives, because they predate the
	-- kit and re-sizing the BUTTON (rather than an inner face) is load-bearing for the column
	-- layout. Left alone deliberately: it is not broken, and porting it would risk the one
	-- part of the HUD the player touches most.
	button.MouseButton1Down:Connect(function()
		tint(lighten(self.accent, -0.10))
		TweenService:Create(button, UITheme.EASE_PRESS, { Size = UDim2.new(1, -6, 0, 54) }):Play()
	end)
	local function release()
		tint(self.selected and lighten(self.accent, 0.10) or self.accent)
		TweenService:Create(button, UITheme.EASE_PRESS, { Size = UDim2.new(1, 0, 0, 58) }):Play()
	end
	button.MouseButton1Up:Connect(release)
	button.MouseLeave:Connect(release)
	button.Activated:Connect(function()
		if config.onActivated then
			config.onActivated()
		end
	end)

	return self
end

function NavButton:setBadge(visible: boolean)
	self.badge.Visible = visible
end

function NavButton:setSelected(selected: boolean)
	self.selected = selected
	local target = selected
		and Color3.new(
			math.clamp(self.accent.R + 0.10, 0, 1),
			math.clamp(self.accent.G + 0.10, 0, 1),
			math.clamp(self.accent.B + 0.10, 0, 1))
		or self.accent
	TweenService:Create(self.instance, UITheme.EASE_PRESS, { BackgroundColor3 = target }):Play()
end

function NavButton:setHeight(height: number)
	self.instance.Size = UDim2.new(1, 0, 0, height)
end

return NavButton
