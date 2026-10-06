--!strict
-- The left roll panel: the player's whole loop in one column.
--
-- Order, top to bottom, matching the reference's ball-roll panel:
--   Tickets balance / ball preview / name / canonical 1 IN X / category chip / Luck /
--   live effective odds / queue preview / ROLL FREE / Auto Roll row / counts
--
-- Everything shown here comes from the server: the reveal payload and the state snapshot.
-- Nothing is computed locally that could disagree with what was actually rolled.
--
-- The centre of the screen is deliberately left alone -- the machine is the spectacle.

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local Economy = require(Shared:WaitForChild("Economy"))
local vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local BallIcon = require(Client:WaitForChild("BallIcon"))

local source = vide.source

local RollPanel = {}
RollPanel.__index = RollPanel

local function panel(parent: Instance, order: number, height: number): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = UITheme.COLOR.panelDeep
	frame.BorderSizePixel = 0
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, 0, 0, height)
	frame.Parent = parent
	UITheme.corner(frame, UITheme.CORNER.normal)
	UITheme.stroke(frame, UITheme.STROKE.normal)
	return frame
end

function RollPanel.new(parent: Instance, callbacks)
	local self = setmetatable({}, RollPanel)
	self.callbacks = callbacks
	self.compact = false

	local root = Instance.new("Frame")
	root.Name = "RollPanel"
	root.BackgroundColor3 = UITheme.COLOR.panel
	root.BorderSizePixel = 0
	root.Parent = parent
	UITheme.corner(root, UITheme.CORNER.large)
	UITheme.stroke(root, UITheme.STROKE.thick)
	UITheme.padding(root, UITheme.PAD.normal)
	self.root = root

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = root

	-- ---- tickets -------------------------------------------------------
	local ticketRow = panel(root, 1, 44)
	local ticketIcon = UITheme.label(ticketRow, "🎟", UITheme.TEXT_SIZE.large, UITheme.COLOR.gold)
	ticketIcon.Position = UDim2.fromOffset(10, 0)
	ticketIcon.Size = UDim2.new(0, 32, 1, 0)
	self.tickets = UITheme.label(ticketRow, "0", UITheme.TEXT_SIZE.large, UITheme.COLOR.gold)
	self.tickets.Position = UDim2.fromOffset(44, 0)
	self.tickets.Size = UDim2.new(1, -52, 1, 0)

	-- ---- ball preview --------------------------------------------------
	local preview = panel(root, 2, 132)
	self.previewFrame = preview

	local revealInfo = source(nil)
	local orb = BallIcon.new {
		name = "RevealBall",
		info = revealInfo,
		discovered = function() return revealInfo() ~= nil end,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 6),
		size = UDim2.fromOffset(72, 72),
		zindex = 3,
	}
	orb.Parent = preview
	self.orb = orb
	self.revealInfo = revealInfo

	self.ballName = UITheme.label(preview, "—", UITheme.TEXT_SIZE.body)
	self.ballName.Position = UDim2.new(0, 0, 0, 78)
	self.ballName.Size = UDim2.new(1, 0, 0, 22)
	self.ballName.TextXAlignment = Enum.TextXAlignment.Center

	-- The canonical identity. Deliberately the largest text in the panel.
	self.oneIn = UITheme.label(preview, "ROLL TO START", UITheme.TEXT_SIZE.large)
	self.oneIn.Position = UDim2.new(0, 0, 0, 98)
	self.oneIn.Size = UDim2.new(1, 0, 0, 30)
	self.oneIn.TextXAlignment = Enum.TextXAlignment.Center
	self.oneIn.TextScaled = true
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = UITheme.TEXT_SIZE.large
	constraint.Parent = self.oneIn

	-- ---- category chip -------------------------------------------------
	local chip = Instance.new("Frame")
	chip.BackgroundColor3 = UITheme.COLOR.slate
	chip.BorderSizePixel = 0
	chip.LayoutOrder = 3
	chip.Size = UDim2.new(1, 0, 0, 24)
	chip.Parent = root
	UITheme.corner(chip, UITheme.CORNER.pill)
	UITheme.stroke(chip, UITheme.STROKE.thin)
	self.chip = chip
	self.chipText = UITheme.label(chip, "—", UITheme.TEXT_SIZE.small, UITheme.COLOR.textOutline)
	self.chipText.Size = UDim2.fromScale(1, 1)
	self.chipText.TextXAlignment = Enum.TextXAlignment.Center
	self.chipText.TextStrokeTransparency = 1

	-- ---- mutation badge ------------------------------------------------
	-- NEVER SUPPRESSED by any effects setting: a mutation is the result, not decoration.
	-- Hidden only when the ball did not mutate, and it sits directly under the identity so
	-- the canonical "1 IN X" always reads first.
	local mutation = Instance.new("Frame")
	mutation.BackgroundColor3 = UITheme.COLOR.blue
	mutation.BorderSizePixel = 0
	mutation.LayoutOrder = 4
	mutation.Size = UDim2.new(1, 0, 0, 28)
	mutation.Visible = false
	mutation.Parent = root
	UITheme.corner(mutation, UITheme.CORNER.normal)
	UITheme.stroke(mutation, UITheme.STROKE.normal)
	self.mutationBadge = mutation

	self.mutationText = UITheme.label(mutation, "", UITheme.TEXT_SIZE.small)
	self.mutationText.Size = UDim2.fromScale(1, 1)
	self.mutationText.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- luck ----------------------------------------------------------
	local luckRow = panel(root, 5, 34)
	self.luck = UITheme.label(luckRow, "x1.00 LUCK", UITheme.TEXT_SIZE.body, UITheme.COLOR.green)
	self.luck.Position = UDim2.fromOffset(10, 0)
	self.luck.Size = UDim2.new(1, -18, 1, 0)

	-- ---- live effective odds -------------------------------------------
	self.odds = UITheme.label(root, "", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	self.odds.LayoutOrder = 6
	self.odds.Size = UDim2.new(1, 0, 0, 16)
	self.odds.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- storage summary -----------------------------------------------
	-- The old row of dots previewed the next few QUEUED balls. There is no queue any more:
	-- which ball drops next is decided at reservation time from the whole collection, so a
	-- fixed preview would be a lie. What replaces it is the honest pair of facts -- how much
	-- is stored, and which rule the hopper is using to pick from it.
	local storageRow = panel(root, 7, 40)
	self.storageRow = storageRow
	UITheme.padding(storageRow, UITheme.PAD.tight)

	self.storedLabel = UITheme.label(storageRow, "STORED 0", UITheme.TEXT_SIZE.small)
	self.storedLabel.Size = UDim2.new(1, 0, 0, 18)
	self.storedLabel.TextXAlignment = Enum.TextXAlignment.Center

	self.feedRule = UITheme.label(storageRow, "", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	self.feedRule.Position = UDim2.new(0, 0, 0, 18)
	self.feedRule.Size = UDim2.new(1, 0, 0, 14)
	self.feedRule.TextXAlignment = Enum.TextXAlignment.Center

	-- ---- ROLL FREE -----------------------------------------------------
	local roll = Instance.new("TextButton")
	roll.Name = "Roll"
	roll.AutoButtonColor = false
	roll.BackgroundColor3 = UITheme.COLOR.green
	roll.BorderSizePixel = 0
	roll.LayoutOrder = 8
	roll.Size = UDim2.new(1, 0, 0, 56)
	roll.Text = ""
	roll.Parent = root
	UITheme.corner(roll, UITheme.CORNER.large)
	UITheme.stroke(roll, UITheme.STROKE.thick)
	UITheme.studPattern(roll, 8, 3, 0.9)
	self.rollButton = roll

	self.rollLabel = UITheme.label(roll, "ROLL FREE", UITheme.TEXT_SIZE.large)
	self.rollLabel.Size = UDim2.fromScale(1, 1)
	self.rollLabel.TextXAlignment = Enum.TextXAlignment.Center
	self.rollLabel.ZIndex = 3

	-- cooldown wipe
	local cooldown = Instance.new("Frame")
	cooldown.BackgroundColor3 = Color3.new(0, 0, 0)
	cooldown.BackgroundTransparency = 0.65
	cooldown.BorderSizePixel = 0
	cooldown.Size = UDim2.fromScale(0, 1)
	cooldown.ZIndex = 2
	cooldown.Parent = roll
	UITheme.corner(cooldown, UITheme.CORNER.large)
	self.cooldown = cooldown

	roll.MouseButton1Down:Connect(function()
		TweenService:Create(roll, UITheme.EASE_PRESS, { Size = UDim2.new(1, -6, 0, 52) }):Play()
	end)
	local function releaseRoll()
		TweenService:Create(roll, UITheme.EASE_PRESS, { Size = UDim2.new(1, 0, 0, 56) }):Play()
	end
	roll.MouseButton1Up:Connect(releaseRoll)
	roll.MouseLeave:Connect(releaseRoll)
	roll.Activated:Connect(function()
		if callbacks.onRoll then
			callbacks.onRoll()
		end
	end)

	-- ---- auto roll -----------------------------------------------------
	local auto = Instance.new("TextButton")
	auto.Name = "AutoRoll"
	auto.AutoButtonColor = false
	auto.BackgroundColor3 = UITheme.COLOR.locked
	auto.BorderSizePixel = 0
	auto.LayoutOrder = 9
	auto.Size = UDim2.new(1, 0, 0, UITheme.TOUCH_MIN)
	auto.Text = ""
	auto.Parent = root
	UITheme.corner(auto, UITheme.CORNER.normal)
	UITheme.stroke(auto, UITheme.STROKE.normal)
	self.autoButton = auto

	self.autoLabel = UITheme.label(auto, "AUTO ROLL  LOCKED", UITheme.TEXT_SIZE.small)
	self.autoLabel.Size = UDim2.fromScale(1, 1)
	self.autoLabel.TextXAlignment = Enum.TextXAlignment.Center
	self.autoLabel.ZIndex = 3

	auto.Activated:Connect(function()
		if callbacks.onToggleAuto then
			callbacks.onToggleAuto()
		end
	end)

	-- ---- counts --------------------------------------------------------
	self.counts = UITheme.label(root, "IN PLAY 0 / 10", UITheme.TEXT_SIZE.tiny, UITheme.COLOR.textDim)
	self.counts.LayoutOrder = 10
	self.counts.Size = UDim2.new(1, 0, 0, 16)
	self.counts.TextXAlignment = Enum.TextXAlignment.Center

	return self
end

-- ---------------------------------------------------------------- updates

function RollPanel:setReveal(reveal)
	self.revealInfo(reveal)
	self.ballName.Text = reveal.name:upper()

	if reveal.baseOneIn then
		self.oneIn.Text = "1 IN " .. Economy.formatOneIn(reveal.baseOneIn)
	else
		-- Basic is the remainder, not a denominator. Never given a fake clean number.
		self.oneIn.Text = "BASIC"
	end

	self.chip.BackgroundColor3 = reveal.tint
	self.chipText.Text = reveal.forced and (reveal.category .. "  · DEV FORCED") or reveal.category

	-- The mutation is shown SEPARATELY from the ball's identity. The canonical 1 IN X above
	-- is the ball; this is an extra property it happens to carry.
	local mutated = reveal.mutationId and reveal.mutationId ~= "NONE"
	self.mutationBadge.Visible = mutated == true
	if mutated then
		self.mutationBadge.BackgroundColor3 = reveal.mutationTint or UITheme.COLOR.blue
		self.mutationText.Text = reveal.forcedMutation
			and ("%s  ·  %gx VALUE  ·  DEV FORCED"):format(reveal.mutationName:upper(), reveal.mutationValue)
			or ("%s  ·  %gx VALUE"):format(reveal.mutationName:upper(), reveal.mutationValue)
	end

	local function asOdds(chance: number): string
		-- A "1 in X" is the wrong shape for a common outcome: Basic's 66% rounds to
		-- "1 in 2", which reads as 50%. Anything above a tenth is shown as a percentage.
		if chance >= 0.1 then
			return ("~%.0f%%"):format(chance * 100)
		end
		return ("~1 in %s"):format(Economy.formatOneIn(1 / chance))
	end

	local parts = { ("ROLLED AT x%.2f LUCK"):format(reveal.luckAtRoll) }
	if reveal.exactChance and reveal.exactChance > 0 then
		table.insert(parts, "current exact " .. asOdds(reveal.exactChance))
	end
	-- The ball-plus-mutation figure, computed from the two SNAPSHOTTED probabilities rather
	-- than from a headline number, so it is true for this roll and not for an average one.
	if reveal.combinedChance and reveal.combinedChance > 0 then
		table.insert(parts, "with " .. reveal.mutationName:upper() .. " " .. asOdds(reveal.combinedChance))
	end
	self.odds.Text = table.concat(parts, "   ·   ")

	-- reveal pop, scaled by rarity
	local baseSize = self.compact and 50 or 72
	local scale = 1 + 0.35 * (reveal.presentation and reveal.presentation.reveal or 0.3)
	self.orb.Size = UDim2.fromOffset(baseSize * scale, baseSize * scale)
	TweenService:Create(self.orb, UITheme.EASE_OUT, { Size = UDim2.fromOffset(baseSize, baseSize) }):Play()
end

function RollPanel:setState(state)
	self.tickets.Text = Economy.formatTickets(state.tickets)
	self.luck.Text = ("x%.2f LUCK"):format(state.luck)
	-- ONE number now, and it is the only real limit: how many balls are physically on the
	-- table. Storage has no cap, so there is nothing to show as a fraction and nothing that
	-- can ever read as "full".
	self.counts.Text = ("IN PLAY %d / %d"):format(state.activeBalls, state.activeCap or 10)

	local stored = state.stored or 0
	self.storedLabel.Text = ("STORED %s"):format(Economy.formatTickets(stored))
	if stored > 0 and not state.hasEligibleBalls then
		-- TRUTHFUL IDLE. Owning balls the hopper is not allowed to touch is a state the
		-- player chose, so it is explained rather than left looking broken.
		self.feedRule.Text = "NO ELIGIBLE BALLS - AUTO ROLL STILL ADDING"
		self.feedRule.TextColor3 = UITheme.COLOR.gold
	elseif state.selectionMode == "BEST" then
		self.feedRule.Text = "FEEDING YOUR BEST BALL"
		self.feedRule.TextColor3 = UITheme.COLOR.gold
	else
		self.feedRule.Text = ("%d KINDS STORED"):format(state.storedVariants or 0)
		self.feedRule.TextColor3 = UITheme.COLOR.textDim
	end

	-- ROLL CAN NEVER BE REFUSED FOR CAPACITY any more, so it never renders as blocked.
	self.rollLabel.Text = "ROLL FREE"
	self.rollButton.BackgroundColor3 = UITheme.COLOR.green

	if not state.autoRollUnlocked then
		self.autoLabel.Text = "AUTO ROLL  LOCKED"
		self.autoButton.BackgroundColor3 = UITheme.COLOR.locked
	elseif state.autoRoll then
		self.autoLabel.Text = "AUTO ROLL  ON"
		self.autoButton.BackgroundColor3 = UITheme.COLOR.greenDeep
	else
		self.autoLabel.Text = "AUTO ROLL  OFF"
		self.autoButton.BackgroundColor3 = UITheme.COLOR.slate
	end

end

function RollPanel:pulseCooldown(seconds: number)
	self.cooldown.Size = UDim2.fromScale(1, 1)
	TweenService:Create(self.cooldown,
		TweenInfo.new(seconds, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(0, 1) }):Play()
end

-- Narrow viewports collapse the panel to a compact top-left card; Roll and Auto Roll are
-- re-parented near the bottom by the HUD so they stay reachable by thumb.
function RollPanel:setCompact(compact: boolean)
	self.compact = compact
	self.previewFrame.Size = UDim2.new(1, 0, 0, compact and 96 or 132)
	self.orb.Size = UDim2.fromOffset(compact and 50 or 72, compact and 50 or 72)
	self.ballName.Position = UDim2.new(0, 0, 0, compact and 56 or 78)
	self.oneIn.Position = UDim2.new(0, 0, 0, compact and 74 or 98)
	self.storageRow.Visible = not compact
	self.odds.Visible = not compact
	-- The mutation badge is NEVER hidden by layout either; only by there being no mutation.
end

return RollPanel
