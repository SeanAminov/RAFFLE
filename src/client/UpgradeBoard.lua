--!strict
-- The Core Upgrade Board: a dark navy board of hexagonal nodes on coloured branches.
--
-- Layout comes from UpgradeGraph, prices and prerequisites from UpgradeConfig, and the
-- player's ranks from the server snapshot. This file renders; it never decides whether a
-- purchase is legal. Pressing Buy sends an upgrade ID and waits -- the rank only changes
-- when the server says so.
--
-- The hexagons are built from THREE rotated rectangles rather than an image: the union of
-- three congruent rectangles at 0/60/120 degrees is a regular hexagon, so the shape needs
-- no asset and stays crisp at any zoom.
--
-- ---------------------------------------------------------------------------------------
-- DEPTH. Each node is four stacked hex layers -- drop shadow, dark outer rim, coloured
-- face, inset stud grid -- plus an icon medallion. All of it is primitives; nothing here
-- needs an uploaded image, so there is no asset to go missing and nothing to license.
--
-- MOTION. Every tween is tracked per node and CANCELLED before it is replaced, so a rapid
-- hover/press/purchase sequence cannot leave two tweens fighting over one property. The
-- affordability pulse is ONE shared Ticker callback for the whole board -- not a connection
-- or a looping tween per node -- and it is unregistered the moment nothing is affordable or
-- the board closes.
--
-- PURCHASING. The visible Buy button is always the primary path. On a mouse, a second
-- activation of the ALREADY SELECTED node inside the double-click window buys exactly one
-- rank. Touch never requires a double tap. A request in flight blocks another for that node,
-- and every request carries an idempotency token so a duplicated packet cannot double-spend.

local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local Economy = require(Shared:WaitForChild("Economy"))
local UpgradeConfig = require(Shared:WaitForChild("UpgradeConfig"))
local UpgradeGraph = require(Shared:WaitForChild("UpgradeGraph"))
local BallCatalog = require(Shared:WaitForChild("BallCatalog"))
local MutationCatalog = require(Shared:WaitForChild("MutationCatalog"))

local Ticker = require(script.Parent:WaitForChild("Ticker"))
local Presenter = require(script.Parent:WaitForChild("Presenter"))

local UpgradeBoard = {}
UpgradeBoard.__index = UpgradeBoard

-- The RATIO of these two is what decides how large a node looks once the board auto-fits:
-- node pixels = NODE * usableSize / (graphSpanInCells * CELL). Raising NODE and lowering CELL
-- together makes the hexagons bigger and the gaps tighter without moving a single node.
-- Nodes were reading as small and smushed, with their labels barely fitting, at 96/132.
local CELL = 124 -- pixels per graph unit at zoom 1
local NODE = 112 -- base node diameter in pixels

-- Second activation of an already-selected node inside this window buys one rank.
local DOUBLE_CLICK = 0.40
-- How long a node stays blocked after a request, if no snapshot arrives to clear it.
local PENDING_TIMEOUT = 1.2

local HOVER_SCALE = 1.03
local PRESS_SCALE = 0.96
-- Keeps the bottom action comfortably above Studio's lower chrome and gives the graph a
-- little more visual room beneath it. The full-screen root supplies the safe-area height;
-- this is an intentional composition lift, not another inset correction.
local BOARD_LIFT = 10

-- Icon medallions, drawn as text glyphs so the board needs no uploaded assets.
-- One glyph per branch, all verified to render with real text bounds in Studio rather than
-- as tofu boxes. Mutations previously reused Feed Speed's lightning bolt.
local ICONS = {
	machine = "🎰", clover = "🍀", auto = "⟳", speed = "⚡",
	coin = "🎟", mutation = "🧬", sorter = "⇅", multi = "✦", balls = "●",
}

-- Tier numerals. A family's tiers share a colour and an icon, so the numeral is what tells
-- Luck I from Luck II at a glance. Tier 1 is left unlabelled: numbering the only member of a
-- family before a second one exists is noise.
local NUMERALS = { "", "II", "III", "IV", "V" }

-- ---------------------------------------------------------------- primitives

-- Union of three rectangles at 0/60/120 degrees = a regular hexagon.
local function hexShape(parent: Instance, diameter: number, colour: Color3, zIndex: number)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(diameter, diameter)
	holder.ZIndex = zIndex
	holder.Parent = parent
	for _, angle in ipairs({ 0, 60, 120 }) do
		local slab = Instance.new("Frame")
		slab.AnchorPoint = Vector2.new(0.5, 0.5)
		slab.Position = UDim2.fromScale(0.5, 0.5)
		slab.Size = UDim2.fromOffset(diameter * 0.866, diameter * 0.5)
		slab.Rotation = angle
		slab.BackgroundColor3 = colour
		slab.BorderSizePixel = 0
		slab.ZIndex = zIndex
		slab.Parent = holder
		UITheme.corner(slab, 5)
	end
	return holder
end

local function tintSlabs(hex: Frame, colour: Color3)
	for _, slab in ipairs(hex:GetChildren()) do
		if slab:IsA("Frame") then
			slab.BackgroundColor3 = colour
		end
	end
end

local function resizeSlabs(hex: Frame, diameter: number)
	hex.Size = UDim2.fromOffset(diameter, diameter)
	for _, slab in ipairs(hex:GetChildren()) do
		if slab:IsA("Frame") then
			slab.Size = UDim2.fromOffset(diameter * 0.866, diameter * 0.5)
		end
	end
end

local function darken(colour: Color3, amount: number): Color3
	return Color3.new(colour.R * amount, colour.G * amount, colour.B * amount)
end

-- ---------------------------------------------------------------- construction

function UpgradeBoard.new(parent: Instance, callbacks)
	local self = setmetatable({}, UpgradeBoard)
	self.callbacks = callbacks
	self.nodes = {}
	self.selected = nil
	self.zoom = 1
	self.pan = Vector2.new(0, 0)
	self.tweens = {}
	self.pending = {}
	self.lastActivate = {}
	self.previousRanks = {}
	self.tokenCounter = 0
	self.pulseTime = 0
	self.pulsing = false
	-- Touch-only devices never require a double tap: select, then press Buy.
	self.touchOnly = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

	local scrim = Instance.new("Frame")
	scrim.Name = "UpgradeBoard"
	scrim.BackgroundColor3 = UITheme.COLOR.scrim
	scrim.BackgroundTransparency = 0.35
	scrim.BorderSizePixel = 0
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.Visible = false
	scrim.ZIndex = 20
	scrim.Parent = parent
	self.scrim = scrim

	local board = Instance.new("Frame")
	board.Name = "Board"
	board.AnchorPoint = Vector2.new(0.5, 0.5)
	board.Position = UDim2.new(0.5, 0, 0.5, -BOARD_LIFT)
	board.Size = UDim2.new(1, -80, 1, -80)
	board.BackgroundColor3 = UITheme.COLOR.board
	board.BorderSizePixel = 0
	board.ClipsDescendants = true
	board.ZIndex = 21
	board.Parent = scrim
	UITheme.corner(board, UITheme.CORNER.large)
	UITheme.stroke(board, UITheme.STROKE.thick)
	self.board = board

	local title = UITheme.label(board, "UPGRADES", UITheme.TEXT_SIZE.large, UITheme.COLOR.gold)
	title.Position = UDim2.fromOffset(18, 12)
	title.Size = UDim2.new(0, 300, 0, 32)
	title.ZIndex = 30

	-- The pannable canvas everything is drawn into.
	local canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.BackgroundTransparency = 1
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Dead centre. The offset that keeps the graph clear of the detail panel is computed in
	-- usableRect() and applied per node, so it can react to the board's real size.
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.ZIndex = 22
	canvas.Parent = board
	self.canvas = canvas

	self:buildEdges()
	self:buildNodes()
	self:buildDetail()

	-- ---- close ----------------------------------------------------------
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(0.5, 1)
	close.Position = UDim2.new(0.5, 0, 1, -14)
	close.Size = UDim2.fromOffset(200, UITheme.TOUCH_MIN + 4)
	close.BackgroundColor3 = UITheme.COLOR.red
	close.BorderSizePixel = 0
	close.AutoButtonColor = false
	close.Text = ""
	close.ZIndex = 40
	close.Selectable = true
	close.Parent = board
	UITheme.corner(close, UITheme.CORNER.large)
	UITheme.stroke(close, UITheme.STROKE.thick)
	local closeText = UITheme.label(close, "CLOSE", UITheme.TEXT_SIZE.body)
	closeText.Size = UDim2.fromScale(1, 1)
	closeText.TextXAlignment = Enum.TextXAlignment.Center
	closeText.ZIndex = 41
	close.Activated:Connect(function()
		self:setOpen(false)
	end)

	-- Luck is selected from the start rather than on first open: the detail panel should
	-- never be blank, and Luck is the upgrade worth reading first.
	self.selected = "LUCK"

	self:setupPanZoom()
	self:setupKeyboard()
	return self
end

function UpgradeBoard:buildEdges()
	self.edges = {}
	for _, edge in ipairs(UpgradeGraph.EDGES) do
		local from = UpgradeGraph.node(edge.from)
		local to = UpgradeGraph.node(edge.to)
		local colour = UpgradeGraph.edgeColour(edge)

		-- Two layers: a dark casing and the lit core inside it, so an unlit connector still
		-- reads as a real physical link rather than disappearing.
		local casing = Instance.new("Frame")
		casing.BackgroundColor3 = UITheme.COLOR.outline
		casing.BorderSizePixel = 0
		casing.AnchorPoint = Vector2.new(0.5, 0.5)
		casing.ZIndex = 22
		casing.Parent = self.canvas
		UITheme.corner(casing, 5)

		local core = Instance.new("Frame")
		core.BackgroundColor3 = colour
		core.BorderSizePixel = 0
		core.AnchorPoint = Vector2.new(0.5, 0.5)
		core.Position = UDim2.fromScale(0.5, 0.5)
		-- PROPORTIONAL inset, not a fixed 6px one. The casing is ~13px at zoom 1 but only ~6px
		-- when the board auto-fits a small window, and a fixed inset made the coloured core
		-- zero-width there -- every branch colour silently collapsed to the dark casing.
		core.Size = UDim2.new(1, -3, 0.58, 0)
		core.ZIndex = 23
		core.Parent = casing
		UITheme.corner(core, 4)

		table.insert(self.edges, {
			edge = edge, casing = casing, core = core,
			from = from, to = to, colour = colour, lit = false,
		})
	end
end

function UpgradeBoard:buildNodes()
	for _, node in ipairs(UpgradeGraph.NODES) do
		local upgrade = UpgradeConfig.get(node.id)
		local diameter = NODE * (node.size or 1)
		local branchColour = UpgradeGraph.colourOf(node.id)

		local holder = Instance.new("TextButton")
		holder.Name = node.id
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Size = UDim2.fromOffset(diameter, diameter)
		holder.Text = ""
		holder.AutoButtonColor = false
		holder.ZIndex = 24
		holder.Selectable = true
		holder.Parent = self.canvas

		-- LAYERS, back to front: shadow, rim, face, studs.
		local shadow = hexShape(holder, diameter, Color3.fromRGB(0, 0, 0), 23)
		for _, slab in ipairs(shadow:GetChildren()) do
			if slab:IsA("Frame") then
				slab.BackgroundTransparency = 0.62
			end
		end
		shadow.Position = UDim2.new(0.5, 0, 0.5, 6)

		local rim = hexShape(holder, diameter, UITheme.COLOR.outline, 24)
		local border = hexShape(holder, diameter - 7, UpgradeGraph.rimFor(branchColour), 25)
		local fill = hexShape(holder, diameter - 16, branchColour, 26)

		local studs = UITheme.studPattern(holder, 4, 3, 0.93)
		studs.ZIndex = 27
		studs.Size = UDim2.fromScale(0.56, 0.46)
		studs.AnchorPoint = Vector2.new(0.5, 0.5)
		studs.Position = UDim2.fromScale(0.5, 0.62)
		for _, stud in ipairs(studs:GetChildren()) do
			if stud:IsA("Frame") then
				stud.ZIndex = 27
			end
		end

		-- Icon medallion: a small dark disc with the branch glyph on it.
		local medallion = Instance.new("Frame")
		medallion.AnchorPoint = Vector2.new(0.5, 0.5)
		medallion.Position = UDim2.fromScale(0.5, 0.30)
		medallion.Size = UDim2.fromOffset(diameter * 0.30, diameter * 0.30)
		medallion.BackgroundColor3 = darken(branchColour, 0.30)
		medallion.BorderSizePixel = 0
		medallion.ZIndex = 28
		medallion.Parent = holder
		UITheme.corner(medallion, UITheme.CORNER.pill)
		UITheme.stroke(medallion, UITheme.STROKE.thin)

		local icon = UITheme.label(medallion, ICONS[upgrade.icon] or "◆", UITheme.TEXT_SIZE.small)
		icon.Size = UDim2.fromScale(1, 1)
		icon.TextXAlignment = Enum.TextXAlignment.Center
		icon.ZIndex = 29

		-- Roman numeral for tier 2 and above, in the family's own colour.
		local numeral = NUMERALS[math.clamp(upgrade.tier or 1, 1, #NUMERALS)]
		if numeral ~= "" then
			local badge = Instance.new("Frame")
			badge.AnchorPoint = Vector2.new(0.5, 0.5)
			badge.Position = UDim2.fromScale(0.78, 0.30)
			badge.Size = UDim2.fromOffset(diameter * 0.26, diameter * 0.20)
			badge.BackgroundColor3 = darken(branchColour, 0.22)
			badge.BorderSizePixel = 0
			badge.ZIndex = 28
			badge.Parent = holder
			UITheme.corner(badge, UITheme.CORNER.small)
			UITheme.stroke(badge, UITheme.STROKE.thin)
			local numeralLabel = UITheme.label(badge, numeral, UITheme.TEXT_SIZE.tiny, branchColour)
			numeralLabel.Size = UDim2.fromScale(1, 1)
			numeralLabel.TextXAlignment = Enum.TextXAlignment.Center
			numeralLabel.TextScaled = true
			numeralLabel.ZIndex = 29
			local fit = Instance.new("UITextSizeConstraint")
			fit.MaxTextSize = UITheme.TEXT_SIZE.tiny
			fit.MinTextSize = 6
			fit.Parent = numeralLabel
		end

		-- The SHORT label, on one line, scaled to the hexagon's narrow waist. Wrapping is off
		-- on purpose: with it on, a long word broke mid-word ("MUTA TION") instead of shrinking.
		local titleLabel = UITheme.label(holder, (upgrade.short or upgrade.displayName):upper(),
			UITheme.TEXT_SIZE.small)
		titleLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		titleLabel.Position = UDim2.fromScale(0.5, 0.63)
		titleLabel.Size = UDim2.new(0.78, 0, 0, 22)
		titleLabel.TextXAlignment = Enum.TextXAlignment.Center
		titleLabel.TextWrapped = false
		titleLabel.TextScaled = true
		titleLabel.ZIndex = 30
		local titleFit = Instance.new("UITextSizeConstraint")
		titleFit.MaxTextSize = UITheme.TEXT_SIZE.small
		titleFit.MinTextSize = 7
		titleFit.Parent = titleLabel

		-- Lv N/MAX sits above the node, cost below: the reference's hierarchy.
		local rankLabel = UITheme.label(holder, "", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.text)
		rankLabel.AnchorPoint = Vector2.new(0.5, 1)
		-- Clear of the hexagon's pointed top. The bigger nodes brought "MAX" onto the rim.
		rankLabel.Position = UDim2.new(0.5, 0, 0, -1)
		rankLabel.Size = UDim2.new(1, 26, 0, 18)
		rankLabel.TextXAlignment = Enum.TextXAlignment.Center
		rankLabel.ZIndex = 30

		local costLabel = UITheme.label(holder, "", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.gold)
		costLabel.AnchorPoint = Vector2.new(0.5, 0)
		costLabel.Position = UDim2.new(0.5, 0, 1, 3)
		costLabel.Size = UDim2.new(1, 30, 0, 18)
		costLabel.TextXAlignment = Enum.TextXAlignment.Center
		costLabel.ZIndex = 30

		local entry = {
			node = node,
			holder = holder,
			shadow = shadow,
			rim = rim,
			border = border,
			fill = fill,
			studs = studs,
			medallion = medallion,
			icon = icon,
			title = titleLabel,
			rank = rankLabel,
			cost = costLabel,
			diameter = diameter,
			branchColour = branchColour,
			scale = 1,
			hovering = false,
			affordable = false,
		}
		self.nodes[node.id] = entry

		holder.MouseEnter:Connect(function()
			entry.hovering = true
			self:scaleNode(node.id, HOVER_SCALE)
		end)
		holder.MouseLeave:Connect(function()
			entry.hovering = false
			self:scaleNode(node.id, 1)
		end)
		holder.MouseButton1Down:Connect(function()
			self:scaleNode(node.id, PRESS_SCALE)
		end)
		holder.MouseButton1Up:Connect(function()
			self:scaleNode(node.id, entry.hovering and HOVER_SCALE or 1)
		end)
		holder.Activated:Connect(function()
			self:activate(node.id)
		end)
	end
end

-- ---------------------------------------------------------------- motion

-- Cancels whatever was animating this property on this node before starting the next tween,
-- so a superseded animation can never keep writing after a newer one starts.
function UpgradeBoard:tween(key: string, instance: Instance, info: TweenInfo, goal)
	local existing = self.tweens[key]
	if existing then
		existing:Cancel()
	end
	local tween = TweenService:Create(instance, info, goal)
	self.tweens[key] = tween
	tween.Completed:Connect(function()
		if self.tweens[key] == tween then
			self.tweens[key] = nil
		end
	end)
	tween:Play()
	return tween
end

function UpgradeBoard:applyScale(id: string)
	local entry = self.nodes[id]
	if not entry then
		return
	end
	local diameter = entry.diameter * self.zoom * entry.scale
	entry.holder.Size = UDim2.fromOffset(diameter, diameter)
	resizeSlabs(entry.shadow, diameter)
	resizeSlabs(entry.rim, diameter)
	resizeSlabs(entry.border, diameter - 7 * self.zoom)
	resizeSlabs(entry.fill, diameter - 16 * self.zoom)
	entry.medallion.Size = UDim2.fromOffset(diameter * 0.30, diameter * 0.30)
end

function UpgradeBoard:scaleNode(id: string, target: number)
	local entry = self.nodes[id]
	if not entry then
		return
	end
	-- Reduced Motion / Minimal effects flatten this to an instant state change rather than
	-- an animation, via the Presenter's one motion scaler.
	if Presenter.motion(1) <= 0 then
		entry.scale = target
		self:applyScale(id)
		return
	end

	local from = entry.scale
	local key = "scale:" .. id
	local existing = self.tweens[key]
	if existing then
		existing:Cancel()
		self.tweens[key] = nil
	end

	-- Scale is not a tweenable property of the hex stack (it is four separate frames), so it
	-- is driven from a single numeric value object -- one instance per node, tweened, read in
	-- its Changed handler. No Heartbeat connection, and it stops itself when the tween ends.
	local driver = entry.scaleDriver
	if not driver then
		driver = Instance.new("NumberValue")
		driver.Name = "ScaleDriver"
		driver.Parent = entry.holder
		driver.Changed:Connect(function(value)
			entry.scale = value
			self:applyScale(id)
		end)
		entry.scaleDriver = driver
	end
	driver.Value = from
	self:tween(key, driver, UITheme.EASE_PRESS, { Value = target })
end

-- 0.92 -> 1.10 -> 1.00, then a rim flash. One-shot; nothing is left animating.
function UpgradeBoard:purchaseBounce(id: string)
	local entry = self.nodes[id]
	if not entry then
		return
	end
	if Presenter.motion(1) <= 0 then
		entry.scale = 1
		self:applyScale(id)
		return
	end

	local driver = entry.scaleDriver
	if not driver then
		self:scaleNode(id, 1)
		driver = entry.scaleDriver
	end
	if not driver then
		return
	end

	local key = "scale:" .. id
	local existing = self.tweens[key]
	if existing then
		existing:Cancel()
	end
	driver.Value = 0.92
	local up = TweenService:Create(driver,
		TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = 1.10 })
	self.tweens[key] = up
	up.Completed:Connect(function()
		if self.tweens[key] ~= up then
			return
		end
		local down = TweenService:Create(driver,
			TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 1.00 })
		self.tweens[key] = down
		down.Completed:Connect(function()
			if self.tweens[key] == down then
				self.tweens[key] = nil
			end
		end)
		down:Play()
	end)
	up:Play()

	-- Rim flash: the outer rim goes bright for a beat and settles back.
	tintSlabs(entry.rim, UITheme.COLOR.text)
	task.delay(0.16, function()
		if entry.rim.Parent then
			tintSlabs(entry.rim, (self.selected == id) and UITheme.COLOR.gold or UITheme.COLOR.outline)
		end
	end)
end

-- A short horizontal shake plus a red rim: the failure response.
function UpgradeBoard:rejectShake(id: string)
	local entry = self.nodes[id]
	if not entry then
		return
	end
	tintSlabs(entry.rim, UITheme.COLOR.red)
	task.delay(0.28, function()
		if entry.rim.Parent then
			tintSlabs(entry.rim, (self.selected == id) and UITheme.COLOR.gold or UITheme.COLOR.outline)
		end
	end)

	if Presenter.motion(1) <= 0 then
		return
	end
	local holder = entry.holder
	local base = holder.Position
	local offsets = { 7, -6, 4, -2, 0 }
	task.spawn(function()
		for _, dx in ipairs(offsets) do
			if not holder.Parent then
				return
			end
			holder.Position = base + UDim2.fromOffset(dx, 0)
			task.wait(0.035)
		end
		if holder.Parent then
			holder.Position = base
		end
	end)
end

-- One-shot connector pulse when an edge first becomes satisfied.
function UpgradeBoard:pulseEdge(record)
	if Presenter.motion(1) <= 0 then
		return
	end
	local core = record.core
	local key = "edge:" .. record.edge.from .. ">" .. record.edge.to
	core.BackgroundColor3 = UITheme.COLOR.text
	self:tween(key, core, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundColor3 = record.colour })
end

-- ---------------------------------------------------------------- interaction

function UpgradeBoard:nextToken(id: string): string
	self.tokenCounter += 1
	return ("%s:%d"):format(id, self.tokenCounter)
end

-- FIRST activation selects. A SECOND activation of the already-selected node inside the
-- window buys exactly one rank -- and then resets the timer, so a third click starts over
-- and a triple-click can never buy twice.
function UpgradeBoard:activate(id: string)
	local now = os.clock()
	local previous = self.lastActivate[id] or 0

	if self.selected == id and not self.touchOnly and (now - previous) < DOUBLE_CLICK then
		self.lastActivate[id] = 0
		self:requestPurchase(id)
		return
	end

	self.lastActivate[id] = now
	self:select(id)
end

function UpgradeBoard:requestPurchase(id: string)
	local upgrade = UpgradeConfig.get(id)
	local state = self.state
	if not upgrade or not state then
		return
	end

	-- A request already in flight for this node blocks another. Cleared by the next state
	-- snapshot, or by a timeout if the server said nothing at all.
	local pending = self.pending[id]
	if pending and (os.clock() - pending) < PENDING_TIMEOUT then
		return
	end

	-- Local feedback only. The server re-validates all of this and is the only authority;
	-- these branches exist so a refusal is explained immediately rather than silently.
	local rank = state.ranks[id] or 0
	local met, why = UpgradeConfig.requirementsMet(id, state.ranks)
	local cost = UpgradeConfig.costOfNext(id, rank)

	if upgrade.preview then
		self:rejectShake(id)
		self:flashBuy("COMING LATER")
		return
	end
	if not met then
		self:rejectShake(id)
		self:flashBuy((why or "LOCKED"):upper())
		return
	end
	if not cost then
		self:rejectShake(id)
		self:flashBuy(upgrade.maxRank == 0 and "OWNED" or "MAXED")
		return
	end
	if state.tickets < cost then
		self:rejectShake(id)
		self:flashBuy(("NEED %s"):format(Economy.formatTickets(cost)))
		return
	end

	self.pending[id] = os.clock()
	self:refreshDetail()
	if self.callbacks.onPurchase then
		self.callbacks.onPurchase(id, self:nextToken(id))
	end
end

function UpgradeBoard:flashBuy(text: string)
	self.buyLabel.Text = text
	self.buyButton.BackgroundColor3 = UITheme.COLOR.red
	task.delay(0.6, function()
		if self.buyButton.Parent then
			self:refreshDetail()
		end
	end)
end

function UpgradeBoard:setupKeyboard()
	-- Keyboard and controller: the selected node's Buy is reachable with Enter / ButtonA
	-- without needing a pointer, and Escape closes the board.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self:isOpen() then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			self:setOpen(false)
		elseif input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
			if self.selected then
				self:requestPurchase(self.selected)
			end
		end
	end)
end

function UpgradeBoard:setupPanZoom()
	local dragging, dragStart, panStart = false, Vector2.new(), Vector2.new()
	self.board.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			panStart = self.pan
		end
	end)
	self.board.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
			self.pan = panStart + delta
			self:layout()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	self.board.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			-- clamped so the board can never be zoomed into uselessness
			self.zoom = math.clamp(self.zoom + input.Position.Z * 0.1, 0.55, 1.6)
			self:layout()
		end
	end)
end

-- ---------------------------------------------------------------- layout

-- The rectangle the graph may actually occupy, expressed as an offset from the board's
-- centre plus a size. The detail panel owns the right-hand column, the title bar the top and
-- the CLOSE button the bottom, so the usable area is neither the board nor centred on it.
--
-- Deriving this instead of applying a fixed -130 nudge is what stopped MORE BALLS being
-- clipped off the bottom-right corner.
function UpgradeBoard:usableRect(): (number, number, number, number)
	local absolute = self.board.AbsoluteSize
	local MARGIN = 16
	-- The detail panel is top-RIGHT in both layouts; only its width changes. Reserving the
	-- bottom for it in compact was wrong and squeezed the graph into a 200px strip, which is
	-- what pushed Multi-Roll off the top edge.
	local detailWidth = self.compact and 230 or 292
	local reserveRight = detailWidth + 14 + MARGIN
	local reserveTop = 52
	local reserveBottom = UITheme.TOUCH_MIN + 4 + 28

	local width = math.max(220, absolute.X - reserveRight - MARGIN * 2)
	local height = math.max(200, absolute.Y - reserveTop - reserveBottom)
	-- Offset of the usable rectangle's centre from the board's centre.
	local offsetX = -reserveRight / 2
	local offsetY = (reserveTop - reserveBottom) / 2
	return offsetX, offsetY, width, height
end

-- Fits the whole graph inside that rectangle. Called on open and on resize, so adding a node
-- can never push the tree off-screen.
function UpgradeBoard:fit()
	local minX, maxX, minY, maxY = UpgradeGraph.bounds()
	local graphW = math.max((maxX - minX) * CELL, 1)
	local graphH = math.max((maxY - minY) * CELL, 1)
	local _, _, width, height = self:usableRect()
	self.zoom = math.clamp(math.min(width / graphW, height / graphH), 0.45, 1.15)
	self.pan = Vector2.new(0, 0)
	self:layout()
end

function UpgradeBoard:layout()
	local scale = self.zoom
	local cx, cy = UpgradeGraph.centre()
	local offsetX, offsetY = self:usableRect()

	local function place(x: number, y: number): (number, number)
		return (x - cx) * CELL * scale + self.pan.X + offsetX,
			(y - cy) * CELL * scale + self.pan.Y + offsetY
	end

	for id, entry in pairs(self.nodes) do
		local px, py = place(entry.node.x, entry.node.y)
		entry.holder.Position = UDim2.new(0.5, px, 0.5, py)
		self:applyScale(id)
	end

	for _, record in ipairs(self.edges) do
		local ax, ay = place(record.from.x, record.from.y)
		local bx, by = place(record.to.x, record.to.y)
		local dx, dy = bx - ax, by - ay
		local length = math.sqrt(dx * dx + dy * dy)
		record.casing.Position = UDim2.new(0.5, (ax + bx) / 2, 0.5, (ay + by) / 2)
		record.casing.Size = UDim2.fromOffset(length, 19 * scale)
		record.casing.Rotation = math.deg(math.atan2(dy, dx))
	end
end

-- ---------------------------------------------------------------- state

function UpgradeBoard:setState(state)
	local previous = self.previousRanks
	self.state = state

	-- Anything whose rank moved has been answered by the server: clear its pending block and
	-- play the purchase response.
	for id, rank in pairs(state.ranks) do
		if previous[id] ~= nil and rank > previous[id] then
			self.pending[id] = nil
			self:purchaseBounce(id)
		end
	end
	-- A pending request that timed out without a rank change is released too, so a dropped
	-- packet cannot lock a node forever.
	for id, at in pairs(self.pending) do
		if os.clock() - at > PENDING_TIMEOUT then
			self.pending[id] = nil
		end
	end

	local anyAffordable = false

	for id, entry in pairs(self.nodes) do
		local upgrade = UpgradeConfig.get(id)
		local rank = state.ranks[id] or 0
		local met = UpgradeConfig.requirementsMet(id, state.ranks)
		local cost = UpgradeConfig.costOfNext(id, rank)
		local affordable = cost ~= nil and state.tickets >= cost and met
		local maxed = upgrade.maxRank > 0 and rank >= upgrade.maxRank

		local branchColour = entry.branchColour
		local fillColour = branchColour
		local borderColour = UpgradeGraph.rimFor(branchColour)
		-- The SHORT board label, not the full title -- this line used to overwrite the short
		-- label chosen at construction on every single state snapshot.
		local titleText = (upgrade.short or upgrade.displayName):upper()
		local locked = upgrade.preview or not met

		entry.icon.TextTransparency = locked and 0.45 or 0
		entry.studs.Visible = not locked

		if locked then
			-- Locked nodes are silhouettes with a "?" rather than a readable title.
			fillColour = UITheme.COLOR.locked
			borderColour = darken(UITheme.COLOR.locked, 0.55)
			titleText = "?"
			entry.rank.Text = upgrade.preview and "LATER" or "LOCKED"
			entry.rank.TextColor3 = UITheme.COLOR.textDim
			entry.cost.Text = ""
		elseif upgrade.maxRank == 0 then
			entry.rank.Text = "OWNED"
			entry.rank.TextColor3 = UITheme.COLOR.text
			entry.cost.Text = ""
		elseif maxed then
			-- MAX is a distinct, brighter state: gold text and a gold rim, not just no cost.
			entry.rank.Text = "MAX"
			entry.rank.TextColor3 = UITheme.COLOR.gold
			entry.cost.Text = ""
			borderColour = UITheme.COLOR.gold
		else
			entry.rank.Text = ("Lv %d/%d"):format(rank, upgrade.maxRank)
			entry.rank.TextColor3 = rank > 0 and UITheme.COLOR.green or UITheme.COLOR.text
			entry.cost.Text = Economy.formatTickets(cost)
			entry.cost.TextColor3 = affordable and UITheme.COLOR.gold or UITheme.COLOR.unaffordable
			if not affordable then
				fillColour = darken(branchColour, 0.52)
			end
		end

		if affordable then
			anyAffordable = true
		end
		entry.affordable = affordable
		entry.title.Text = titleText
		entry.medallion.BackgroundColor3 = darken(fillColour, 0.30)
		tintSlabs(entry.fill, fillColour)
		tintSlabs(entry.border, borderColour)
		tintSlabs(entry.rim, (self.selected == id) and UITheme.COLOR.gold or UITheme.COLOR.outline)
	end

	-- Connector states, and a one-shot pulse the first time one lights up.
	for _, record in ipairs(self.edges) do
		local satisfied = UpgradeGraph.edgeSatisfied(record.edge, state.ranks)
		if satisfied ~= record.lit then
			record.lit = satisfied
			if satisfied and next(previous) ~= nil then
				self:pulseEdge(record)
			end
		end
		record.core.BackgroundColor3 = satisfied and record.colour or darken(record.colour, 0.30)
		record.core.BackgroundTransparency = satisfied and 0 or 0.35
	end

	self.previousRanks = {}
	for id, rank in pairs(state.ranks) do
		self.previousRanks[id] = rank
	end

	self:setPulsing(anyAffordable and self:isOpen())

	if self.selected then
		self:refreshDetail()
	end
	self:layout()
end

-- ONE shared pulse for the whole board. Registered only while something is affordable AND
-- the board is open; unregistered the moment either stops being true.
function UpgradeBoard:setPulsing(on: boolean)
	if on == self.pulsing then
		return
	end
	self.pulsing = on
	if not on then
		Ticker.unregister("UpgradeBoardPulse")
		for _, entry in ipairs(UpgradeGraph.NODES) do
			local node = self.nodes[entry.id]
			if node then
				node.medallion.BackgroundTransparency = 0
			end
		end
		return
	end
	Ticker.register("UpgradeBoardPulse", function(dt)
		self.pulseTime += dt
		-- Restrained on purpose: a shallow breathe on the medallion of affordable nodes, not
		-- a glow, a scale bounce or a colour cycle.
		local a = 0.18 + 0.18 * (0.5 + 0.5 * math.sin(self.pulseTime * 3.4))
		for id, node in pairs(self.nodes) do
			node.medallion.BackgroundTransparency = node.affordable and a or 0
		end
	end)
end

function UpgradeBoard:select(id: string)
	self.selected = id
	if self.state then
		self:setState(self.state)
	end
end

function UpgradeBoard:refreshDetail()
	local id = self.selected
	local upgrade = UpgradeConfig.get(id)
	local state = self.state
	if not upgrade or not state then
		return
	end
	local rank = state.ranks[id] or 0
	local met, why = UpgradeConfig.requirementsMet(id, state.ranks)
	local cost = UpgradeConfig.costOfNext(id, rank)

	self.detailTitle.Text = upgrade.displayName:upper()
	self.detailBlurb.Text = upgrade.blurb
	self.detailRank.Text = upgrade.maxRank > 0
		and ("RANK %d / %d"):format(rank, upgrade.maxRank)
		or "OWNED"

	-- EFFECT LINE: this node's own contribution AND the family total it produces.
	--
	-- Both numbers matter and neither is sufficient alone. "+0.35 Luck" says what this
	-- purchase is worth; "Total Luck becomes x1.35" says what the machine will actually run
	-- at. With several tiers feeding one stat, showing only the node's number would leave the
	-- player unable to tell what they are buying into.
	local family = upgrade.family
	local spec = UpgradeConfig.FAMILIES[family]
	local delta = UpgradeConfig.nextContribution(id, rank)
	local totalNow, totalNext
	if spec and spec.combine ~= "CAPABILITY" and cost then
		local after = {}
		for key, value in pairs(state.ranks) do
			after[key] = value
		end
		after[id] = rank + 1
		totalNow = UpgradeConfig.aggregate(family, state.ranks)
		totalNext = UpgradeConfig.aggregate(family, after)
	end

	if not cost then
		self.detailEffect.Text = upgrade.availability == UpgradeConfig.PREVIEW and "COMING LATER"
			or (upgrade.maxRank == 0 and "OWNED" or "MAXED")
	elseif spec and spec.combine == "CAPABILITY" then
		self.detailEffect.Text = rank > 0 and "OWNED" or "NOT OWNED  ->  OWNED"
	elseif family == "FEED" then
		-- Shown as a rate, because "1.20 -> 1.02" reads like a nerf when it is a buff.
		self.detailEffect.Text = ("%.2f -> %.2f balls/sec from the hopper")
			:format(1 / totalNow, 1 / totalNext)
	elseif family == "MUTATION" then
		local base = MutationCatalog.baseChance("CHARGED", totalNext)
		self.detailEffect.Text = ("+%d rank  ·  Mutations total %d -> %d  (1 in %d base)")
			:format(delta or 1, totalNow, totalNext, base > 0 and (1 / base) or 0)
	elseif family == "LUCK" then
		self.detailEffect.Text = ("+%.2f Luck  ·  Total Luck becomes x%.2f"):format(delta or 0, totalNext)
	elseif family == "VALUE" then
		self.detailEffect.Text = ("+%.2f Ball Value  ·  Total becomes x%.2f"):format(delta or 0, totalNext)
	else
		self.detailEffect.Text = ("%.2f  ->  %.2f"):format(totalNow or 0, totalNext or 0)
	end

	-- Contextual preview, using the same math the server rolls against.
	if family == "LUCK" and cost and totalNow and totalNext then
		-- Representative effective odds, computed from the FAMILY TOTAL rather than from this
		-- node alone, so a Luck II preview would show the combined effect honestly.
		local before = BallCatalog.chanceOfThisOrBetter("RUBY", totalNow)
		local after = BallCatalog.chanceOfThisOrBetter("RUBY", totalNext)
		self.detailPreview.Text = ("Rare or better: ~1 in %s  ->  ~1 in %s"):format(
			Economy.formatOneIn(1 / before), Economy.formatOneIn(1 / after))
	elseif id == "MUTATIONS" then
		local shown = math.max(rank, 1)
		local effective = MutationCatalog.effectiveChance("CHARGED", shown, state.luck)
		self.detailPreview.Text = effective > 0
			and ("At x%.2f Luck, Lv %d is ~1 in %s. Charged pays 3x on drain.")
				:format(state.luck, shown, Economy.formatOneIn(1 / effective))
			or "Charged balls pay 3x when they drain."
	elseif not met then
		local parts = {}
		for _, need in ipairs(UpgradeConfig.unmetRequirements(id, state.ranks)) do
			table.insert(parts, ("%s Lv %d"):format(need.title, need.level))
		end
		self.detailPreview.Text = "Requires " .. table.concat(parts, " and ")
	else
		self.detailPreview.Text = ""
	end

	-- Buy button state mirrors exactly why the server would refuse.
	if self.pending[id] then
		self.buyLabel.Text = "..."
		self.buyButton.BackgroundColor3 = UITheme.COLOR.slate
	elseif upgrade.preview then
		self.buyLabel.Text = "COMING LATER"
		self.buyButton.BackgroundColor3 = UITheme.COLOR.locked
	elseif not met then
		self.buyLabel.Text = (why or "LOCKED"):upper()
		self.buyButton.BackgroundColor3 = UITheme.COLOR.locked
	elseif not cost then
		self.buyLabel.Text = upgrade.maxRank == 0 and "OWNED" or "MAXED"
		self.buyButton.BackgroundColor3 = UITheme.COLOR.slate
	elseif state.tickets < cost then
		self.buyLabel.Text = ("NEED %s"):format(Economy.formatTickets(cost))
		self.buyButton.BackgroundColor3 = UITheme.COLOR.unaffordable
	else
		self.buyLabel.Text = ("BUY  %s"):format(Economy.formatTickets(cost))
		self.buyButton.BackgroundColor3 = UITheme.COLOR.green
	end
end

function UpgradeBoard:buildDetail()
	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.AnchorPoint = Vector2.new(1, 0)
	detail.Position = UDim2.new(1, -14, 0, 14)
	detail.Size = UDim2.fromOffset(292, 268)
	detail.BackgroundColor3 = UITheme.COLOR.panelDeep
	detail.BorderSizePixel = 0
	detail.ZIndex = 35
	detail.Parent = self.board
	UITheme.corner(detail, UITheme.CORNER.large)
	UITheme.stroke(detail, UITheme.STROKE.thick)
	UITheme.padding(detail, UITheme.PAD.normal)
	self.detail = detail

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = detail

	local function line(order: number, size: number, colour: Color3?, height: number)
		local label = UITheme.label(detail, "", size, colour)
		label.LayoutOrder = order
		label.Size = UDim2.new(1, 0, 0, height)
		label.TextWrapped = true
		label.ZIndex = 36
		return label
	end

	self.detailTitle = line(1, UITheme.TEXT_SIZE.body, UITheme.COLOR.text, 26)
	self.detailRank = line(2, UITheme.TEXT_SIZE.small, UITheme.COLOR.textDim, 20)
	self.detailBlurb = line(3, UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim, 46)
	self.detailEffect = line(4, UITheme.TEXT_SIZE.small, UITheme.COLOR.green, 22)
	self.detailPreview = line(5, UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim, 44)

	local buy = Instance.new("TextButton")
	buy.Name = "Buy"
	buy.LayoutOrder = 6
	buy.Size = UDim2.new(1, 0, 0, UITheme.TOUCH_MIN)
	buy.BackgroundColor3 = UITheme.COLOR.green
	buy.BorderSizePixel = 0
	buy.AutoButtonColor = false
	buy.Text = ""
	buy.ZIndex = 36
	buy.Selectable = true
	buy.Parent = detail
	UITheme.corner(buy, UITheme.CORNER.normal)
	UITheme.stroke(buy, UITheme.STROKE.normal)
	self.buyButton = buy

	self.buyLabel = UITheme.label(buy, "BUY", UITheme.TEXT_SIZE.body)
	self.buyLabel.Size = UDim2.fromScale(1, 1)
	self.buyLabel.TextXAlignment = Enum.TextXAlignment.Center
	self.buyLabel.ZIndex = 37

	local hint = UITheme.label(detail, "Double-click a node to buy", UITheme.TEXT_SIZE.tiny,
		UITheme.COLOR.textDim)
	hint.LayoutOrder = 7
	hint.Size = UDim2.new(1, 0, 0, 16)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.ZIndex = 36
	hint.Visible = not (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)

	buy.MouseButton1Down:Connect(function()
		Presenter.tween(buy, UITheme.EASE_PRESS, { Size = UDim2.new(1, -6, 0, 40) })
	end)
	local function release()
		Presenter.tween(buy, UITheme.EASE_PRESS, { Size = UDim2.new(1, 0, 0, UITheme.TOUCH_MIN) })
	end
	buy.MouseButton1Up:Connect(release)
	buy.MouseLeave:Connect(release)
	buy.Activated:Connect(function()
		if self.selected then
			self:requestPurchase(self.selected)
		end
	end)
end

function UpgradeBoard:setOpen(open: boolean)
	self.scrim.Visible = open
	if open then
		self:fit()
		if self.state then
			self:refreshDetail()
		end
		-- GAMEPAD ONLY. Claiming GuiService.SelectedObject unconditionally did two unwanted
		-- things on a mouse: it logged "Setting GuiService.SelectedObject to invalid
		-- GuiObject" on every open, and it drew a controller focus ring around Buy that a
		-- mouse user has no use for. Controller users still get a selected control to start
		-- from; everyone else is left alone.
		if UserInputService.GamepadEnabled then
			task.defer(function()
				if self:isOpen() and self.buyButton.Parent then
					GuiService.SelectedObject = self.buyButton
				end
			end)
		end
	else
		self:setPulsing(false)
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(self.scrim) then
			GuiService.SelectedObject = nil
		end
	end
	if self.callbacks.onOpenChanged then
		self.callbacks.onOpenChanged(open)
	end
end

function UpgradeBoard:isOpen(): boolean
	return self.scrim.Visible
end

function UpgradeBoard:setCompact(compact: boolean)
	self.compact = compact
	self.board.Size = compact and UDim2.new(1, -16, 1, -16) or UDim2.new(1, -80, 1, -80)
	self.detail.Size = compact and UDim2.fromOffset(230, 244) or UDim2.fromOffset(292, 268)
	if self:isOpen() then
		self:fit()
	end
end

return UpgradeBoard
