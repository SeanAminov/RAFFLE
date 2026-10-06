--!strict
-- The single source of truth for how the UI looks: colours, strokes, corners, spacing,
-- the stud pattern, typography and animation timing.
--
-- Every panel and button reads from here. Changing the palette is a change to this file,
-- not a sweep through a dozen scripts, and nothing may hardcode a colour or a corner
-- radius locally.
--
-- The look is the bright arcade style from the reference: saturated fills, thick dark
-- outlines, chunky outlined text, and a faint inset stud grid on the large buttons.

local UITheme = {}

-- ---------------------------------------------------------------- palette

UITheme.COLOR = {
	-- surfaces
	panel = Color3.fromRGB(20, 20, 34),
	panelDeep = Color3.fromRGB(13, 13, 24),
	board = Color3.fromRGB(17, 20, 42),
	scrim = Color3.fromRGB(0, 0, 0),

	-- text
	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(168, 176, 202),
	textOutline = Color3.fromRGB(10, 10, 18),

	-- accents
	gold = Color3.fromRGB(252, 202, 66),
	green = Color3.fromRGB(72, 214, 118),
	greenDeep = Color3.fromRGB(38, 150, 78),
	red = Color3.fromRGB(230, 74, 74),
	blue = Color3.fromRGB(84, 162, 248),
	purple = Color3.fromRGB(174, 116, 246),
	pink = Color3.fromRGB(238, 110, 178),
	slate = Color3.fromRGB(74, 82, 112),

	-- states
	locked = Color3.fromRGB(58, 64, 88),
	affordable = Color3.fromRGB(72, 214, 118),
	unaffordable = Color3.fromRGB(126, 92, 92),
	outline = Color3.fromRGB(9, 9, 16),
}

-- ---------------------------------------------------------------- geometry

UITheme.STROKE = { thin = 2, normal = 3, thick = 4 }
UITheme.CORNER = { small = 6, normal = 10, large = 14, pill = 999 }
UITheme.PAD = { tight = 6, normal = 10, loose = 16 }

-- ---------------------------------------------------------------- typography

UITheme.FONT = {
	display = Enum.Font.FredokaOne,
	body = Enum.Font.GothamBold,
	mono = Enum.Font.Code,
}

UITheme.TEXT_SIZE = { tiny = 12, small = 15, body = 18, large = 26, huge = 38, giant = 52 }

-- ---------------------------------------------------------------- motion

UITheme.TIME = { press = 0.07, hover = 0.12, panel = 0.20, reveal = 0.35 }

UITheme.EASE_OUT = TweenInfo.new(UITheme.TIME.panel, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
UITheme.EASE_PRESS = TweenInfo.new(UITheme.TIME.press, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Minimum touch target. Anything the player taps must be at least this tall.
UITheme.TOUCH_MIN = 44

-- ---------------------------------------------------------------- builders
--
-- Small helpers so a caller never hand-rolls a stroke or a corner and drifts from the
-- theme. They return the created instance so it can be tweaked further if truly needed.

function UITheme.corner(parent: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or UITheme.CORNER.normal)
	corner.Parent = parent
	return corner
end

function UITheme.stroke(parent: Instance, thickness: number?, colour: Color3?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness or UITheme.STROKE.normal
	stroke.Color = colour or UITheme.COLOR.outline
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function UITheme.padding(parent: Instance, amount: number?): UIPadding
	local value = UDim.new(0, amount or UITheme.PAD.normal)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop, padding.PaddingBottom = value, value
	padding.PaddingLeft, padding.PaddingRight = value, value
	padding.Parent = parent
	return padding
end

-- The faint inset stud grid that gives the big buttons their moulded-plastic feel.
-- Drawn from frames rather than an image so it needs no asset and scales cleanly.
function UITheme.studPattern(parent: GuiObject, columns: number, rows: number, alpha: number?)
	local holder = Instance.new("Frame")
	holder.Name = "Studs"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = (parent.ZIndex or 1)
	holder.Parent = parent

	local transparency = alpha or 0.88
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local stud = Instance.new("Frame")
			stud.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			stud.BackgroundTransparency = transparency
			stud.BorderSizePixel = 0
			stud.AnchorPoint = Vector2.new(0.5, 0.5)
			stud.Size = UDim2.fromScale(0.6 / columns, 0.55 / rows)
			stud.Position = UDim2.fromScale((column + 0.5) / columns, (row + 0.5) / rows)
			stud.ZIndex = holder.ZIndex
			stud.Parent = holder
			UITheme.corner(stud, 3)
		end
	end
	return holder
end

-- Chunky display text. Light labels get the reference's dark outline; labels intentionally
-- using that same dark colour stay flat or the identical fill and stroke merge into a blot.
function UITheme.label(parent: Instance, text: string, size: number, colour: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	local resolvedColour = colour or UITheme.COLOR.text
	label.BackgroundTransparency = 1
	label.Font = UITheme.FONT.display
	label.Text = text
	label.TextSize = size
	label.TextColor3 = resolvedColour
	label.TextStrokeColor3 = UITheme.COLOR.textOutline
	label.TextStrokeTransparency = resolvedColour == UITheme.COLOR.textOutline and 1 or 0
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

return UITheme
