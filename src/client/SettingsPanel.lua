--!strict
-- The Settings panel: visual and performance controls, PERSISTED per player.
--
-- THIS HEADER USED TO SAY "session-local -- nothing here is sent anywhere, there is no
-- settings remote". That stopped being true on 2026-09-02, when settings gained a remote so a
-- returning player gets their choices back. The comment was not updated with the code, which
-- is the defect this note replaces: the next person would have made a change on the strength
-- of a guarantee that no longer held.
--
-- The guarantee the old wording gave STRUCTURALLY -- the server could not branch on a setting
-- because it could not know one -- now has to be stated and kept deliberately:
--
--   These controls change what is DRAWN and nothing else: not RNG, not physics, not hopper
--   cadence, not server instances, not reward totals, and not settlement.
--
--   The server STORES them and NEVER READS them. They are written to the profile and echoed
--   back once on join, and no server module outside that path may branch on a settings value.
--
-- Values are normalised through Settings.normalise on both sides, so an unreadable or hostile
-- payload can only ever produce a legal presentation config. On the client every value still
-- routes to exactly one consumer, the Presenter. See Net.lua.
--
-- The panel is deliberately compact and anchored BESIDE the right-hand navigation column
-- rather than centred, so opening it never covers the machine.
--
-- BESIDE, NOT BELOW. It used to hang under the column, which worked while there were two
-- tiles. With five, the column reaches ~390px and the panel both overlapped it and pushed its
-- own CLOSE button off the bottom of a 576px screen -- so the only way to shut it was a tile
-- the panel itself was covering. It now sits to the LEFT of the column at the same top edge,
-- and carries an X in its title row that is reachable no matter how tall the content grows.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local Settings = require(Shared:WaitForChild("Settings"))

local SettingsPanel = {}
SettingsPanel.__index = SettingsPanel

local ROW_HEIGHT = UITheme.TOUCH_MIN
local PANEL_WIDTH = 288

local function heading(parent: Instance, text: string, order: number): TextLabel
	local label = UITheme.label(parent, text, UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, 18)
	label.ZIndex = 52
	return label
end

-- A row of mutually exclusive options. Every button is a full touch target.
local function segmented(parent: Instance, order: number, options: { string }, onPick: (string) -> ())
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.ZIndex = 52
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local buttons: { [string]: TextButton } = {}
	local width = 1 / #options
	for index, option in ipairs(options) do
		local button = Instance.new("TextButton")
		button.AutoButtonColor = false
		button.BackgroundColor3 = UITheme.COLOR.slate
		button.BorderSizePixel = 0
		button.LayoutOrder = index
		button.Size = UDim2.new(width, -4, 1, 0)
		button.Text = ""
		button.ZIndex = 52
		button.Parent = row
		UITheme.corner(button, UITheme.CORNER.normal)
		UITheme.stroke(button, UITheme.STROKE.normal)

		local label = UITheme.label(button, option, UITheme.TEXT_SIZE.tiny)
		label.Size = UDim2.fromScale(1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.ZIndex = 53

		button.Activated:Connect(function()
			onPick(option)
		end)
		buttons[option] = button
	end

	return function(selected: string)
		for option, button in pairs(buttons) do
			button.BackgroundColor3 = (option == selected)
				and UITheme.COLOR.green
				or UITheme.COLOR.slate
		end
	end
end

local function toggle(parent: Instance, order: number, text: string, onFlip: () -> ())
	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.BackgroundColor3 = UITheme.COLOR.slate
	button.BorderSizePixel = 0
	button.LayoutOrder = order
	button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	button.Text = ""
	button.ZIndex = 52
	button.Parent = parent
	UITheme.corner(button, UITheme.CORNER.normal)
	UITheme.stroke(button, UITheme.STROKE.normal)

	local label = UITheme.label(button, text, UITheme.TEXT_SIZE.small)
	label.Position = UDim2.fromOffset(12, 0)
	label.Size = UDim2.new(1, -70, 1, 0)
	label.ZIndex = 53

	local pill = UITheme.label(button, "OFF", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	pill.AnchorPoint = Vector2.new(1, 0.5)
	pill.Position = UDim2.new(1, -12, 0.5, 0)
	pill.Size = UDim2.fromOffset(48, 22)
	pill.TextXAlignment = Enum.TextXAlignment.Right
	pill.ZIndex = 53

	button.Activated:Connect(onFlip)

	return function(on: boolean)
		pill.Text = on and "ON" or "OFF"
		pill.TextColor3 = on and UITheme.COLOR.green or UITheme.COLOR.textDim
		button.BackgroundColor3 = on and UITheme.COLOR.greenDeep or UITheme.COLOR.slate
	end
end

-- callbacks: { onChanged(settings) }
function SettingsPanel.new(parent: Instance, callbacks)
	local self = setmetatable({}, SettingsPanel)
	self.callbacks = callbacks
	self.values = Settings.normalise(nil)

	local root = Instance.new("Frame")
	root.Name = "Settings"
	root.AnchorPoint = Vector2.new(1, 0)
	root.BackgroundColor3 = UITheme.COLOR.panel
	root.BorderSizePixel = 0
	root.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.Visible = false
	root.ZIndex = 50
	root.Parent = parent
	UITheme.corner(root, UITheme.CORNER.large)
	UITheme.stroke(root, UITheme.STROKE.thick)
	UITheme.padding(root, UITheme.PAD.normal)

	-- A ceiling, so a taller settings list can never again grow its own close button off the
	-- bottom of the screen. Set from the live viewport by `position`.
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(PANEL_WIDTH, 10000)
	sizeLimit.Parent = root
	self.sizeLimit = sizeLimit

	self.root = root

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = root

	-- TITLE ROW, with a close that does not depend on reaching the bottom of the list.
	-- The CLOSE button at the end is kept as well -- it is the obvious target once you have
	-- read the panel -- but the X is the one that is always on screen.
	local titleRow = Instance.new("Frame")
	titleRow.Name = "TitleRow"
	titleRow.BackgroundTransparency = 1
	titleRow.LayoutOrder = 0
	titleRow.Size = UDim2.new(1, 0, 0, 30)
	titleRow.ZIndex = 52
	titleRow.Parent = root

	local title = UITheme.label(titleRow, "SETTINGS", UITheme.TEXT_SIZE.body, UITheme.COLOR.gold)
	title.Size = UDim2.new(1, -40, 1, 0)
	title.ZIndex = 52

	local closeX = Instance.new("TextButton")
	closeX.Name = "CloseX"
	closeX.AutoButtonColor = false
	closeX.AnchorPoint = Vector2.new(1, 0.5)
	closeX.BackgroundColor3 = UITheme.COLOR.red
	closeX.BorderSizePixel = 0
	closeX.Position = UDim2.new(1, 0, 0.5, 0)
	closeX.Size = UDim2.fromOffset(30, 26)
	closeX.Text = ""
	closeX.ZIndex = 53
	closeX.Parent = titleRow
	UITheme.corner(closeX, UITheme.CORNER.small)
	UITheme.stroke(closeX, UITheme.STROKE.normal)
	local closeXLabel = UITheme.label(closeX, "X", UITheme.TEXT_SIZE.small)
	closeXLabel.Size = UDim2.fromScale(1, 1)
	closeXLabel.TextXAlignment = Enum.TextXAlignment.Center
	closeXLabel.ZIndex = 54
	closeX.Activated:Connect(function()
		self:setOpen(false)
	end)

	local function apply()
		if self.callbacks.onChanged then
			self.callbacks.onChanged(self.values)
		end
		self:refresh()
	end

	heading(root, "HIT NUMBERS", 1)
	self.setHitNumbers = segmented(root, 2, Settings.HIT_NUMBERS_ORDER, function(option)
		self.values.hitNumbers = option
		apply()
	end)
	self.hitNote = UITheme.label(root, "", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	self.hitNote.LayoutOrder = 3
	self.hitNote.Size = UDim2.new(1, 0, 0, 30)
	self.hitNote.TextWrapped = true
	self.hitNote.ZIndex = 52

	heading(root, "EFFECTS", 4)
	self.setEffects = segmented(root, 5, Settings.EFFECTS_ORDER, function(option)
		self.values.effects = option
		apply()
	end)
	self.effectsNote = UITheme.label(root, "", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	self.effectsNote.LayoutOrder = 6
	self.effectsNote.Size = UDim2.new(1, 0, 0, 30)
	self.effectsNote.TextWrapped = true
	self.effectsNote.ZIndex = 52

	self.setReducedMotion = toggle(root, 7, "REDUCED MOTION", function()
		self.values.reducedMotion = not self.values.reducedMotion
		apply()
	end)
	self.setSound = toggle(root, 8, "SOUND", function()
		self.values.sound = not self.values.sound
		apply()
	end)

	-- The guarantee, stated where a player can read it.
	local promise = UITheme.label(root,
		"Presentation only. Never changes odds, rewards or how the machine plays.",
		UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	promise.LayoutOrder = 9
	promise.Size = UDim2.new(1, 0, 0, 30)
	promise.TextWrapped = true
	promise.ZIndex = 52

	local close = Instance.new("TextButton")
	close.AutoButtonColor = false
	close.BackgroundColor3 = UITheme.COLOR.red
	close.BorderSizePixel = 0
	close.LayoutOrder = 10
	close.Size = UDim2.new(1, 0, 0, UITheme.TOUCH_MIN)
	close.Text = ""
	close.ZIndex = 52
	close.Parent = root
	UITheme.corner(close, UITheme.CORNER.normal)
	UITheme.stroke(close, UITheme.STROKE.normal)
	local closeLabel = UITheme.label(close, "CLOSE", UITheme.TEXT_SIZE.small)
	closeLabel.Size = UDim2.fromScale(1, 1)
	closeLabel.TextXAlignment = Enum.TextXAlignment.Center
	closeLabel.ZIndex = 53
	close.Activated:Connect(function()
		self:setOpen(false)
	end)

	self:refresh()
	return self
end

local HIT_NOTES = {
	ALL = "Every scoring hit shows a number.",
	IMPORTANT = "Only drains, mutations and big hits. Repeated bumper trickle is hidden.",
	OFF = "No floating numbers are created at all.",
}

local EFFECTS_NOTES = {
	FULL = "All impact particles, trails, flashes and sparks.",
	REDUCED = "No impact particles or sparks. Trails and flashes stay.",
	MINIMAL = "Decoration off. Balls, identity, mutations and Tickets stay.",
}

function SettingsPanel:refresh()
	self.setHitNumbers(self.values.hitNumbers)
	self.setEffects(self.values.effects)
	self.setReducedMotion(self.values.reducedMotion)
	self.setSound(self.values.sound)
	self.hitNote.Text = HIT_NOTES[self.values.hitNumbers] or ""
	self.effectsNote.Text = EFFECTS_NOTES[self.values.effects] or ""
end

function SettingsPanel:setOpen(open: boolean)
	self.root.Visible = open
	if self.callbacks.onOpenChanged then
		self.callbacks.onOpenChanged(open)
	end
end

function SettingsPanel:isOpen(): boolean
	return self.root.Visible
end

-- `available` is the vertical room between the panel's top edge and the bottom of the
-- screen. The panel is AutomaticSize.Y, so without a ceiling it simply grows past the edge.
function SettingsPanel:position(anchorPosition: UDim2, compact: boolean, available: number?)
	local width = compact and 246 or PANEL_WIDTH
	self.root.Position = anchorPosition
	self.root.Size = UDim2.fromOffset(width, 0)
	self.sizeLimit.MaxSize = Vector2.new(width, math.max(200, available or 10000))
end

-- Test/DEV hook: apply a settings table as if the player had picked it.
function SettingsPanel:set(values)
	self.values = Settings.normalise(values)
	if self.callbacks.onChanged then
		self.callbacks.onChanged(self.values)
	end
	self:refresh()
end

return SettingsPanel
