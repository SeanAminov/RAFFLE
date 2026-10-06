--!strict
-- ONE BALL, AS A CARD. The unit the Collection grid is made of.
--
-- ---------------------------------------------------------------------------------------
-- THIS FILE OWNS CARD LAYOUT; BallVisualSpec + BallIcon OWN BALL APPEARANCE
--
-- The panel around this owns filtering, sorting, scrolling and controls. BallIcon is the one
-- shared renderer used here and in the roll reveal; BallVisualSpec is the data-only visual
-- contract that later physical-ball cosmetics will consume too.
--
-- ---------------------------------------------------------------------------------------
-- BUILT ONCE, REBOUND MANY TIMES
--
-- A card belongs to a POOL SLOT, not to a variant. `props.key` is a source: scrolling writes
-- a different variant key into it and every property recomputes. So a card must never
-- conditionally create a child based on the variant it currently holds -- the next rebind
-- might need that child. Anything variant-dependent is created ALWAYS and controlled by a
-- reactive property instead.
--
-- That rule is why the mutation ring is always present and merely transparent, rather than
-- created only for mutated variants: a slot showing an ordinary Basic will later show a
-- Charged one, and a missing instance cannot be brought back by a source write.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local BallVariant = require(Shared:WaitForChild("BallVariant"))
local FeedPolicy = require(Shared:WaitForChild("FeedPolicy"))
local Economy = require(Shared:WaitForChild("Economy"))
local vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local BallIcon = require(Client:WaitForChild("BallIcon"))

local create = vide.create
local derive = vide.derive

local BallCard = {}

BallCard.WIDTH = 148

-- 156, not 176. The first pass left ~20px of dead air under the count on every card that had
-- no state flags, which cost a whole ROW of the grid at a 528px window -- two rows visible
-- instead of three. Every element below is packed against this height deliberately.
BallCard.HEIGHT = 156

local LOCKED_BAND = Color3.fromRGB(44, 48, 66)

-- ---------------------------------------------------------------- the visual
--
-- Kept as a tiny adapter so existing callers/tests can still address BallCard.visual while
-- every actual layer comes from the shared renderer.
local function visual(info, discovered)
	return BallIcon.new {
		name = "Visual",
		info = info,
		discovered = discovered,
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 16),
		size = UDim2.fromOffset(62, 62),
		zindex = 3,
	}
end

BallCard.visual = visual

-- ---------------------------------------------------------------- the card

-- props: key (source), rows (source), selected (source), selection (source), onSelect (fn)
--
-- `selected` is FOCUS -- the one card the detail strip is describing. `selection` is the
-- MULTI-SELECTION, a set of keys a bulk action will apply to. They are different questions and
-- are drawn differently: gold ring for focus, green ring plus a tick for marked.
function BallCard.new(props)
	local key, rows, selected = props.key, props.rows, props.selected

	local info = derive(function()
		local k = key()
		return k and BallVariant.info(k) or nil
	end)
	local row = derive(function()
		local k = key()
		return k and rows()[k] or nil
	end)
	local discovered = derive(function() return row() ~= nil end)

	-- Reads the set rather than being told about itself, so scrolling a card into a marked
	-- slot picks the mark up with no extra bookkeeping in the panel.
	local marked = derive(function()
		local k = key()
		if k == nil or not props.selection then
			return false
		end
		return props.selection()[k] == true
	end)

	return UIKit.button {
		name = "BallCard",
		size = UDim2.fromOffset(BallCard.WIDTH, BallCard.HEIGHT),
		radius = UITheme.CORNER.large,
		stroke = UITheme.STROKE.thick,
		accent = function()
			local i = info()
			if not i or not discovered() then
				return UITheme.COLOR.panelDeep
			end
			-- A HINT, not a wash: 18% of the rarity colour over the panel, so the grid reads
			-- as colour-coded at a glance without any card competing with its own contents.
			return UITheme.COLOR.panelDeep:Lerp(i.tint, 0.18)
		end,
		motion = "subtle",
		position = props.position,
		visible = function() return key() ~= nil end,
		onClick = function()
			local k = key()
			if k and props.onSelect then
				props.onSelect(k)
			end
		end,
		children = {
			-- rarity band
			create("Frame") {
				Name = "Band",
				BackgroundColor3 = function()
					local i = info()
					if not i or not discovered() then
						return LOCKED_BAND
					end
					return i.tint
				end,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 22),
				ZIndex = 2,
				create("UICorner") { CornerRadius = UDim.new(0, UITheme.CORNER.large) },
			},
			UIKit.text {
				text = function()
					local i = info()
					if not i then return "" end
					return discovered() and i.category or "???"
				end,
				size = UITheme.TEXT_SIZE.tiny,
				align = Enum.TextXAlignment.Center,
				size2 = UDim2.new(1, 0, 0, 22),
				zindex = 3,
			},

			visual(info, discovered),

			-- name
			UIKit.text {
				text = function()
					local i = info()
					if not i then return "" end
					return discovered() and i.displayName or "UNDISCOVERED"
				end,
				colour = function()
					return discovered() and UITheme.COLOR.text or UITheme.COLOR.textDim
				end,
				size = UITheme.TEXT_SIZE.small,
				align = Enum.TextXAlignment.Center,
				truncate = true,
				position = UDim2.new(0, 4, 0, 72),
				size2 = UDim2.new(1, -8, 0, 17),
				zindex = 4,
			},

			-- THE CANONICAL DENOMINATOR, never the live odds. This is what the ball IS; the
			-- roll panel is where current-Luck odds belong.
			UIKit.text {
				text = function()
					local i = info()
					if not i then return "" end
					if not i.oneIn then return "BASIC" end
					return "1 IN " .. Economy.formatOneIn(i.oneIn)
				end,
				colour = UITheme.COLOR.textDim,
				size = UITheme.TEXT_SIZE.tiny,
				align = Enum.TextXAlignment.Center,
				position = UDim2.new(0, 4, 0, 89),
				size2 = UDim2.new(1, -8, 0, 13),
				zindex = 4,
			},

			-- owned count
			UIKit.text {
				text = function()
					local r = row()
					if not r then return "" end
					return "x" .. Economy.formatTickets(r.count)
				end,
				size = UITheme.TEXT_SIZE.large,
				align = Enum.TextXAlignment.Center,
				position = UDim2.new(0, 0, 0, 102),
				size2 = UDim2.new(1, 0, 0, 28),
				zindex = 4,
			},

			-- STATE ICONS, not controls. The real controls live in the detail strip; putting
			-- five of them on every pooled card would be ninety idle interactive instances.
			UIKit.text {
				text = function()
					local r = row()
					if not r then return "" end
					local marks = {}
					if r.hold then table.insert(marks, "HOLD") end
					if not r.autoFeed then table.insert(marks, "OFF") end
					if r.favorite then table.insert(marks, "\u{2605}") end
					if r.keepAtLeast ~= 0 then
						table.insert(marks, "K" .. FeedPolicy.keepLabel(r.keepAtLeast))
					end
					return table.concat(marks, "  ")
				end,
				colour = UITheme.COLOR.gold,
				size = UITheme.TEXT_SIZE.tiny,
				align = Enum.TextXAlignment.Center,
				position = UDim2.new(0, 0, 1, -19),
				size2 = UDim2.new(1, 0, 0, 16),
				zindex = 4,
			},

			UIKit.badge {
				text = "NEW",
				position = UDim2.fromOffset(-4, -6),
				size = UDim2.fromOffset(44, 20),
				textSize = UITheme.TEXT_SIZE.tiny,
				visible = function()
					local r = row()
					return r ~= nil and r.isNew == true
				end,
			},

			-- THE MARK, always created and merely hidden. A card that built this child only
			-- for marked variants would lose it on the next rebind, and no source write can
			-- bring back an instance that was never made.
			create("Frame") {
				Name = "Mark",
				BackgroundColor3 = UITheme.COLOR.green,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -6, 0, 26),
				Size = UDim2.fromOffset(24, 24),
				Visible = marked,
				ZIndex = 6,
				create("UICorner") { CornerRadius = UDim.new(0, 7) },
				create("UIStroke") { Thickness = 2, Color = UITheme.COLOR.textOutline },
				UIKit.text {
					text = "\u{2713}",
					size = UITheme.TEXT_SIZE.small,
					align = Enum.TextXAlignment.Center,
					colour = UITheme.COLOR.textOutline,
					zindex = 7,
				},
			},

			-- SELECTION RING, one stroke doing two jobs rather than two strokes fighting over
			-- the same instance. Green wins when a card is both marked and focused, because the
			-- bulk action is the thing about to happen to it.
			create("UIStroke") {
				Thickness = 4,
				Color = function()
					return marked() and UITheme.COLOR.green or UITheme.COLOR.gold
				end,
				Transparency = function()
					local k = key()
					if k == nil then
						return 1
					end
					return (marked() or selected() == k) and 0 or 1
				end,
			},
		},
	}
end

return BallCard
