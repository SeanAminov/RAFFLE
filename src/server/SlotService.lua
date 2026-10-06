-- The multiplier band at the bottom of the table.
--
-- The pads themselves are Studio-authored geometry (Studio owns geometry), but everything
-- ABOUT them -- multiplier, colour, printed label -- is repainted from Rewards on startup.
-- Editing a number in Rewards.lua and pressing Play is therefore enough to change both the
-- payout and what the player reads on the pad, with no rebuild.
--
-- The pad COUNT still comes from geometry. If it disagrees with Rewards the service says so
-- loudly rather than quietly paying out against pads that do not exist.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rewards = require(Shared:WaitForChild("Rewards"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))

local SlotService = {}

SlotService.stats = { pads = 0, painted = 0 }

local function paint(pad: BasePart, index: number)
	local slot = Rewards.slot(index)

	pad.Material = Enum.Material.SmoothPlastic
	pad.Transparency = 0
	pad.Color = slot.fill
	pad.CastShadow = false

	local gui = pad:FindFirstChildWhichIsA("SurfaceGui")
	if not gui then
		gui = Instance.new("SurfaceGui")
		gui.Name = "SurfaceGui"
		gui.Parent = pad
	end
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false

	local label = gui:FindFirstChildWhichIsA("TextLabel")
	if not label then
		label = Instance.new("TextLabel")
		label.Parent = gui
	end

	-- The Top face's canvas X axis runs along the pad's DEPTH, so the label has to be
	-- rotated a quarter turn to read up-frame. Rotation does NOT re-lay-out a UI element,
	-- so a full-bleed label would have its long axis land across the pad's NARROW side and
	-- the text would be cut off -- which is what clipped the 5x. A SQUARE label on the
	-- short dimension has the same footprint at any rotation, so it cannot clip.
	local shortSide = math.min(pad.Size.X, pad.Size.Z) * gui.PixelsPerStud
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromOffset(shortSide * 0.86, shortSide * 0.86)
	label.BackgroundTransparency = 1
	label.Font = Rewards.SLOT_FONT
	label.Text = Rewards.slotLabel(index)
	label.TextColor3 = slot.text
	label.TextScaled = true
	label.TextStrokeTransparency = 0.65
	label.Rotation = -90

	local constraint = label:FindFirstChildWhichIsA("UITextSizeConstraint")
	if not constraint then
		constraint = Instance.new("UITextSizeConstraint")
		constraint.Parent = label
	end
	constraint.MaxTextSize = 150

	pad:SetAttribute("SlotIndex", index)
	pad:SetAttribute("SlotMultiplier", slot.mult)
end

function SlotService.start(root: Instance)
	local art = TableSpec.folder(root, "Art")
	if not art then
		warn("[RAFFLE] SlotService: Art folder not found; multiplier band not painted")
		return
	end

	local pads = {}
	for _, child in ipairs(art:GetChildren()) do
		if child:IsA("BasePart") and child.Name:match("^Slot%d+$") then
			table.insert(pads, child)
		end
	end
	table.sort(pads, function(a, b) return a.Name < b.Name end)

	SlotService.stats.pads = #pads
	if #pads ~= Rewards.slotCount() then
		warn(("[RAFFLE] SlotService: %d slot pads built but Rewards defines %d. "
			.. "Changing the NUMBER of slots needs the pads rebuilt in Studio; "
			.. "changing their VALUES does not.")
			:format(#pads, Rewards.slotCount()))
	end

	for index, pad in ipairs(pads) do
		if index <= Rewards.slotCount() then
			paint(pad, index)
			SlotService.stats.painted += 1
		end
	end
end

return SlotService
