--!strict
-- Rebirth presentation and intent only.
--
-- The server snapshot supplies the exact requirement, reward, eligibility and permanent
-- totals. This panel previews them and sends one opaque request token; it never computes or
-- submits a Token award, Luck bonus, reset list or resulting rebirth count.
--
-- The reference image contributes the information hierarchy -- next grants, progress, a
-- blunt reset/keep statement and one large action -- not its stars, shop tabs or styling.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
local UITheme = require(Shared:WaitForChild("UITheme"))
local vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))

local create = vide.create
local derive = vide.derive
local source = vide.source

local RebirthPanel = {}
RebirthPanel.__index = RebirthPanel

local HEADER_H = 52
local CONTENT_H = 390

local EMPTY = {
	count = 0,
	tokens = 0,
	cost = 1000,
	reward = 1,
	eligible = false,
	luckBonus = 0,
	nextLuckBonus = 0.10,
	nextMilestone = nil,
}

function RebirthPanel.new(parent: Instance, callbacks)
	local self = setmetatable({}, RebirthPanel)
	callbacks = callbacks or {}
	self.callbacks = callbacks

	local open = source(false)
	local compact = source(false)
	local tickets = source(0)
	local luck = source(1)
	local rebirth = source(EMPTY)
	local tokenCounter = 0

	self.openSource = open
	self.compactSource = compact
	self.ticketsSource = tickets
	self.luckSource = luck
	self.rebirthSource = rebirth

	local progress = derive(function()
		local state = rebirth()
		if state.cost <= 0 then return 1 end
		return math.clamp(tickets() / state.cost, 0, 1)
	end)

	local function rewardCard(index, title, colour, value, note)
		return create("Frame") {
			Name = title,
			BackgroundColor3 = UITheme.COLOR.panelDeep,
			BorderSizePixel = 0,
			Position = UDim2.new((index - 1) / 3, (index - 1) * 3, 0, 38),
			Size = UDim2.new(1 / 3, -6, 0, 82),
			ZIndex = 23,
			UIKit.corner(UITheme.CORNER.normal),
			UIKit.bevel(UITheme.STROKE.normal),
			create("Frame") {
				BackgroundColor3 = colour,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 7),
				ZIndex = 24,
				UIKit.corner(UITheme.CORNER.normal),
			},
			UIKit.text {
				text = title,
				colour = UITheme.COLOR.textDim,
				size = UITheme.TEXT_SIZE.tiny,
				align = Enum.TextXAlignment.Center,
				position = UDim2.fromOffset(4, 10),
				size2 = UDim2.new(1, -8, 0, 18),
				zindex = 25,
			},
			UIKit.text {
				text = value,
				colour = colour,
				size = UITheme.TEXT_SIZE.body,
				align = Enum.TextXAlignment.Center,
				position = UDim2.fromOffset(4, 27),
				size2 = UDim2.new(1, -8, 0, 29),
				zindex = 25,
			},
			UIKit.text {
				text = note,
				colour = UITheme.COLOR.textDim,
				size = 11,
				align = Enum.TextXAlignment.Center,
				truncate = true,
				position = UDim2.fromOffset(4, 56),
				size2 = UDim2.new(1, -8, 0, 16),
				zindex = 25,
			},
		}
	end

	local function requestRebirth()
		if not rebirth().eligible then return end
		tokenCounter += 1
		if callbacks.onRebirth then
			callbacks.onRebirth(("rebirth:%d:%d")
				:format(math.floor(os.clock() * 1000), tokenCounter))
		end
	end

	local root = create("Frame") {
		Name = "RebirthPanel",
		BackgroundColor3 = UITheme.COLOR.scrim,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = open,
		ZIndex = 20,
		Parent = parent,

		create("Frame") {
			Name = "Window",
			BackgroundColor3 = UITheme.COLOR.board,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = function()
				return compact() and UDim2.new(1, -16, 1, -20)
					or UDim2.new(1, -32, 1, -48)
			end,
			ZIndex = 21,
			create("UISizeConstraint") {
				MaxSize = Vector2.new(880, 600),
				MinSize = Vector2.new(320, 300),
			},
			UIKit.corner(UITheme.CORNER.large),
			UIKit.bevel(UITheme.STROKE.thick),

			create("Frame") {
				Name = "Header",
				BackgroundColor3 = UITheme.COLOR.pink,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, HEADER_H),
				ZIndex = 22,
				UIKit.corner(UITheme.CORNER.large),
				UIKit.stripes(0.90),
				UIKit.text {
					text = "REBIRTH",
					size = UITheme.TEXT_SIZE.large,
					position = UDim2.fromOffset(16, 0),
					size2 = function()
						return compact() and UDim2.new(0, 118, 1, 0)
							or UDim2.new(0, 240, 1, 0)
					end,
					zindex = 23,
				},
				create("Frame") {
					Name = "TokenBadge",
					BackgroundColor3 = UITheme.COLOR.panelDeep,
					BackgroundTransparency = 0.15,
					BorderSizePixel = 0,
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -62, 0.5, 0),
					Size = function()
						return compact() and UDim2.fromOffset(106, 30)
							or UDim2.fromOffset(170, 32)
					end,
					ZIndex = 23,
					UIKit.corner(UITheme.CORNER.pill),
					UIKit.bevel(UITheme.STROKE.normal),
					UIKit.text {
						text = function()
							local amount = rebirth().tokens
							return compact() and ("◆  %d"):format(amount)
								or ("◆  TOKENS  %d"):format(amount)
						end,
						colour = UITheme.COLOR.gold,
						size = UITheme.TEXT_SIZE.small,
						align = Enum.TextXAlignment.Center,
						zindex = 24,
					},
				},
				UIKit.button {
					name = "Close",
					size = UDim2.fromOffset(44, 40),
					position = UDim2.new(1, -52, 0, 6),
					radius = UITheme.CORNER.small,
					accent = UITheme.COLOR.red,
					zindex = 24,
					onClick = function() self:setOpen(false) end,
					children = {
						UIKit.text { text = "X", size = UITheme.TEXT_SIZE.body,
							align = Enum.TextXAlignment.Center },
					},
				},
			},

			create("ScrollingFrame") {
				Name = "Body",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Position = UDim2.fromOffset(12, HEADER_H + 8),
				Size = UDim2.new(1, -24, 1, -(HEADER_H + 16)),
				CanvasSize = UDim2.fromOffset(0, CONTENT_H),
				ScrollingDirection = Enum.ScrollingDirection.Y,
				ScrollBarThickness = 5,
				ScrollBarImageColor3 = UITheme.COLOR.slate,
				ZIndex = 22,

				UIKit.text {
					text = "NEXT REBIRTH GRANTS",
					colour = UITheme.COLOR.textDim,
					size = UITheme.TEXT_SIZE.small,
					position = UDim2.fromOffset(0, 4),
					size2 = UDim2.new(1, 0, 0, 24),
					zindex = 23,
				},

				rewardCard(1, "LUCK", UITheme.COLOR.green,
					function()
						local state = rebirth()
						local gain = math.max(0, (state.nextLuckBonus or 0) - (state.luckBonus or 0))
						return ("x%.2f → x%.2f"):format(luck(), luck() + gain)
					end,
					function()
						local state = rebirth()
						local gain = math.max(0, (state.nextLuckBonus or 0) - (state.luckBonus or 0))
						return ("+%.2f permanent"):format(gain)
					end),
				rewardCard(2, "TOKENS", UITheme.COLOR.gold,
					function() return "+" .. tostring(rebirth().reward) end,
					function() return "banked forever" end),
				rewardCard(3, "REBIRTH", UITheme.COLOR.pink,
					function()
						local count = rebirth().count
						return ("%d → %d"):format(count, count + 1)
					end,
					function() return "new milestones" end),

				create("Frame") {
					Name = "Progress",
					BackgroundColor3 = UITheme.COLOR.panelDeep,
					BorderSizePixel = 0,
					Position = UDim2.fromOffset(0, 130),
					Size = UDim2.new(1, 0, 0, 72),
					ZIndex = 23,
					UIKit.corner(UITheme.CORNER.normal),
					UIKit.bevel(UITheme.STROKE.normal),
					UIKit.text {
						text = function()
							return ("REBIRTH %d REQUIREMENT"):format(rebirth().count + 1)
						end,
						colour = UITheme.COLOR.textDim,
						size = UITheme.TEXT_SIZE.tiny,
						position = UDim2.fromOffset(12, 4),
						size2 = UDim2.new(0.5, -12, 0, 24),
						zindex = 25,
					},
					UIKit.text {
						text = function()
							return ("%s / %s TICKETS"):format(
								Economy.formatTickets(tickets()), Economy.formatTickets(rebirth().cost))
						end,
						colour = function()
							return rebirth().eligible and UITheme.COLOR.green or UITheme.COLOR.text
						end,
						size = UITheme.TEXT_SIZE.small,
						align = Enum.TextXAlignment.Right,
						position = UDim2.new(0.5, 0, 0, 4),
						size2 = UDim2.new(0.5, -12, 0, 24),
						zindex = 25,
					},
					create("Frame") {
						BackgroundColor3 = UITheme.COLOR.outline,
						BorderSizePixel = 0,
						Position = UDim2.fromOffset(12, 40),
						Size = UDim2.new(1, -24, 0, 16),
						ClipsDescendants = true,
						ZIndex = 24,
						UIKit.corner(UITheme.CORNER.pill),
						create("Frame") {
							Name = "Fill",
							BackgroundColor3 = function()
								return rebirth().eligible and UITheme.COLOR.green or UITheme.COLOR.gold
							end,
							BorderSizePixel = 0,
							Size = function() return UDim2.fromScale(progress(), 1) end,
							ZIndex = 25,
							UIKit.corner(UITheme.CORNER.pill),
						},
					},
				},

				create("Frame") {
					Name = "ResetBoundary",
					BackgroundColor3 = UITheme.COLOR.panelDeep,
					BackgroundTransparency = 0.25,
					BorderSizePixel = 0,
					Position = UDim2.fromOffset(0, 210),
					Size = UDim2.new(1, 0, 0, 64),
					ZIndex = 23,
					UIKit.corner(UITheme.CORNER.normal),
					UIKit.text {
						text = function()
							return ("RESETS  TICKETS (%s RIGHT NOW)")
								:format(Economy.formatTickets(tickets()))
						end,
						colour = UITheme.COLOR.red,
						size = UITheme.TEXT_SIZE.small,
						align = Enum.TextXAlignment.Center,
						position = UDim2.fromOffset(8, 6),
						size2 = UDim2.new(1, -16, 0, 23),
						zindex = 24,
					},
					UIKit.text {
						text = "KEEPS  UPGRADES · BALLS · INDEX · ACHIEVEMENTS · SETTINGS · TOKENS",
						colour = UITheme.COLOR.green,
						size = UITheme.TEXT_SIZE.tiny,
						align = Enum.TextXAlignment.Center,
						truncate = true,
						position = UDim2.fromOffset(8, 33),
						size2 = UDim2.new(1, -16, 0, 19),
						zindex = 24,
					},
				},

				create("Frame") {
					Name = "NextUnlock",
					BackgroundColor3 = UITheme.COLOR.slate,
					BackgroundTransparency = 0.25,
					BorderSizePixel = 0,
					Position = UDim2.fromOffset(0, 282),
					Size = UDim2.new(1, 0, 0, 42),
					ZIndex = 23,
					UIKit.corner(UITheme.CORNER.normal),
					UIKit.text {
						text = function()
							local milestone = rebirth().nextMilestone
							if not milestone then return "ALL CURRENT TOKEN MILESTONES UNLOCKED" end
							return ("REBIRTH %d UNLOCKS  %s  ·  %s")
								:format(milestone.rebirth, milestone.title, milestone.description)
						end,
						colour = UITheme.COLOR.text,
						size = UITheme.TEXT_SIZE.tiny,
						align = Enum.TextXAlignment.Center,
						truncate = true,
						position = UDim2.fromOffset(8, 0),
						size2 = UDim2.new(1, -16, 1, 0),
						zindex = 24,
					},
				},

				UIKit.button {
					name = "RebirthNow",
					size = UDim2.new(1, 0, 0, 52),
					position = UDim2.fromOffset(0, 334),
					radius = UITheme.CORNER.large,
					accent = function()
						return rebirth().eligible and UITheme.COLOR.gold or UITheme.COLOR.locked
					end,
					disabled = function() return not rebirth().eligible end,
					motion = "primary",
					zindex = 23,
					onClick = requestRebirth,
					children = {
						UIKit.stripes(0.93),
						UIKit.text {
							text = function()
								if rebirth().eligible then return "REBIRTH NOW" end
								return "NEED " .. Economy.formatTickets(rebirth().cost) .. " TICKETS"
							end,
							colour = function()
								return rebirth().eligible and UITheme.COLOR.textOutline or UITheme.COLOR.text
							end,
							size = UITheme.TEXT_SIZE.large,
							align = Enum.TextXAlignment.Center,
							zindex = 25,
						},
					},
				},
			},
		},
	}

	self.root = root

	return self
end

function RebirthPanel:isOpen(): boolean
	return self.openSource()
end

function RebirthPanel:setOpen(value: boolean)
	self.openSource(value and true or false)
	if self.callbacks.onOpenChanged then
		self.callbacks.onOpenChanged(self.openSource())
	end
end

function RebirthPanel:setCompact(value: boolean)
	self.compactSource(value and true or false)
end

function RebirthPanel:setState(state)
	if type(state) ~= "table" then return end
	if type(state.tickets) == "number" then self.ticketsSource(state.tickets) end
	if type(state.luck) == "number" then self.luckSource(state.luck) end
	if type(state.rebirth) == "table" then self.rebirthSource(state.rebirth) end
end

return RebirthPanel
