--!strict
-- ACHIEVEMENTS: what you are working towards, how close you are, and what you have not
-- collected yet.
--
-- ---------------------------------------------------------------------------------------
-- WHY THIS ONE IS NOT VIRTUALISED AND THE COLLECTION IS
--
-- The Collection grid is bounded by the CATALOG, which is 24 variants today and is meant to
-- grow into the hundreds. This list is bounded by AchievementConfig, which is eight and grows
-- by hand. Eight rows built once is cheaper in every dimension than a pool, and pooling here
-- would be machinery defending against a problem that cannot occur.
--
-- If the set ever reaches a few dozen, the ScrollingFrame is already here and the rows are
-- already built from a config list; the change would be to bind them to slots the way
-- CollectionPanel does.
--
-- ---------------------------------------------------------------------------------------
-- THE PANEL NEVER DECIDES WHETHER SOMETHING IS CLAIMABLE
--
-- It draws what the snapshot says and sends an ID when the button is pressed. The server
-- re-derives whether the goal is met, decides the reward from its own config, and refuses a
-- second claim because the flag is already set. A player who edits this file can make the
-- button gold; they cannot make it pay.
--
-- ---------------------------------------------------------------------------------------
-- LESSONS THIS PANEL WAS BORN WITH
--
-- Two bugs shipped in this UI already, both of them a control that existed but could not be
-- reached. So: the close is in the header where it cannot be pushed off the bottom, the
-- window is responsive with a size constraint rather than a fixed rectangle, and the rows
-- scroll rather than overflow.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local AchievementConfig = require(Shared:WaitForChild("AchievementConfig"))
local Economy = require(Shared:WaitForChild("Economy"))
local vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))

local create = vide.create
local source = vide.source
local derive = vide.derive

local AchievementsPanel = {}
AchievementsPanel.__index = AchievementsPanel

local ROW_H = 76
local ROW_GAP = 8

-- ---------------------------------------------------------------- one row

-- `data` is the whole achievement block from the snapshot; the row reads its own entry out of
-- it. Passing the block rather than three pre-extracted values means a row added later can
-- read a field this one does not, without changing the caller.
local function row(def, data, compact, onClaim)
	local progress = derive(function()
		local d = data()
		return d and d.progress and d.progress[def.id] or 0
	end)
	local unlocked = derive(function()
		local d = data()
		return (d and d.unlocked and d.unlocked[def.id]) == true
	end)
	local claimed = derive(function()
		local d = data()
		return (d and d.claimed and d.claimed[def.id]) == true
	end)
	local fraction = derive(function()
		return math.clamp(progress() / def.threshold, 0, 1)
	end)

	-- The button is ALWAYS present and merely restyled. A button that appears when a goal
	-- unlocks would shift every row below it at the moment the player is reading them.
	local button = UIKit.button {
		name = "Claim",
		size = function()
			return UDim2.fromOffset(compact() and 92 or 108, 38)
		end,
		position = function()
			return UDim2.new(1, compact() and -100 or -116, 0, (ROW_H - 38) / 2)
		end,
		radius = UITheme.CORNER.small,
		stroke = UITheme.STROKE.normal,
		-- Gold only when there is something to collect. Claimed and locked are both inert and
		-- read as inert.
		accent = function()
			if claimed() then
				return UITheme.COLOR.panelDeep
			end
			return unlocked() and UITheme.COLOR.gold or UITheme.COLOR.slate
		end,
		-- Eight repeated row controls should acknowledge hover once, not wobble like the main
		-- Roll/Rebirth actions. The quick tier gives one small lift and is already settled by
		-- the time the pointer can reach the next row.
		motion = "quick",
		zindex = 4,
		onClick = function()
			-- Refused locally when there is nothing to collect, purely to avoid a pointless
			-- packet. The server refuses it too, and that is the refusal that matters.
			if unlocked() and not claimed() and onClaim then
				onClaim(def.id)
			end
		end,
		children = {
			UIKit.text {
				text = function()
					if claimed() then
						return "CLAIMED"
					end
					if unlocked() then
						return "+" .. Economy.formatTickets(def.reward)
					end
					return "LOCKED"
				end,
				size = UITheme.TEXT_SIZE.tiny,
				align = Enum.TextXAlignment.Center,
				colour = function()
					if claimed() then
						return UITheme.COLOR.textDim
					end
					return unlocked() and UITheme.COLOR.textOutline or UITheme.COLOR.text
				end,
				zindex = 5,
			},
		},
	}

	return create("Frame") {
		Name = def.id,
		BackgroundColor3 = UITheme.COLOR.panelDeep,
		BackgroundTransparency = function()
			-- A claimed goal recedes. It stays in the list -- removing it would make the list
			-- shrink as you succeed, which reads as losing something.
			return claimed() and 0.45 or 0
		end,
		BorderSizePixel = 0,
		LayoutOrder = def.order,
		Size = UDim2.new(1, 0, 0, ROW_H),
		ZIndex = 3,

		UIKit.corner(UITheme.CORNER.normal),
		UIKit.bevel(UITheme.STROKE.normal),

		UIKit.text {
			text = def.displayName,
			size = UITheme.TEXT_SIZE.small,
			colour = function()
				return claimed() and UITheme.COLOR.textDim or UITheme.COLOR.text
			end,
			position = UDim2.fromOffset(12, 8),
			size2 = function()
				return UDim2.new(1, compact() and -122 or -140, 0, 20)
			end,
			truncate = true,
			zindex = 4,
		},

		UIKit.text {
			text = def.description,
			size = UITheme.TEXT_SIZE.tiny,
			colour = UITheme.COLOR.textDim,
			position = UDim2.fromOffset(12, 28),
			size2 = function()
				return UDim2.new(1, compact() and -122 or -140, 0, 16)
			end,
			truncate = true,
			zindex = 4,
		},

		-- THE BAR. Track and fill, two frames, no tween: it is driven by a snapshot that
		-- arrives five times a second and a spring on top of that would lag the number
		-- printed beside it.
		create("Frame") {
			Name = "Track",
			BackgroundColor3 = UITheme.COLOR.scrim,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(12, 52),
			Size = function()
				return UDim2.new(1, compact() and -122 or -140, 0, 10)
			end,
			ZIndex = 4,
			create("UICorner") { CornerRadius = UDim.new(1, 0) },

			create("Frame") {
				Name = "Fill",
				BackgroundColor3 = function()
					return unlocked() and UITheme.COLOR.gold or UITheme.COLOR.green
				end,
				BorderSizePixel = 0,
				Size = function()
					return UDim2.fromScale(fraction(), 1)
				end,
				ZIndex = 5,
				create("UICorner") { CornerRadius = UDim.new(1, 0) },
			},

			-- The exact numbers, right-aligned over the track. "412 / 1000" answers "how much
			-- more" in a way a bar alone never does.
			UIKit.text {
				text = function()
					if claimed() or unlocked() then
						return ""
					end
					return ("%s / %s"):format(
						Economy.formatTickets(progress()), Economy.formatTickets(def.threshold))
				end,
				size = UITheme.TEXT_SIZE.tiny,
				colour = UITheme.COLOR.textDim,
				align = Enum.TextXAlignment.Right,
				position = UDim2.fromOffset(0, -16),
				size2 = UDim2.new(1, 0, 0, 14),
				zindex = 6,
			},
		},

		button,
	}
end

-- ---------------------------------------------------------------- construction

function AchievementsPanel.new(parent: Instance, callbacks)
	local self = setmetatable({}, AchievementsPanel)
	callbacks = callbacks or {}
	self.callbacks = callbacks

	local open = source(false)
	local data = source(nil)
	local compact = source(false)

	self.open, self.data, self.compact = open, data, compact

	local claimable = derive(function()
		local d = data()
		return d and d.claimable or 0
	end)
	self.claimable = claimable

	local rows = {}
	for _, def in ipairs(AchievementConfig.all()) do
		table.insert(rows, row(def, data, compact, callbacks.onClaim))
	end

	local list = create("ScrollingFrame") {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = UITheme.COLOR.slate,
		ZIndex = 22,

		create("UIListLayout") {
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, ROW_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
		-- Right padding so the last row does not sit under the scrollbar.
		create("UIPadding") { PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 6) },

		table.unpack(rows),
	}

	local root = create("Frame") {
		Name = "AchievementsPanel",
		BackgroundColor3 = UITheme.COLOR.scrim,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = open,
		ZIndex = 20,
		Parent = parent,

		create("Frame") {
			Name = "Window",
			BackgroundColor3 = UITheme.COLOR.panel,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			-- RESPONSIVE WITH A CAP. A fixed rectangle is what hung the Collection window off
			-- the top of a short viewport; the cap is what stops this becoming an empty field
			-- on a large monitor.
			Size = function()
				return compact() and UDim2.new(1, -16, 1, -20) or UDim2.new(1, -32, 1, -48)
			end,
			ZIndex = 21,

			create("UISizeConstraint") {
				MaxSize = Vector2.new(620, 660),
				MinSize = Vector2.new(300, 260),
			},

			UIKit.corner(UITheme.CORNER.large),
			UIKit.bevel(UITheme.STROKE.thick),

			create("Frame") {
				Name = "Header",
				BackgroundColor3 = UITheme.COLOR.gold,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 52),
				ZIndex = 22,
				UIKit.corner(UITheme.CORNER.large),
				UIKit.stripes(0.9),

				UIKit.text {
					text = "ACHIEVEMENTS",
					size = UITheme.TEXT_SIZE.large,
					colour = UITheme.COLOR.textOutline,
					position = UDim2.fromOffset(16, 0),
					size2 = UDim2.new(1, -180, 1, 0),
					zindex = 23,
				},

				-- How many are sitting there uncollected. The one number worth putting in the
				-- header, because it is the reason to have opened the panel.
				UIKit.text {
					text = function()
						local n = claimable()
						if n == 0 then
							return ""
						end
						return ("%d TO CLAIM"):format(n)
					end,
					size = UITheme.TEXT_SIZE.small,
					colour = UITheme.COLOR.textOutline,
					align = Enum.TextXAlignment.Right,
					position = UDim2.new(1, -116, 0, 0),
					size2 = UDim2.fromOffset(104, 52),
					zindex = 23,
				},

				-- IN THE HEADER, where content growth cannot push it off the screen.
				UIKit.button {
					name = "Close",
					size = UDim2.fromOffset(44, 38),
					position = UDim2.new(1, -52, 0, 7),
					radius = UITheme.CORNER.small,
					accent = UITheme.COLOR.red,
					zindex = 23,
					onClick = function() self:setOpen(false) end,
					children = {
						UIKit.text { text = "X", size = UITheme.TEXT_SIZE.body,
							align = Enum.TextXAlignment.Center },
					},
				},
			},

			create("Frame") {
				Name = "Body",
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(0, 52),
				Size = UDim2.new(1, 0, 1, -52),
				ZIndex = 22,
				create("UIPadding") {
					PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
					PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
				},
				list,
			},
		},
	}

	self.root = root
	self.list = list

	self.setDataForTest = function(value) data(value) end
	self.rowsForTest = rows

	return self
end

function AchievementsPanel:isOpen(): boolean
	return self.open()
end

function AchievementsPanel:setOpen(value: boolean)
	self.open(value and true or false)
	if self.callbacks.onOpenChanged then
		self.callbacks.onOpenChanged(self.open())
	end
end

-- The achievement block arrives inside the ordinary state snapshot rather than on its own
-- remote: it is eight small entries, the same order of size as `ranks`, which that snapshot
-- already carries at the same rate.
function AchievementsPanel:setState(state)
	if state and state.achievements then
		self.data(state.achievements)
	end
end

function AchievementsPanel:claimableCount(): number
	return self.claimable()
end

function AchievementsPanel:setCompact(value: boolean)
	self.compact(value and true or false)
end

return AchievementsPanel
