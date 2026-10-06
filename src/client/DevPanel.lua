-- Studio-only DEV panel.
--
-- Shows nothing unless BOTH the client is running in Studio AND the server actually
-- created the DEV remote (which it only does in Studio). In production the remote does
-- not exist, so this panel cannot be built even if the RunService check were bypassed --
-- and neither the panel NOR its toggle pill is created at all.
--
-- The raw diagnostics that used to sit on the player-facing HUD live here now: the public
-- surface shows Tickets and a real bounded queue, not a debug supply counter.
--
-- COLLAPSED BY DEFAULT. Normal Play Mode testing should look like the game, not like a
-- debugging session, so the panel starts closed behind a small DEV pill in the corner.
-- The collapse state is session-local and resets every run. F8 toggles it as well, but the
-- visible pill is the primary control and is never the only way in.
--
-- Forcing a ball or a mutation is how the rare end of the catalog gets exercised. A forced
-- result is stamped by the server and rendered as DEV FORCED, so it can never be mistaken
-- for a natural roll.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local BallCatalog = require(Shared:WaitForChild("BallCatalog"))
local MutationCatalog = require(Shared:WaitForChild("MutationCatalog"))

local DevPanel = {}

local TOGGLE_KEY = Enum.KeyCode.F8

local ACTIONS = {
	{ id = "ROLL", label = "Roll once", colour = Color3.fromRGB(58, 158, 110) },
	{ id = "GRANT_TICKETS", label = "+10,000 Tickets", colour = Color3.fromRGB(70, 110, 170), value = 10000 },
	{ id = "TOGGLE_FEED", label = "Pause / resume hopper", colour = Color3.fromRGB(88, 84, 128) },
	{ id = "TOGGLE_HOPPER_RECORDING", label = "Hopper: record on/off", colour = Color3.fromRGB(46, 118, 128) },
	{ id = "HOPPER_REPORT", label = "Hopper: print report", colour = Color3.fromRGB(46, 118, 128) },
	{ id = "CLEAR_BALLS", label = "Clear my balls", colour = Color3.fromRGB(150, 62, 62) },
	{ id = "RESET_UPGRADES", label = "Reset upgrades", colour = Color3.fromRGB(150, 92, 40) },
	{ id = "DUMP_STATS", label = "Dump stats to output", colour = Color3.fromRGB(64, 72, 96) },
}

local function button(parent: Instance, text: string, colour: Color3, order: number): TextButton
	local instance = Instance.new("TextButton")
	instance.Size = UDim2.new(1, 0, 0, 22)
	instance.BackgroundColor3 = colour
	instance.BorderSizePixel = 0
	instance.Font = Enum.Font.GothamBold
	instance.Text = text
	instance.TextColor3 = Color3.fromRGB(255, 255, 255)
	instance.TextSize = 11
	instance.LayoutOrder = order
	instance.Parent = parent
	UITheme.corner(instance, 5)
	return instance
end

function DevPanel.start(devRemote: RemoteEvent?, getState)
	if not RunService:IsStudio() or not devRemote then
		return nil
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "RaffleDevPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- ---- the pill -------------------------------------------------------
	-- Small, bottom-right, and deliberately clear of the player-facing surfaces: the roll
	-- panel is top-left, Upgrades and Settings are top-right, and the upgrade board's detail
	-- panel and CLOSE button sit at the board's top-right and bottom-centre.
	local pill = Instance.new("TextButton")
	pill.Name = "DevPill"
	pill.AnchorPoint = Vector2.new(1, 1)
	pill.Position = UDim2.new(1, -12, 1, -12)
	pill.Size = UDim2.fromOffset(58, 26)
	pill.BackgroundColor3 = Color3.fromRGB(150, 46, 46)
	pill.BackgroundTransparency = 0.15
	pill.BorderSizePixel = 0
	pill.AutoButtonColor = false
	pill.Font = Enum.Font.GothamBold
	pill.Text = "DEV"
	pill.TextColor3 = Color3.fromRGB(255, 226, 226)
	pill.TextSize = 12
	pill.ZIndex = 60
	pill.Parent = gui
	UITheme.corner(pill, UITheme.CORNER.pill)

	-- ---- the panel ------------------------------------------------------
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(1, 1)
	-- Sits directly ABOVE the pill so the pill itself is never covered by what it opens.
	panel.Position = UDim2.new(1, -12, 1, -44)
	panel.Size = UDim2.new(0, 168, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(18, 16, 28)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 59
	panel.Parent = gui
	UITheme.corner(panel, 8)
	UITheme.padding(panel, 8)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "DEV (STUDIO ONLY)"
	title.TextColor3 = Color3.fromRGB(255, 108, 108)
	title.TextSize = 11
	title.LayoutOrder = 0
	title.ZIndex = 60
	title.Parent = panel

	local diag = Instance.new("TextLabel")
	diag.Size = UDim2.new(1, 0, 0, 82)
	diag.BackgroundColor3 = Color3.fromRGB(10, 9, 18)
	diag.BorderSizePixel = 0
	diag.Font = Enum.Font.Code
	diag.Text = ""
	diag.TextColor3 = Color3.fromRGB(150, 232, 168)
	diag.TextSize = 11
	diag.TextXAlignment = Enum.TextXAlignment.Left
	diag.TextYAlignment = Enum.TextYAlignment.Top
	diag.LayoutOrder = 1
	diag.ZIndex = 60
	diag.Parent = panel
	UITheme.corner(diag, 5)

	for index, action in ipairs(ACTIONS) do
		local instance = button(panel, action.label, action.colour, index + 1)
		instance.ZIndex = 60
		instance.Activated:Connect(function()
			devRemote:FireServer(action.id, action.value)
		end)
	end

	-- ---- forced mutations ----------------------------------------------
	local mutationTitle = Instance.new("TextLabel")
	mutationTitle.Size = UDim2.new(1, 0, 0, 14)
	mutationTitle.BackgroundTransparency = 1
	mutationTitle.Font = Enum.Font.GothamBold
	mutationTitle.Text = "FORCE MUTATION"
	mutationTitle.TextColor3 = Color3.fromRGB(150, 224, 250)
	mutationTitle.TextSize = 10
	mutationTitle.LayoutOrder = 40
	mutationTitle.ZIndex = 60
	mutationTitle.Parent = panel

	for index, mutation in ipairs(MutationCatalog.MUTATIONS) do
		local instance = button(panel, mutation.name:upper(), mutation.tint, 40 + index)
		instance.TextColor3 = Color3.fromRGB(16, 22, 30)
		instance.ZIndex = 60
		instance.Activated:Connect(function()
			devRemote:FireServer("FORCE_MUTATION", mutation.id)
		end)
	end

	-- ---- forced balls ---------------------------------------------------
	-- Force any configured ball, so every rarity can be inspected without waiting for odds
	-- that analytic tests are the right tool for. Scrolled so the whole catalog fits in a
	-- fixed height however many balls are added later.
	local forceTitle = Instance.new("TextLabel")
	forceTitle.Size = UDim2.new(1, 0, 0, 14)
	forceTitle.BackgroundTransparency = 1
	forceTitle.Font = Enum.Font.GothamBold
	forceTitle.Text = "FORCE BALL"
	forceTitle.TextColor3 = Color3.fromRGB(240, 200, 120)
	forceTitle.TextSize = 10
	forceTitle.LayoutOrder = 50
	forceTitle.ZIndex = 60
	forceTitle.Parent = panel

	local forceList = Instance.new("ScrollingFrame")
	forceList.Size = UDim2.new(1, 0, 0, 96)
	forceList.BackgroundTransparency = 1
	forceList.BorderSizePixel = 0
	forceList.ScrollBarThickness = 4
	forceList.CanvasSize = UDim2.new()
	forceList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	forceList.LayoutOrder = 51
	forceList.ZIndex = 60
	forceList.Parent = panel
	local forceLayout = Instance.new("UIListLayout")
	forceLayout.Padding = UDim.new(0, 3)
	forceLayout.SortOrder = Enum.SortOrder.LayoutOrder
	forceLayout.Parent = forceList

	local order = 1
	local function forceButton(id: string, label: string, tint: Color3)
		local instance = button(forceList, label, tint, order)
		instance.ZIndex = 60
		instance.Activated:Connect(function()
			devRemote:FireServer("FORCE_BALL", id)
		end)
		order += 1
	end
	forceButton(BallCatalog.BASIC.id, "Basic", Color3.fromRGB(70, 74, 92))
	for _, entry in ipairs(BallCatalog.BALLS) do
		local band = BallCatalog.bandFor(entry.oneIn)
		forceButton(entry.id, ("%s  1 in %d"):format(entry.name, entry.oneIn), band.tint)
	end

	-- ---- collapse -------------------------------------------------------
	local open = false
	local function setOpen(next: boolean)
		open = next
		panel.Visible = open
		pill.BackgroundTransparency = open and 0.0 or 0.15
		pill.Text = open and "DEV ×" or "DEV"
	end
	setOpen(false)

	pill.Activated:Connect(function()
		setOpen(not open)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			setOpen(not open)
		end
	end)

	task.spawn(function()
		while gui.Parent do
			task.wait(0.25)
			-- Nothing is formatted while the panel is closed: the pill alone costs nothing.
			if open then
				local state = getState and getState()
				if state then
					diag.Text = ("tickets %d\nluck    x%.2f\nstored  %d (%d kinds)\nreserved %d\nin play %d\nrolls   %d\nmut lv  %d\nauto    %s\nsorter  %s")
						:format(state.tickets, state.luck, state.stored or 0, state.storedVariants or 0,
							state.reservations or 0, state.activeBalls, state.rolls,
							state.mutationRank or 0, tostring(state.autoRoll),
							tostring(state.prizeSorter))
				end
			end
		end
	end)

	return {
		setOpen = setOpen,
		isOpen = function() return open end,
	}
end

return DevPanel
