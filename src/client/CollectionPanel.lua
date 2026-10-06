--!strict
-- THE COLLECTION: what you have discovered, what you own, and what the hopper may take.
--
-- Two views of one dataset:
--   INDEX    every catalog variant, discovered or not. Undiscovered ones are silhouettes.
--   STORAGE  what you actually own, with the controls that govern it.
--
-- ---------------------------------------------------------------------------------------
-- THE PERFORMANCE RULE, WHICH SHAPES EVERYTHING ELSE
--
-- INSTANCE COUNT IS BOUNDED BY SCREEN SIZE, NOT BY CATALOG SIZE.
--
-- A fixed pool of cards is built once. Scrolling REBINDS those cards to different variants
-- rather than creating new ones, so 24 variants and 2,400 variants produce identical instance
-- counts and identical frame cost. Vide then updates only the properties that actually
-- differ, because each card reads from a source rather than being rebuilt.
--
-- That is also why the five per-variant controls are NOT on the card. Five controls times
-- eighteen pooled cards is ninety interactive instances that are almost always idle. The card
-- shows compact STATE ICONS; selecting it opens one detail strip with the real controls.
--
-- Connections: THREE. Two on the scroll frame (canvas position and absolute size) and one on
-- the window (absolute size, which the layout is computed from). Everything else is Vide
-- reacting to sources, driven by the Ticker the client already had.
--
-- ---------------------------------------------------------------------------------------
-- THE CLIENT NEVER DECIDES ANYTHING
--
-- Every control sends INTENT. The server owns the policy, validates the variant, normalises
-- the patch and replies through the ordinary inventory sync. Nothing here writes a count, and
-- the panel cannot make a ball feedable that the server would refuse -- it only asks.
--
-- FILTERING AND SORTING ARE A PURE READ. There is no write path from a filter to a policy, so
-- "filters must never silently change feed preferences" is true by construction.
--
-- ---------------------------------------------------------------------------------------
-- BULK EDITING IS ONE PACKET
--
-- SELECT mode swaps the tap gesture from "focus this card" to "mark this card", and swaps the
-- detail strip for a bulk bar. Every bulk button sends ONE SetVariantPolicy carrying the whole
-- list of marked keys.
--
-- It has to be one packet. The server rate-limits policy edits, so firing one per marked
-- variant would land the first and drop the rest -- a "hold everything" button that held
-- exactly one thing, which is worse than not having the button at all. The list is capped at
-- Economy.MAX_POLICY_BATCH on both sides, and the bar says so when it caps.
--
-- ---------------------------------------------------------------------------------------
-- EVERY HORIZONTAL ROW SCROLLS
--
-- Filters, sorts, the detail strip and the bulk bar are all wider than a phone. Each lives in
-- a horizontal ScrollingFrame, which hides its own scrollbar when the canvas fits -- so the
-- desktop layout pays nothing and the narrow layout cannot push a control off the edge.
--
-- That is deliberate rather than incidental. The last two bugs in this UI were both a control
-- that existed but could not be reached, and a row that silently overflows is exactly how you
-- get a third one.
--
-- The vertical stack is computed in ONE place from the window's measured size, so the grid can
-- never disagree with the rows above it about where it starts.
--
-- IT MEASURES RATHER THAN BEING TOLD. A device class handed down from the HUD is a proxy for
-- the question that actually matters, and it gets the answer wrong: a landscape phone at
-- 844x390 is not "compact" by width, but its 342px-tall window has less vertical room than any
-- portrait phone. Measuring the window answers both questions directly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local BallVariant = require(Shared:WaitForChild("BallVariant"))
local BallCatalog = require(Shared:WaitForChild("BallCatalog"))
local FeedPolicy = require(Shared:WaitForChild("FeedPolicy"))
local Economy = require(Shared:WaitForChild("Economy"))
local vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local BallCard = require(Client:WaitForChild("BallCard"))

local create = vide.create
local source = vide.source
local derive = vide.derive
local indexes = vide.indexes
local changed = vide.changed

local CollectionPanel = {}
CollectionPanel.__index = CollectionPanel

local CARD_GAP = 10
local CARD_W, CARD_H = BallCard.WIDTH, BallCard.HEIGHT

-- Rows beyond the viewport kept bound. Two hides the rebind during a fast flick without
-- materially raising the pool size.
local OVERSCAN_ROWS = 2

-- A hard ceiling on pooled cards. Protects against a pathological viewport (an ultrawide at
-- minimum card size) asking for hundreds of slots; beyond this the grid simply scrolls more.
local MAX_POOL = 60

local TABS = { "INDEX", "STORAGE" }
local FILTERS = { "ALL", "OWNED", "UNDISCOVERED", "MUTATED", "HELD", "FAVORITE" }
local SORTS = { "RARITY", "VALUE", "OWNED", "NEWEST", "NAME" }

-- ---------------------------------------------------------------- construction

function CollectionPanel.new(parent: Instance, callbacks)
	local self = setmetatable({}, CollectionPanel)
	callbacks = callbacks or {}
	self.callbacks = callbacks

	-- ---- state ------------------------------------------------------
	local open = source(false)
	local tab = source("STORAGE")
	local rows = source({})
	local revision = source(0)
	local luck = source(1)
	local ballValue = source(1)
	local searchText = source("")
	local filter = source("ALL")
	local sortMode = source("RARITY")
	local sortAscending = source(false)
	local selected = source(nil)
	local scrollY = source(0)
	local viewportHeight = source(400)
	local viewportWidth = source(640)
	local compact = source(false)

	-- The WINDOW, not the screen. Defaults are a plausible desktop so the first layout that
	-- happens before the connection fires is sane rather than degenerate.
	local windowWidth = source(940)
	local windowHeight = source(600)

	-- MULTI-SELECT, off by default. The common action is "look at one ball", and a grid that
	-- toggles a checkbox on every tap makes that harder rather than easier.
	local selectMode = source(false)
	local selection = source({})

	self.open, self.rows, self.revision = open, rows, revision
	self.luck, self.ballValue, self.selected = luck, ballValue, selected
	self.tab, self.filter, self.sortMode = tab, filter, sortMode
	self.searchText, self.sortAscending = searchText, sortAscending
	self.selectMode, self.selection = selectMode, selection
	self.TABS, self.FILTERS, self.SORTS = TABS, FILTERS, SORTS

	-- THE ONE SOURCE OF VERTICAL TRUTH.
	--
	-- Every offset above the grid is computed here, and the grid reads its own top from the
	-- same result -- so the two cannot disagree. Five hardcoded constants is how the Settings
	-- panel put its own close button off the bottom of the screen.
	--
	-- ROW_H is 34 for a 30px chip. A ScrollingFrame's scrollbar comes out of its OWN window,
	-- not out of the space around it: measured in Studio, a 30px row scrolling horizontally
	-- reports a window of 27px, so a 30px chip inside it loses 3px off the bottom. Four pixels
	-- of slack costs nothing and removes the dependency entirely.
	local ROW_H = 34
	local TAB_H = 34
	local SEARCH_H = 34

	-- TWO INDEPENDENT QUESTIONS, not one device class.
	--
	--   STACK  can the tab row also hold the search box? 260 + 240 needs 500px of width.
	--   SHORT  is this a genuinely phone-sized landscape window? On that shape, 38px is the
	--          difference between one visible card row and none. A short DESKTOP window keeps
	--          both rows: it has the width and enough card space, and hiding SELECT at the end
	--          of a half-width scroller is a worse trade.
	--
	-- They are independent: a landscape phone is short but not narrow, a portrait phone is
	-- narrow but not short, and a desktop is neither.
	local metrics = derive(function()
		local w, h = windowWidth(), windowHeight()
		local stack = compact() or w < 560
		local short = h < 480 and w < 760

		local m = {}
		m.header = short and 44 or 48
		m.tabW = stack and 96 or 120
		m.tabsW = stack and 200 or 260
		m.searchW = stack and 0 or 240
		m.searchY = stack and (TAB_H + 6) or 0

		local chipsY = stack and (TAB_H + 6 + SEARCH_H + 6) or (TAB_H + 6)
		m.side = short
		m.filtersY = chipsY
		-- SIDE BY SIDE when short: the same two ScrollingFrames share one line, each still
		-- scrolling its own contents. Nothing is reparented, so no instance is created or
		-- destroyed by a resize.
		m.sortsY = short and chipsY or (chipsY + ROW_H + 4)
		m.gridY = (short and (chipsY + ROW_H) or (chipsY + ROW_H * 2 + 4)) + 6
		return m
	end)

	local gridTop = derive(function() return metrics().gridY end)
	local function metric(name)
		return function() return metrics()[name] end
	end

	-- SCROLL_BAR_W comes off the usable width because AbsoluteSize includes the scrollbar but
	-- the cards cannot use it. Ignoring it only bites at a column boundary, which is exactly
	-- where a wrong answer costs a whole column.
	local SCROLL_BAR_W = 6

	local columns = derive(function()
		local usable = viewportWidth() - SCROLL_BAR_W - CARD_GAP
		return math.max(1, math.floor(usable / (CARD_W + CARD_GAP)))
	end)

	-- ---- the visible list (pure read) -------------------------------
	local visible = derive(function()
		local currentRows = rows()
		local mode, needle = filter(), string.lower(searchText())
		local showUndiscovered = tab() == "INDEX"

		local list = {}
		for _, key in ipairs(BallVariant.all()) do
			local info = BallVariant.info(key)
			local row = currentRows[key]
			local isDiscovered = row ~= nil

			local keep = true
			if not showUndiscovered and not isDiscovered then
				keep = false
			elseif mode == "OWNED" then
				keep = isDiscovered and row.count > 0
			elseif mode == "UNDISCOVERED" then
				keep = not isDiscovered
			elseif mode == "MUTATED" then
				keep = info.mutated
			elseif mode == "HELD" then
				keep = isDiscovered and row.hold
			elseif mode == "FAVORITE" then
				keep = isDiscovered and row.favorite
			end

			if keep and needle ~= "" then
				keep = string.find(string.lower(info.displayName), needle, 1, true) ~= nil
					or string.find(string.lower(info.category), needle, 1, true) ~= nil
			end

			if keep then
				table.insert(list, key)
			end
		end

		local order, ascending = sortMode(), sortAscending()
		table.sort(list, function(a, b)
			local ia, ib = BallVariant.info(a), BallVariant.info(b)
			local ra, rb = currentRows[a], currentRows[b]
			local av, bv
			if order == "RARITY" then
				av, bv = ia.sortRarity, ib.sortRarity
			elseif order == "VALUE" then
				av, bv = BallVariant.prospectiveValue(a, 1), BallVariant.prospectiveValue(b, 1)
			elseif order == "OWNED" then
				av, bv = ra and ra.count or -1, rb and rb.count or -1
			elseif order == "NEWEST" then
				av, bv = ra and ra.firstSeen or -1, rb and rb.firstSeen or -1
			else
				av, bv = ia.displayName, ib.displayName
			end
			if av == bv then
				return a < b   -- stable, deterministic tail-break
			end
			return ascending and av < bv or (not ascending and av > bv)
		end)
		return list
	end)
	self.visible = visible

	-- ---- virtualisation ---------------------------------------------
	local poolSize = derive(function()
		local onScreen = math.ceil(viewportHeight() / (CARD_H + CARD_GAP)) + OVERSCAN_ROWS
		return math.clamp(onScreen * columns(), 1, MAX_POOL)
	end)

	local firstIndex = derive(function()
		local rowIndex = math.floor(scrollY() / (CARD_H + CARD_GAP))
		return math.max(0, rowIndex * columns())
	end)

	local canvasHeight = derive(function()
		local rowCount = math.ceil(#visible() / math.max(1, columns()))
		return rowCount * (CARD_H + CARD_GAP) + CARD_GAP
	end)

	-- THE POOL, as a map of slot index -> variant key.
	--
	-- Empty slots hold `false` rather than nil, so the KEY SET is always exactly poolSize.
	-- That matters more than it looks: `indexes` keys its scopes by table key, so a stable key
	-- set means scrolling only changes VALUES and every card is reused. If trailing slots
	-- vanished to nil near the end of the list, cards would be destroyed and rebuilt mid-flick
	-- -- allocation during a scroll, which is the one thing this design exists to prevent.
	local slotMap = derive(function()
		local list, start, count = visible(), firstIndex(), poolSize()
		local map = {}
		for slot = 1, count do
			map[slot] = list[start + slot] or false
		end
		return map
	end)

	-- ---- selection helpers ------------------------------------------
	local selectedRow = derive(function()
		local key = selected()
		return key and rows()[key] or nil
	end)
	local selectedInfo = derive(function()
		local key = selected()
		return key and BallVariant.info(key) or nil
	end)

	-- TRUTHFUL IDLE. Owning balls the hopper is not allowed to touch is a state the player
	-- chose; it is explained rather than left looking broken.
	local nothingEligible = derive(function()
		local currentRows = rows()
		local owned, eligible = 0, 0
		for _, row in pairs(currentRows) do
			if row.count > 0 then
				owned += 1
				local policy = {
					autoFeed = row.autoFeed, hold = row.hold,
					favorite = row.favorite, keepAtLeast = row.keepAtLeast,
				}
				if FeedPolicy.isAutoEligible(row.count, policy) then
					eligible += 1
				end
			end
		end
		return owned > 0 and eligible == 0
	end)
	self.nothingEligible = nothingEligible

	local function patch(field, value)
		local key = selected()
		if key and callbacks.onSetPolicy then
			callbacks.onSetPolicy(key, { [field] = value })
		end
	end

	-- ---- multi-selection --------------------------------------------
	--
	-- The set is REPLACED rather than mutated on every change. Vide compares by identity, so
	-- mutating the existing table in place would leave every reader showing a stale mark.
	local function countOf(set): number
		local n = 0
		for _ in pairs(set) do
			n += 1
		end
		return n
	end

	local selectionCount = derive(function() return countOf(selection()) end)
	self.selectionCount = selectionCount
	local discoveredCount = derive(function() return countOf(rows()) end)
	local totalVariantCount = #BallVariant.all()

	local function toggleMark(key: string)
		local current = selection()
		local updated = {}
		for k in pairs(current) do
			updated[k] = true
		end
		if updated[key] then
			updated[key] = nil
		elseif countOf(current) < Economy.MAX_POLICY_BATCH then
			updated[key] = true
		else
			return   -- at the cap; refusing the mark beats showing one that will not be sent
		end
		selection(updated)
	end

	-- VISIBLE AND OWNED, not merely visible. Marking an undiscovered variant would let a bulk
	-- action look like it did something to balls that do not exist, and the server would
	-- refuse every one of them anyway.
	local function selectAllVisible()
		local currentRows = rows()
		local updated, n = {}, 0
		for _, key in ipairs(visible()) do
			if n >= Economy.MAX_POLICY_BATCH then
				break
			end
			local row = currentRows[key]
			if row and row.count > 0 then
				updated[key] = true
				n += 1
			end
		end
		selection(updated)
	end

	local function bulkPatch(field, value)
		local keys = {}
		for key in pairs(selection()) do
			table.insert(keys, key)
		end
		if #keys == 0 then
			return
		end
		-- Sorted, so the same visible selection always produces the same packet. Costs nothing
		-- at this size and makes the wire reproducible when reading a log.
		table.sort(keys)
		if callbacks.onSetPolicyMany then
			callbacks.onSetPolicyMany(keys, { [field] = value })
		end
	end

	local function setSelectMode(value: boolean)
		selectMode(value)
		if value then
			-- Focus and multi-selection answer different questions; showing both at once would
			-- put two "chosen" states on screen meaning two different things.
			selected(nil)
		else
			selection({})
		end
	end

	self.setSelectModeForTest = setSelectMode
	self.toggleMarkForTest = toggleMark
	self.selectAllVisibleForTest = selectAllVisible

	-- ---- tree -------------------------------------------------------

	local function tabButton(name)
		return UIKit.button {
			name = name,
			size = function() return UDim2.fromOffset(metrics().tabW, TAB_H) end,
			radius = UITheme.CORNER.normal,
			accent = function()
				return tab() == name and UITheme.COLOR.green or UITheme.COLOR.slate
			end,
			order = name == "INDEX" and 1 or 2,
			onClick = function() tab(name) end,
			children = {
				UIKit.text { text = name, size = UITheme.TEXT_SIZE.body,
					align = Enum.TextXAlignment.Center },
			},
		}
	end

	-- A row that is allowed to be wider than the panel. See the header: a ScrollingFrame hides
	-- its bar when the canvas fits, so this costs the desktop layout nothing.
	--
	-- `side` is which half it takes when the layout puts two rows on one line. Full width
	-- otherwise, which is every case except a short window.
	local function scrollRow(name, yKey, side, children)
		return create("ScrollingFrame") {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = function()
				local m = metrics()
				if m.side and side == "right" then
					return UDim2.new(0.5, 3, 0, m[yKey])
				end
				return UDim2.fromOffset(0, m[yKey])
			end,
			Size = function()
				if metrics().side then
					return UDim2.new(0.5, -3, 0, ROW_H)
				end
				return UDim2.new(1, 0, 0, ROW_H)
			end,
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			CanvasSize = UDim2.new(),
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = UITheme.COLOR.slate,
			ZIndex = 22,
			create("UIListLayout") {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 6),
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(children),
		}
	end

	-- Filter and sort chips share a shape, so they share a builder.
	local function chip(label, isActive, onClick, width)
		-- `label` may be a source (the ASC/DESC toggle relabels itself), but Name must be a
		-- string. Reactive text is fine; a reactive instance name is not.
		return UIKit.button {
			name = type(label) == "string" and label or "Chip",
			size = UDim2.fromOffset(width or 92, 30),
			radius = UITheme.CORNER.small,
			stroke = UITheme.STROKE.normal,
			accent = function()
				return isActive() and UITheme.COLOR.gold or UITheme.COLOR.panelDeep
			end,
			onClick = onClick,
			children = {
				UIKit.text {
					text = label,
					size = UITheme.TEXT_SIZE.tiny,
					align = Enum.TextXAlignment.Center,
					colour = function()
						return isActive() and UITheme.COLOR.textOutline or UITheme.COLOR.textDim
					end,
				},
			},
		}
	end

	local filterChips = {}
	for index, mode in ipairs(FILTERS) do
		local c = chip(mode, function() return filter() == mode end, function() filter(mode) end)
		c.LayoutOrder = index
		table.insert(filterChips, c)
	end

	local sortChips = {}
	for index, mode in ipairs(SORTS) do
		local c = chip(mode, function() return sortMode() == mode end, function() sortMode(mode) end, 84)
		c.LayoutOrder = index
		table.insert(sortChips, c)
	end
	local directionChip = chip(
		function() return sortAscending() and "ASC" or "DESC" end,
		function() return true end,
		function() sortAscending(not sortAscending()) end, 64)
	directionChip.LayoutOrder = #SORTS + 1
	table.insert(sortChips, directionChip)

	-- Lives at the end of the sort row because that is where there is room, but it is an
	-- ACTION rather than a sort, so it carries a gold accent the sort chips do not.
	local selectChip = UIKit.button {
		name = "SelectMode",
		size = UDim2.fromOffset(104, 30),
		radius = UITheme.CORNER.small,
		stroke = UITheme.STROKE.normal,
		accent = function()
			return selectMode() and UITheme.COLOR.gold or UITheme.COLOR.panelDeep
		end,
		onClick = function() setSelectMode(not selectMode()) end,
		children = {
			UIKit.text {
				text = function() return selectMode() and "SELECTING" or "SELECT" end,
				size = UITheme.TEXT_SIZE.tiny,
				align = Enum.TextXAlignment.Center,
				colour = function()
					return selectMode() and UITheme.COLOR.textOutline or UITheme.COLOR.textDim
				end,
			},
		},
	}
	selectChip.LayoutOrder = #SORTS + 2
	table.insert(sortChips, selectChip)

	-- `indexes` creates one card per slot and REUSES it while that slot exists. So:
	--   scrolling      -> values change, every card is reused, nothing is allocated
	--   resizing       -> the key set changes, cards are created or destroyed
	-- Allocation therefore happens only on a window resize, which is rare, and never on the
	-- frequent path. Vide owns the scopes, so a destroyed card's effects are cleaned up too.
	local cards = indexes(slotMap, function(slotValue, slot)
		return BallCard.new {
			key = function()
				local value = slotValue()
				return value ~= false and value or nil
			end,
			rows = rows,
			selected = selected,
			selection = selection,
			onSelect = function(k)
				if selectMode() then
					toggleMark(k)
				else
					selected(k)
				end
			end,
			position = derive(function()
				local index = firstIndex() + slot
				local cols = columns()
				local row = math.floor((index - 1) / cols)
				local col = (index - 1) % cols
				return UDim2.fromOffset(
					CARD_GAP + col * (CARD_W + CARD_GAP),
					CARD_GAP + row * (CARD_H + CARD_GAP))
			end),
		}
	end)

	local grid = create("ScrollingFrame") {
		Name = "Grid",
		-- A recessed well rather than a void. Without it the cards float on the window and the
		-- whole panel reads as one flat sheet.
		BackgroundColor3 = UITheme.COLOR.panelDeep,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		-- THE GRID GROWS WHEN NO STRIP IS UP. Detail and bulk are both 52px and mutually
		-- exclusive; reserving their space permanently wasted most of a row on a short window
		-- for a panel that is usually showing neither.
		--
		-- ON A SHORT WINDOW THE STRIP OVERLAYS INSTEAD OF PUSHING. A landscape phone has 192px
		-- of grid; giving 56 of it to the detail strip leaves 136, and a card is 156 -- so
		-- selecting a ball would empty the grid completely. Covering the bottom of a row you
		-- are already looking at is a far smaller cost than showing nothing at all.
		Size = function()
			local strip = selectMode() or selected() ~= nil
			local push = strip and not metrics().side
			local reserved = gridTop() + (push and 72 or 8)
			return UDim2.new(1, 0, 1, -reserved)
		end,
		Position = function() return UDim2.fromOffset(0, gridTop()) end,
		CanvasSize = function() return UDim2.fromOffset(0, canvasHeight()) end,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = UITheme.COLOR.slate,
		ZIndex = 2,

		-- THE ONLY TWO CONNECTIONS IN THE PANEL.
		changed("CanvasPosition", function(position) scrollY(position.Y) end),
		changed("AbsoluteSize", function(size)
			viewportHeight(size.Y)
			viewportWidth(size.X)
		end),

		cards,
	}

	-- ---- detail strip -----------------------------------------------
	-- `order` is not optional. Without it all three controls default to LayoutOrder 0 and the
	-- list sorts them alphabetically AHEAD of the name and value they describe -- which is
	-- what this strip was actually doing.
	local function control(label, field, width, order)
		return create("Frame") {
			Name = label,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Size = UDim2.fromOffset(width or 108, 34),
			create("UIListLayout") {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 6),
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			UIKit.checkbox {
				value = function()
					local r = selectedRow()
					return r ~= nil and r[field] == true
				end,
				accent = function()
					local r = selectedRow()
					return (r and r[field]) and UITheme.COLOR.green or UITheme.COLOR.slate
				end,
				onChanged = function(value) patch(field, value) end,
				order = 1,
			},
			UIKit.text {
				text = label,
				size = UITheme.TEXT_SIZE.tiny,
				colour = UITheme.COLOR.textDim,
				size2 = UDim2.fromOffset((width or 108) - 34, 30),
				order = 2,
			},
		}
	end

	local keepChips = {}
	for index, preset in ipairs(FeedPolicy.KEEP_PRESETS) do
		local c = chip(FeedPolicy.keepLabel(preset), function()
			local r = selectedRow()
			return r ~= nil and r.keepAtLeast == preset
		end, function() patch("keepAtLeast", preset) end, 52)
		c.LayoutOrder = index
		table.insert(keepChips, c)
	end

	local detail = create("Frame") {
		Name = "Detail",
		BackgroundColor3 = UITheme.COLOR.panelDeep,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 52),
		-- Floats above the body edge instead of merging into the screen boundary. Besides
		-- looking like an action dock, this gives Studio chrome and phone gesture areas room.
		Position = UDim2.new(0, 0, 1, -60),
		Visible = function() return selected() ~= nil and not selectMode() end,
		ZIndex = 3,

		UIKit.corner(UITheme.CORNER.normal),
		UIKit.bevel(UITheme.STROKE.normal),

		create("ScrollingFrame") {
			Name = "Bar",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -20, 1, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			CanvasSize = UDim2.new(),
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = UITheme.COLOR.slate,
			ZIndex = 4,

			create("UIListLayout") {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 8),
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			-- what is selected, and what it would be worth right now
			create("Frame") {
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(190, 44),
				LayoutOrder = 1,
				UIKit.text {
					text = function()
						local i = selectedInfo()
						return i and i.displayName or ""
					end,
					size = UITheme.TEXT_SIZE.small,
					size2 = UDim2.new(1, 0, 0, 20),
				},
				UIKit.text {
					text = function()
						local key, i = selected(), selectedInfo()
						if not key or not i then return "" end
						local value = BallVariant.prospectiveValue(key, ballValue())
						local live = i.oneIn and BallCatalog.chanceOf(i.ballId, luck()) or nil
						local odds = live and live > 0
							and ("~1 in " .. Economy.formatOneIn(1 / live))
							or "remainder"
						return ("drops for x%.2f  -  %s at your Luck"):format(value, odds)
					end,
					colour = UITheme.COLOR.textDim,
					size = UITheme.TEXT_SIZE.tiny,
					position = UDim2.fromOffset(0, 20),
					size2 = UDim2.new(1, 0, 0, 16),
				},
			},

			control("AUTO FEED", "autoFeed", 118, 2),
			control("HOLD", "hold", 88, 3),
			control("FAV", "favorite", 76, 4),

			create("Frame") {
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(300, 34),
				LayoutOrder = 5,
				create("UIListLayout") {
					FillDirection = Enum.FillDirection.Horizontal,
					Padding = UDim.new(0, 4),
					VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				UIKit.text {
					text = "KEEP", size = UITheme.TEXT_SIZE.tiny,
					colour = UITheme.COLOR.textDim,
					size2 = UDim2.fromOffset(40, 30), order = 0,
				},
				table.unpack(keepChips),
			},

			UIKit.button {
				name = "DropNext",
				size = UDim2.fromOffset(120, 34),
				radius = UITheme.CORNER.small,
				accent = UITheme.COLOR.gold,
				motion = "primary",
				order = 6,
				onClick = function()
					local key = selected()
					if key and callbacks.onDropNext then
						callbacks.onDropNext(key)
					end
				end,
				children = {
					UIKit.text { text = "DROP NEXT", size = UITheme.TEXT_SIZE.tiny,
						align = Enum.TextXAlignment.Center, colour = UITheme.COLOR.textOutline },
				},
			},
		},
	}

	-- ---- bulk bar ----------------------------------------------------
	--
	-- Sits exactly where the detail strip sits and is never up at the same time.
	--
	-- ITS CONTENTS SCROLL. Ten controls do not fit across a phone, and a bar whose last button
	-- is off the edge is the same bug the Settings panel had. A ScrollingFrame hides its own
	-- bar when the canvas fits, so the desktop layout pays nothing for this.
	local function bulkButton(label, colour, width, order, onClick)
		return UIKit.button {
			name = (label:gsub("%W", "")),
			size = UDim2.fromOffset(width, 34),
			radius = UITheme.CORNER.small,
			accent = colour,
			motion = "subtle",
			order = order,
			onClick = onClick,
			children = {
				UIKit.text {
					text = label,
					size = UITheme.TEXT_SIZE.tiny,
					align = Enum.TextXAlignment.Center,
					colour = colour == UITheme.COLOR.gold
						and UITheme.COLOR.textOutline or UITheme.COLOR.text,
				},
			},
		}
	end

	local bulk = create("Frame") {
		Name = "Bulk",
		BackgroundColor3 = UITheme.COLOR.panelDeep,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 52),
		Position = UDim2.new(0, 0, 1, -60),
		Visible = selectMode,
		ZIndex = 3,

		UIKit.corner(UITheme.CORNER.normal),
		UIKit.bevel(UITheme.STROKE.normal),

		create("ScrollingFrame") {
			Name = "Bar",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -20, 1, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			CanvasSize = UDim2.new(),
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = UITheme.COLOR.slate,
			ZIndex = 4,

			create("UIListLayout") {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 6),
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			-- Says what it will actually do, including when it is refusing to mark more.
			UIKit.text {
				text = function()
					local n = selectionCount()
					if n == 0 then
						return "TAP CARDS TO MARK"
					end
					if n >= Economy.MAX_POLICY_BATCH then
						return ("%d SELECTED (MAX)"):format(n)
					end
					return ("%d SELECTED"):format(n)
				end,
				colour = function()
					return selectionCount() > 0 and UITheme.COLOR.gold or UITheme.COLOR.textDim
				end,
				size = UITheme.TEXT_SIZE.tiny,
				size2 = UDim2.fromOffset(150, 30),
				order = 0,
			},

			bulkButton("ALL", UITheme.COLOR.slate, 62, 1, selectAllVisible),
			bulkButton("NONE", UITheme.COLOR.slate, 68, 2, function() selection({}) end),
			bulkButton("FEED ON", UITheme.COLOR.green, 94, 3, function() bulkPatch("autoFeed", true) end),
			bulkButton("FEED OFF", UITheme.COLOR.slate, 98, 4, function() bulkPatch("autoFeed", false) end),
			bulkButton("HOLD", UITheme.COLOR.red, 74, 5, function() bulkPatch("hold", true) end),
			bulkButton("UNHOLD", UITheme.COLOR.slate, 86, 6, function() bulkPatch("hold", false) end),
			bulkButton("FAV", UITheme.COLOR.purple, 62, 7, function() bulkPatch("favorite", true) end),
			bulkButton("UNFAV", UITheme.COLOR.slate, 78, 8, function() bulkPatch("favorite", false) end),
			bulkButton("DONE", UITheme.COLOR.gold, 76, 9, function() setSelectMode(false) end),
		},
	}

	-- ---- root -------------------------------------------------------
	local root = create("Frame") {
		Name = "CollectionPanel",
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
			-- RESPONSIVE WITH A CAP, not a fixed size. A fixed 760x640 was taller than a
			-- 1192x576 viewport, and because the window is centre-anchored it hung 90px off
			-- the TOP of the screen -- the header and tabs were simply not reachable.
			--
			-- A phone gets tighter margins: 32px of scrim either side of a 390px screen is 8%
			-- of the width spent on nothing.
			Size = function()
				return compact() and UDim2.new(1, -16, 1, -20) or UDim2.new(1, -32, 1, -48)
			end,

			-- THE THIRD CONNECTION. Everything above the grid is derived from this.
			changed("AbsoluteSize", function(size)
				windowWidth(size.X)
				windowHeight(size.Y)
			end),
			ZIndex = 21,

			-- The cap keeps it from becoming a vast empty rectangle on a big monitor while the
			-- Size above keeps it inside a small one. Neither alone is enough.
			-- Wide enough for five columns on a desktop, capped so it never becomes a vast
			-- empty rectangle on an ultrawide.
			create("UISizeConstraint") {
				MaxSize = Vector2.new(980, 680),
				MinSize = Vector2.new(320, 300),
			},

			UIKit.corner(UITheme.CORNER.large),
			UIKit.bevel(UITheme.STROKE.thick),

			-- header
			create("Frame") {
				Name = "Header",
				BackgroundColor3 = UITheme.COLOR.green,
				BorderSizePixel = 0,
				Size = function() return UDim2.new(1, 0, 0, metric("header")()) end,
				ZIndex = 22,
				UIKit.corner(UITheme.CORNER.large),
				UIKit.stripes(0.9),
				UIKit.text {
					text = "COLLECTION",
					size = UITheme.TEXT_SIZE.large,
					position = UDim2.fromOffset(16, 0),
					size2 = UDim2.new(0, 240, 1, 0),
					zindex = 23,
				},
				-- A compact index-style completion readout: useful collection information in the
				-- header instead of another permanent row above the card grid.
				create("Frame") {
					Name = "DiscoveryBadge",
					BackgroundColor3 = UITheme.COLOR.greenDeep,
					BackgroundTransparency = 0.18,
					BorderSizePixel = 0,
					AnchorPoint = Vector2.new(1, 0.5),
					Position = function()
						return UDim2.new(1, -64, 0, metric("header")() / 2)
					end,
					Size = UDim2.fromOffset(190, 30),
					Visible = function() return windowWidth() >= 600 end,
					ZIndex = 23,
					UIKit.corner(UITheme.CORNER.pill),
					UIKit.text {
						text = function()
							return ("DISCOVERED  %d / %d"):format(
								discoveredCount(), totalVariantCount)
						end,
						size = UITheme.TEXT_SIZE.tiny,
						align = Enum.TextXAlignment.Center,
						zindex = 24,
					},
				},
				UIKit.button {
					name = "Close",
					size = UDim2.fromOffset(44, 40),
					position = function()
						return UDim2.new(1, -52, 0, (metric("header")() - 40) / 2)
					end,
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

			-- body
			create("Frame") {
				Name = "Body",
				BackgroundTransparency = 1,
				Position = function() return UDim2.fromOffset(0, metric("header")()) end,
				Size = function() return UDim2.new(1, 0, 1, -metric("header")()) end,
				ZIndex = 22,
				create("UIPadding") {
					PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
					PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10),
				},

				-- tabs
				create("Frame") {
					Name = "Tabs",
					BackgroundTransparency = 1,
					Size = function() return UDim2.new(0, metrics().tabsW, 0, TAB_H) end,
					ZIndex = 22,
					create("UIListLayout") {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, 8),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					tabButton("INDEX"),
					tabButton("STORAGE"),
				},

				-- search
				create("TextBox") {
					Name = "Search",
					BackgroundColor3 = UITheme.COLOR.panelDeep,
					BorderSizePixel = 0,
					-- Beside the tabs when they both fit, on its own row when they do not.
					-- `searchW` of 0 means "take the full row", the only sane narrow answer.
					Position = function()
						local m = metrics()
						if m.searchW == 0 then
							return UDim2.fromOffset(0, m.searchY)
						end
						return UDim2.new(1, -m.searchW, 0, m.searchY)
					end,
					Size = function()
						local m = metrics()
						if m.searchW == 0 then
							return UDim2.new(1, 0, 0, SEARCH_H)
						end
						return UDim2.fromOffset(m.searchW, SEARCH_H)
					end,
					Font = UITheme.FONT.body,
					PlaceholderText = "Search...",
					PlaceholderColor3 = UITheme.COLOR.textDim,
					Text = "",
					TextColor3 = UITheme.COLOR.text,
					TextSize = UITheme.TEXT_SIZE.small,
					ClearTextOnFocus = false,
					ZIndex = 22,
					UIKit.corner(UITheme.CORNER.small),
					UIKit.bevel(UITheme.STROKE.normal),
					create("UIPadding") { PaddingLeft = UDim.new(0, 10) },
					changed("Text", function(value) searchText(value or "") end),
				},

				scrollRow("Filters", "filtersY", "left", filterChips),
				scrollRow("Sorts", "sortsY", "right", sortChips),

				grid,

				-- honest empty / idle states
				UIKit.text {
					text = function()
						if #visible() > 0 then return "" end
						if tab() == "STORAGE" then
							return "Nothing here yet - roll some balls."
						end
						return "No balls match that filter."
					end,
					colour = UITheme.COLOR.textDim,
					size = UITheme.TEXT_SIZE.body,
					align = Enum.TextXAlignment.Center,
					position = UDim2.fromOffset(0, 240),
					size2 = UDim2.new(1, 0, 0, 30),
					zindex = 23,
				},
				UIKit.text {
					text = "No eligible balls - Auto Roll is still adding to Storage.",
					colour = UITheme.COLOR.gold,
					size = UITheme.TEXT_SIZE.small,
					align = Enum.TextXAlignment.Center,
					position = UDim2.new(0, 0, 1, -76),
					size2 = UDim2.new(1, 0, 0, 20),
					visible = nothingEligible,
					zindex = 23,
				},

				detail,
				bulk,
			},
		},
	}

	self.root = root
	self.grid = grid

	-- ---- test seams --------------------------------------------------
	self.slotMapForTest = slotMap
	self.poolSizeForTest = poolSize
	self.firstIndexForTest = firstIndex
	self.canvasHeightForTest = canvasHeight
	self.columnsForTest = columns
	self.setViewportForTest = function(height, width)
		viewportHeight(height)
		viewportWidth(width)
	end
	self.setScrollForTest = function(y) scrollY(y) end
	self.setRowsForTest = function(value) rows(value) end
	self.setFilterForTest = function(value) filter(value) end
	self.setSearchForTest = function(value) searchText(value) end
	self.setSortForTest = function(mode, ascending)
		sortMode(mode)
		sortAscending(ascending and true or false)
	end
	self.setTabForTest = function(value) tab(value) end
	self.bulkPatchForTest = bulkPatch
	self.gridTopForTest = gridTop
	self.metricForTest = metric
	self.metricsForTest = metrics
	self.setWindowForTest = function(width, height)
		windowWidth(width)
		windowHeight(height)
	end
	self.setCompactForTest = function(value) compact(value and true or false) end

	-- ---- sync -------------------------------------------------------
	function self.applySync(payload)
		if type(payload) ~= "table" then
			return "ignored"
		end
		if payload.full then
			rows(payload.variants or {})
			revision(payload.revision or 0)
			return "full"
		end
		if payload.from ~= revision() then
			if callbacks.onResyncNeeded then
				callbacks.onResyncNeeded()
			end
			return "resync"
		end
		local merged = {}
		for key, row in pairs(rows()) do
			merged[key] = row
		end
		for key, row in pairs(payload.changed or {}) do
			merged[key] = row
		end
		rows(merged)
		revision(payload.revision or revision())
		return "delta"
	end

	return self
end

function CollectionPanel:isOpen(): boolean
	return self.open()
end

function CollectionPanel:setOpen(value: boolean)
	self.open(value and true or false)
	if value and self.callbacks.onOpened then
		-- Opening asks for the whole truth; everything after it is a delta.
		self.callbacks.onOpened()
	end
	if self.callbacks.onOpenChanged then
		self.callbacks.onOpenChanged(self.open())
	end
end

function CollectionPanel:select(key: string?)
	self.selected(key)
end

function CollectionPanel:setState(state)
	if state.luck then
		self.luck(state.luck)
	end
	if state.ballValue then
		self.ballValue(state.ballValue)
	end
end

function CollectionPanel:setCompact(value: boolean)
	self.setCompactForTest(value)
end

return CollectionPanel
