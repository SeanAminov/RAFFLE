--!strict
-- ONE panel for every locked navigation tile.
--
-- A locked tile that opens nothing is worse than no tile at all -- the player clicks, gets no
-- response, and concludes the button is broken. This opens, names the system, and says
-- plainly that it does not exist yet.
--
-- WHAT IT DELIBERATELY DOES NOT HAVE: a progress bar, a badge, an unlock requirement, a
-- currency, a countdown, or a purchase button. Every one of those would imply the system is
-- partly built and being withheld. It is not built.
--
-- It is SHARED rather than one panel per locked tile, because the content is entirely data --
-- a title and a sentence. Achievements and Rebirth differ by two strings.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))

local create = vide.create
local source = vide.source

local LockedPanel = {}
LockedPanel.__index = LockedPanel

function LockedPanel.new(parent: Instance)
	local self = setmetatable({}, LockedPanel)

	local open = source(false)
	local title = source("")
	local message = source("")
	local currentId = source(nil)

	self.openSource, self.titleSource = open, title
	self.messageSource, self.currentIdSource = message, currentId

	self.root = create("Frame") {
		Name = "LockedPanel",
		BackgroundColor3 = UITheme.COLOR.scrim,
		BackgroundTransparency = 0.35,
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
			Size = UDim2.fromOffset(460, 260),
			ZIndex = 21,

			UIKit.corner(UITheme.CORNER.large),
			UIKit.bevel(UITheme.STROKE.thick),

			create("Frame") {
				Name = "Header",
				BackgroundColor3 = UITheme.COLOR.slate,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 54),
				ZIndex = 22,
				UIKit.corner(UITheme.CORNER.large),
				UIKit.stripes(0.93),
				UIKit.text {
					text = title,
					size = UITheme.TEXT_SIZE.large,
					position = UDim2.fromOffset(16, 0),
					size2 = UDim2.new(1, -70, 1, 0),
					zindex = 23,
				},
				UIKit.button {
					name = "Close",
					size = UDim2.fromOffset(40, 36),
					position = UDim2.new(1, -48, 0, 9),
					radius = UITheme.CORNER.small,
					accent = UITheme.COLOR.red,
					zindex = 23,
					onClick = function() open(false) end,
					children = {
						UIKit.text { text = "X", size = UITheme.TEXT_SIZE.body,
							align = Enum.TextXAlignment.Center },
					},
				},
			},

			UIKit.text {
				text = "COMING LATER",
				colour = UITheme.COLOR.gold,
				size = UITheme.TEXT_SIZE.body,
				align = Enum.TextXAlignment.Center,
				position = UDim2.fromOffset(0, 78),
				size2 = UDim2.new(1, 0, 0, 26),
				zindex = 22,
			},

			create("TextLabel") {
				Name = "Message",
				BackgroundTransparency = 1,
				Font = UITheme.FONT.body,
				Text = message,
				TextColor3 = UITheme.COLOR.textDim,
				TextSize = UITheme.TEXT_SIZE.small,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(28, 116),
				Size = UDim2.new(1, -56, 0, 100),
				ZIndex = 22,
			},
		},
	}

	return self
end

function LockedPanel:isOpen(): boolean
	return self.openSource()
end

function LockedPanel:currentId(): string?
	return self.currentIdSource()
end

function LockedPanel:setOpen(value: boolean)
	self.openSource(value and true or false)
	if not value then
		self.currentIdSource(nil)
	end
end

function LockedPanel:show(id: string, label: string, text: string, open: boolean)
	self.titleSource(string.upper(label))
	self.messageSource(text)
	self.currentIdSource(open and id or nil)
	self.openSource(open and true or false)
end

return LockedPanel
