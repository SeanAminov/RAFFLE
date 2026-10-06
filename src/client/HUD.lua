--!strict
-- Screen layout: the left roll panel, the right navigation column, and the toast rail.
--
-- Respects the live GuiService inset so nothing hides under the Roblox topbar, and
-- re-lays-out whenever the viewport changes rather than being tuned for one resolution.
--
-- NARROW VIEWPORTS: the left panel collapses to a compact top-left card, Roll and Auto
-- Roll move to a bottom bar within thumb reach, and Upgrades stays top-right. The centre
-- of the screen is never covered -- the machine is the spectacle.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
-- Hoisted: this used to be required INSIDE the per-rank loop in setState, which re-resolved
-- the module on every snapshot for every upgrade.
local UpgradeConfig = require(Shared:WaitForChild("UpgradeConfig"))
local NavRegistry = require(Shared:WaitForChild("NavRegistry"))
local vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local RollPanel = require(Client:WaitForChild("RollPanel"))
local NavButton = require(Client:WaitForChild("NavButton"))
local UpgradeBoard = require(Client:WaitForChild("UpgradeBoard"))
local SettingsPanel = require(Client:WaitForChild("SettingsPanel"))
local CollectionPanel = require(Client:WaitForChild("CollectionPanel"))
local LockedPanel = require(Client:WaitForChild("LockedPanel"))
local AchievementsPanel = require(Client:WaitForChild("AchievementsPanel"))
local RebirthPanel = require(Client:WaitForChild("RebirthPanel"))

local HUD = {}

local COMPACT_WIDTH = 820

-- Below this, a reported viewport is a startup artefact rather than a real screen.
local MIN_BELIEVABLE_VIEWPORT = 64

-- The last viewport worth believing, used while the real one is still degenerate. Seeded
-- with a common desktop size so the very first layout is sane.
local lastGoodViewport = Vector2.new(1280, 720)

local gui, rollPanel, navHolder, board, toastHolder, bottomBar
local settingsPanel, collectionPanel, lockedPanel, achievementsPanel, rebirthPanel
local navButtons: { [string]: any } = {}
local compact = false

-- ONE PANEL AT A TIME. Every screen registers a closer here, so opening one closes the rest
-- without any panel needing to know the others exist. Adding a screen adds a row, not a
-- branch in some `if` chain.
local closers: { [string]: () -> () } = {}

local function showOnly(id: string?)
	for other, close in pairs(closers) do
		if other ~= id then
			close()
		end
	end
	for other, button in pairs(navButtons) do
		button:setSelected(other == id)
	end
end

local function buildToast(kind: string, text: string)
	local colour = UITheme.COLOR.slate
	if kind == "starter" then
		colour = UITheme.COLOR.gold
	elseif kind == "purchase" then
		colour = UITheme.COLOR.green
	elseif kind == "rebirth" then
		colour = UITheme.COLOR.pink
	elseif kind == "reject" then
		colour = UITheme.COLOR.red
	end

	local toast = Instance.new("Frame")
	toast.BackgroundColor3 = colour
	toast.BorderSizePixel = 0
	toast.Size = UDim2.new(1, 0, 0, 34)
	toast.Parent = toastHolder
	UITheme.corner(toast, UITheme.CORNER.normal)
	UITheme.stroke(toast, UITheme.STROKE.normal)

	local label = UITheme.label(toast, text, UITheme.TEXT_SIZE.small)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center

	task.delay(2.2, function()
		if toast.Parent then
			TweenService:Create(toast, UITheme.EASE_OUT, {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
			}):Play()
			TweenService:Create(label, UITheme.EASE_OUT, {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			}):Play()
			task.delay(UITheme.TIME.panel + 0.05, function()
				toast:Destroy()
			end)
		end
	end)
end

local function relayout()
	if not gui then
		return
	end
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local inset = GuiService:GetGuiInset()
	local top = inset.Y + 12

	-- A DEGENERATE viewport is not a narrow one. Roblox reports 1x1 while the render window
	-- is still being sized, and taking that at face value latched the whole HUD into compact
	-- mode -- bottom bar, shrunken board -- and left it there, because the next real
	-- ViewportSize change never came.
	--
	-- SUBSTITUTE rather than bail: an early return here would skip the FIRST layout too, and
	-- with no later ViewportSize change the HUD would stay unsized at 0x0 forever. Fall back
	-- to the last believable size instead, so a layout always happens and the compact
	-- decision is only ever made from a real measurement.
	if viewport.X < MIN_BELIEVABLE_VIEWPORT or viewport.Y < MIN_BELIEVABLE_VIEWPORT then
		viewport = lastGoodViewport
	else
		lastGoodViewport = viewport
	end

	compact = viewport.X < COMPACT_WIDTH

	rollPanel:setCompact(compact)
	board:setCompact(compact)

	if compact then
		-- compact card top-left, controls on a bottom bar
		rollPanel.root.Position = UDim2.fromOffset(10, top)
		rollPanel.root.Size = UDim2.fromOffset(math.min(232, viewport.X * 0.5), 0)
		rollPanel.root.AutomaticSize = Enum.AutomaticSize.Y

		bottomBar.Visible = true
		rollPanel.rollButton.Parent = bottomBar
		rollPanel.autoButton.Parent = bottomBar
		-- Explicit half-widths: inside the panel these are full-width rows, but on the
		-- bottom bar they sit side by side and would otherwise each claim the whole bar.
		rollPanel.rollButton.Size = UDim2.new(0.5, -6, 0, 52)
		rollPanel.autoButton.Size = UDim2.new(0.5, -6, 0, 52)
		rollPanel.rollButton.LayoutOrder = 1
		rollPanel.autoButton.LayoutOrder = 2

		navHolder.Position = UDim2.new(1, -10, 0, top)
		navHolder.Size = UDim2.fromOffset(150, 0)
		for id, button in pairs(navButtons) do
			local item = NavRegistry.get(id)
			button:setHeight(UITheme.TOUCH_MIN + (item and item.compactHeight and 2 or 6))
		end
	else
		rollPanel.root.Position = UDim2.fromOffset(16, top)
		rollPanel.root.Size = UDim2.fromOffset(268, 0)
		rollPanel.root.AutomaticSize = Enum.AutomaticSize.Y

		bottomBar.Visible = false
		rollPanel.rollButton.Parent = rollPanel.root
		rollPanel.autoButton.Parent = rollPanel.root
		rollPanel.rollButton.Size = UDim2.new(1, 0, 0, 56)
		rollPanel.autoButton.Size = UDim2.new(1, 0, 0, UITheme.TOUCH_MIN)
		-- Restore the in-panel order. The compact branch renumbers these to 1 and 2 for the
		-- bottom bar; without putting them back, a viewport that starts narrow and widens
		-- leaves Roll pinned to the top of the panel.
		rollPanel.rollButton.LayoutOrder = 8
		rollPanel.autoButton.LayoutOrder = 9

		navHolder.Position = UDim2.new(1, -16, 0, top)
		navHolder.Size = UDim2.fromOffset(228, 0)
		for id, button in pairs(navButtons) do
			local item = NavRegistry.get(id)
			button:setHeight(item and item.compactHeight and 56 or 62)
		end
	end

	-- The Settings panel hangs BELOW the navigation column on the right, so it never crosses
	-- the centre of the screen and never covers the machine.
	-- BESIDE THE NAV COLUMN, at the same top edge -- not under it. The column is as tall as
	-- the registry is long, so "below the nav" stopped being a real position the moment a
	-- third tile existed.
	local navWidth = compact and 150 or 228
	local navMargin = compact and 10 or 16
	settingsPanel:position(
		UDim2.new(1, -(navMargin + navWidth + 10), 0, top),
		compact,
		viewport.Y - top - 16)
	collectionPanel:setCompact(compact)
	achievementsPanel:setCompact(compact)
	rebirthPanel:setCompact(compact)

	-- FULL-SCREEN SCRIMS COVER THE VISIBLE SCREEN, NOT THE GUI'S COORDINATE SPACE.
	--
	-- This ScreenGui sets IgnoreGuiInset, so its space starts `inset` pixels ABOVE the visible
	-- screen: a fromScale(1, 1) frame inside it runs from -inset to viewport-inset, and a
	-- centre-anchored window inside THAT lands inset/2 too high. On the 58px inset measured in
	-- Studio that is 34px -- which put the Achievements and Collection close buttons, and the
	-- upgrade board's header, off the top edge of the screen.
	--
	-- Every other element already compensates because it is positioned from `top`. These four
	-- are the only ones that fill the screen, so they are the only ones that never did.
	--
	-- A shared parent frame would fix it once for all future panels, but this gui uses
	-- ZIndexBehavior.Sibling, where an ancestor's ZIndex governs everything beneath it -- so a
	-- wrapper would quietly reorder every panel against the nav. Applied per element instead,
	-- which is what the gui's own comment says this HUD does.
	--
	-- Position AND height are a pair. Moving the root down without shortening it fixes the top
	-- but hangs the same number of pixels off the bottom -- exactly where Collection's action
	-- dock and the upgrade Close button live.
	for _, panel in ipairs({ board, collectionPanel, achievementsPanel, rebirthPanel, lockedPanel }) do
		local scrim = panel and (panel.root or panel.scrim)
		if scrim then
			scrim.Position = UDim2.fromOffset(0, inset.Y)
			scrim.Size = UDim2.new(1, 0, 1, -inset.Y)
		end
	end

	toastHolder.Position = compact
		and UDim2.new(0.5, 0, 1, -132)
		or UDim2.new(0.5, 0, 1, -96)
end

function HUD.start(callbacks)
	local player = Players.LocalPlayer

	gui = Instance.new("ScreenGui")
	gui.Name = "RaffleHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- we apply the inset ourselves, per element
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	-- RollPanel's shared BallIcon is Vide-driven, so the otherwise-imperative panel now gets
	-- one lifetime root of its own. The ScreenGui lives for the whole client session, matching
	-- the root lifetime exactly.
	vide.root(function()
		rollPanel = RollPanel.new(gui, callbacks)
	end)

	-- ---- right navigation ----------------------------------------------
	navHolder = Instance.new("Frame")
	navHolder.Name = "Nav"
	navHolder.AnchorPoint = Vector2.new(1, 0)
	navHolder.BackgroundTransparency = 1
	navHolder.AutomaticSize = Enum.AutomaticSize.Y
	navHolder.Parent = gui
	local navLayout = Instance.new("UIListLayout")
	navLayout.Padding = UDim.new(0, 8)
	navLayout.SortOrder = Enum.SortOrder.LayoutOrder
	navLayout.Parent = navHolder

	-- ---- bottom bar (compact only) -------------------------------------
	bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.AnchorPoint = Vector2.new(0.5, 1)
	bottomBar.Position = UDim2.new(0.5, 0, 1, -10)
	bottomBar.Size = UDim2.new(1, -20, 0, 60)
	bottomBar.BackgroundTransparency = 1
	bottomBar.Visible = false
	bottomBar.Parent = gui
	local barLayout = Instance.new("UIListLayout")
	barLayout.FillDirection = Enum.FillDirection.Horizontal
	barLayout.Padding = UDim.new(0, 8)
	barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	barLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	barLayout.SortOrder = Enum.SortOrder.LayoutOrder
	barLayout.Parent = bottomBar

	-- ---- toasts ---------------------------------------------------------
	toastHolder = Instance.new("Frame")
	toastHolder.Name = "Toasts"
	toastHolder.AnchorPoint = Vector2.new(0.5, 1)
	toastHolder.BackgroundTransparency = 1
	toastHolder.Size = UDim2.fromOffset(300, 120)
	toastHolder.Parent = gui
	local toastLayout = Instance.new("UIListLayout")
	toastLayout.Padding = UDim.new(0, 4)
	toastLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toastLayout.Parent = toastHolder

	-- ---- upgrade board ---------------------------------------------------
	--
	-- NIL-GUARDED, and not defensively-for-the-sake-of-it. Panels are built BEFORE the nav
	-- column, and a panel's onOpenChanged can fire during construction, so the tile it wants
	-- to deselect may genuinely not exist yet. This used to reference a `upgradesButton` local
	-- that the registry refactor deleted, which made it an undeclared global: every nav click
	-- threw inside showOnly and the click died before reaching the panel it was opening.
	board = UpgradeBoard.new(gui, {
		onPurchase = callbacks.onPurchase,
		onOpenChanged = function(open)
			if navButtons.UPGRADES then
				navButtons.UPGRADES:setSelected(open)
			end
		end,
	})

	-- ---- panels ----------------------------------------------------------
	-- A panel closed by its own X must deselect its tile too, or the nav column keeps
	-- showing a screen as open after it has gone.
	settingsPanel = SettingsPanel.new(gui, {
		onChanged = callbacks.onSettingsChanged,
		onOpenChanged = function(open)
			if navButtons.SETTINGS then
				navButtons.SETTINGS:setSelected(open)
			end
		end,
	})

	-- Vide components must be built inside a reactive root. One root owns the whole panel, so
	-- tearing it down would clean up every effect and spring it created.
	vide.root(function()
		collectionPanel = CollectionPanel.new(gui, {
			onOpened = callbacks.onRequestInventory,
			onResyncNeeded = callbacks.onRequestInventory,
			onSetPolicy = callbacks.onSetVariantPolicy,
			onSetPolicyMany = callbacks.onSetVariantPolicyMany,
			onDropNext = callbacks.onDropNext,
			onOpenChanged = function(open)
				if navButtons.COLLECTION then
					navButtons.COLLECTION:setSelected(open)
				end
			end,
		})
		achievementsPanel = AchievementsPanel.new(gui, {
			onClaim = callbacks.onClaimAchievement,
			onOpenChanged = function(open)
				if navButtons.ACHIEVEMENTS then
					navButtons.ACHIEVEMENTS:setSelected(open)
				end
			end,
		})
		rebirthPanel = RebirthPanel.new(gui, {
			onRebirth = callbacks.onRebirth,
			onOpenChanged = function(open)
				if navButtons.REBIRTH then
					navButtons.REBIRTH:setSelected(open)
				end
			end,
		})
		lockedPanel = LockedPanel.new(gui)
		return function() end
	end)

	-- ---- navigation, built from the registry ------------------------------
	--
	-- The controller knows about ITEMS, not about Upgrades and Settings specifically. Adding
	-- Quests or a Shop later is a row in NavRegistry plus a panel, with nothing here to edit.
	local openers: { [string]: (boolean) -> () } = {
		UPGRADES = function(open) board:setOpen(open) end,
		COLLECTION = function(open) collectionPanel:setOpen(open) end,
		ACHIEVEMENTS = function(open) achievementsPanel:setOpen(open) end,
		REBIRTH = function(open) rebirthPanel:setOpen(open) end,
		SETTINGS = function(open) settingsPanel:setOpen(open) end,
	}
	local isOpen: { [string]: () -> boolean } = {
		UPGRADES = function() return board:isOpen() end,
		COLLECTION = function() return collectionPanel:isOpen() end,
		ACHIEVEMENTS = function() return achievementsPanel:isOpen() end,
		REBIRTH = function() return rebirthPanel:isOpen() end,
		SETTINGS = function() return settingsPanel:isOpen() end,
	}

	-- THE REGISTRY'S `badge` FIELD, MADE REAL.
	--
	-- It used to be declarative only: the registry named a badge, and the controller hardcoded
	-- a branch per tile. The registry's own comment claimed a future tile could opt in without
	-- the controller learning about it, which was not true -- and the proof is that
	-- COLLECTION has declared `newDiscovery` since the registry was written and it has never
	-- been drawn, because nobody wrote the branch.
	--
	-- One predicate per badge NAME, looked up by the nav loop. Adding a badge to a tile is now
	-- a row in the registry plus an entry here, and forgetting the entry means no badge rather
	-- than a silent lie.
	local affordableNow = false
	local rebirthReadyNow = false
	local badgeSources: { [string]: () -> boolean } = {
		affordable = function()
			return affordableNow
		end,
		claimable = function()
			return achievementsPanel:claimableCount() > 0
		end,
		newDiscovery = function()
			for _, row in pairs(collectionPanel.rows()) do
				if row.isNew then
					return true
				end
			end
			return false
		end,
		rebirthReady = function()
			return rebirthReadyNow
		end,
	}

	for _, item in ipairs(NavRegistry.ordered()) do
		local open = openers[item.id]
		local opened = isOpen[item.id]

		closers[item.id] = function()
			if open then
				open(false)
			elseif item.locked then
				lockedPanel:setOpen(false)
			end
		end

		navButtons[item.id] = NavButton.new(navHolder, {
			label = item.label,
			accent = item.accent,
			order = item.order,
			onActivated = function()
				if item.locked then
					-- HONEST LOCK: it opens, and says plainly that the system does not exist
					-- yet. No badge, no fake progress, no purchase path.
					local opening = not lockedPanel:isOpen() or lockedPanel:currentId() ~= item.id
					showOnly(opening and item.id or nil)
					lockedPanel:show(item.id, item.label, item.lockedMessage, opening)
					return
				end
				local opening = not opened()
				showOnly(opening and item.id or nil)
				open(opening)
			end,
		})
	end

	relayout()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(relayout)
	end
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(relayout)

	return {
		setState = function(state)
			rollPanel:setState(state)
			board:setState(state)
			collectionPanel:setState(state)
			achievementsPanel:setState(state)
			rebirthPanel:setState(state)
			rebirthReadyNow = state.rebirth ~= nil and state.rebirth.eligible == true
			local affordable = false
			for id, rank in pairs(state.ranks) do
				local upgrade = UpgradeConfig.get(id)
				if upgrade and not upgrade.preview and upgrade.maxRank > 0 and rank < upgrade.maxRank then
					if UpgradeConfig.requirementsMet(id, state.ranks) then
						local cost = UpgradeConfig.costOfNext(id, rank)
						if cost and state.tickets >= cost then
							affordable = true
						end
					end
				end
			end
			affordableNow = affordable

			-- EVERY badge, from the registry, by name. A badge means "there is something here
			-- you have not taken", so it goes out while you are looking at it -- which is why
			-- the open check is here rather than inside each predicate.
			for _, item in ipairs(NavRegistry.ordered()) do
				local button = navButtons[item.id]
				local predicate = item.badge and badgeSources[item.badge]
				if button and predicate then
					local opened = isOpen[item.id]
					button:setBadge(predicate() and not (opened ~= nil and opened()))
				end
			end
		end,

		-- A returning player's saved presentation choices, pushed through the SAME path a
		-- click takes, so restoring cannot diverge from choosing.
		applySavedSettings = function(settings)
			settingsPanel:set(settings)
		end,

		-- Inventory replication lands here and goes straight to the panel, which decides
		-- whether it is a usable delta or a reason to ask for the whole truth again.
		applyInventorySync = function(payload)
			return collectionPanel.applySync(payload)
		end,

		openCollection = function(open)
			showOnly(open and "COLLECTION" or nil)
			collectionPanel:setOpen(open)
		end,
		openRebirth = function(open)
			showOnly(open and "REBIRTH" or nil)
			rebirthPanel:setOpen(open)
		end,
		rebirthOpen = function()
			return rebirthPanel:isOpen()
		end,
		collectionOpen = function()
			return collectionPanel:isOpen()
		end,
		setReveal = function(reveal)
			rollPanel:setReveal(reveal)
		end,
		toast = buildToast,
		settingsPanel = settingsPanel,
		-- Exposed so the Studio-only measurement bridge can drive the board the way a click
		-- does, rather than reaching into UpgradeBoard's internals.
		openBoard = function(open)
			showOnly(open and "UPGRADES" or nil)
			board:setOpen(open)
		end,
		boardOpen = function()
			return board:isOpen()
		end,
		pulseRoll = function(seconds)
			rollPanel:pulseCooldown(seconds)
		end,
		relayout = relayout,
	}
end

return HUD
