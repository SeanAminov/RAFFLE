--!strict
-- THE BUBBLY COMPONENT KIT. Vide-flavoured building blocks every panel is made of.
--
-- UITheme still owns the palette, corners, strokes, fonts and the stud pattern -- this module
-- owns SHAPE and BEHAVIOUR. A component here that hardcodes a colour is a defect; it should
-- be reading UITheme. That split is what lets the whole game be re-skinned by editing one
-- file, and it survives Vide exactly as it survived the imperative panels.
--
-- ---------------------------------------------------------------------------------------
-- WHY THIS EXISTS SEPARATELY FROM THE PANELS
--
-- The arcade look is a set of rules -- thick dark bevel, chunky outlined text, a faint inset
-- texture, a press that squashes and overshoots. Written inline, those rules drift: the
-- fourth panel is always slightly wrong. Written once here, a new panel gets them by
-- construction and the drift has nowhere to happen.
--
-- ---------------------------------------------------------------------------------------
-- MOTION
--
-- Every animation is a Vide spring, and Vide's springs are driven by Ticker (see
-- Ticker.driveVide). So the whole UI animates on the ONE RunService connection the client
-- already had, inherits its hitch clamp, and costs nothing per component.
--
-- REDUCE MOTION is a source, not a parameter. Flipping it re-evaluates every spring target
-- already on screen rather than only affecting components built afterwards.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared:WaitForChild("UITheme"))
local vide = require(Shared:WaitForChild("Vide"))

local create = vide.create
local source = vide.source
local spring = vide.spring

local UIKit = {}

-- ---------------------------------------------------------------- motion policy

-- One source, read by every springy component. Set from the settings panel.
local reducedMotion = source(false)

UIKit.reducedMotion = reducedMotion

function UIKit.setReducedMotion(value: boolean)
	reducedMotion(value and true or false)
end

-- THE OVERSHOOT IS THE DAMPING, NOT A KEYFRAME.
--
-- An underdamped spring springs past its target and settles back on its own, which is exactly
-- the "release with a small overshoot around 1.03" the design calls for -- without a second
-- animation, a timer, or a target that lies about where it is going. The target is always the
-- honest resting scale; the bounce falls out of the physics.
--
-- THE DAMPING IS DERIVED FROM THE WANTED OVERSHOOT, not picked by feel.
--
-- A second-order system overshoots its step by exp(-pi*z / sqrt(1 - z^2)). The press travels
-- 1.00 -> 0.94, a step of 0.06, and the design asks for a release peaking around 1.03 -- an
-- overshoot of ~0.03, or 50% of the step. Solving for z gives ~0.22.
--
--   z = 0.55 -> 12% of 0.06 = peak 1.007   (measured 1.005: correct, and far too subtle)
--   z = 0.22 -> 49% of 0.06 = peak 1.030   (measured 1.026 -- discrete stepping eats a little)
--   z = 0.19 -> 54% of 0.06 = peak 1.033   (measured below; lands in the 1.03-1.04 band)
--
-- Vide's solver explodes if 4*pi*z/period exceeds 2*UPDATE_RATE (240), i.e. period must stay
-- above pi*z/60 = 0.012s here. 0.13 has an order of magnitude of margin, so this cannot be
-- tuned into instability by accident.
UIKit.SPRING_PERIOD = 0.13
UIKit.SPRING_DAMPING = 0.19

-- Press squashes the face; hover lifts it slightly. There is deliberately no explicit
-- overshoot value -- see above.
UIKit.PRESSED_SCALE = 0.94
UIKit.HOVER_SCALE = 1.02

-- MOTION TIERS. The first build gave every control the full bounce, and a panel with eleven
-- filter chips plus five checkboxes read as a trampoline: the effect that makes ONE big
-- button feel good is noise when sixteen things do it at once.
--
-- So bounce is now a property of a control's ROLE. Primary actions keep the full squash and
-- overshoot; small repeated controls get a shallow, nearly-critically-damped press that still
-- confirms the click without drawing the eye.
UIKit.MOTION = {
	-- Roll, nav tiles, Drop Next: things you press deliberately and rarely.
	primary = { press = 0.94, damping = 0.19, period = 0.13 },
	-- Repeated row actions: one small acknowledgement, settled before the pointer can travel
	-- to the next row. A slightly underdamped spring gives one tiny overshoot, not a wobble.
	quick = { press = 0.975, hover = 1.012, damping = 0.55, period = 0.07 },
	-- Chips, checkboxes, close buttons: things there are a lot of.
	subtle = { press = 0.975, damping = 0.75, period = 0.10 },
	none = { press = 1.00, damping = 1.00, period = 0.10 },
}

-- SUBTLE IS THE DEFAULT. A control has to ask for the big bounce, which means adding twenty
-- small buttons to a panel cannot accidentally make it wobble.

-- With Reduce Motion on, every scale collapses to 1: no squash, no overshoot, no lift. The
-- control still changes COLOUR on press, so it never stops being legible as a button --
-- removing motion must not remove feedback.
local function scaleFor(target: number): number
	if reducedMotion() then
		return 1
	end
	return target
end

UIKit.scaleFor = scaleFor

-- ---------------------------------------------------------------- colour helpers

function UIKit.shift(colour: Color3, amount: number): Color3
	return Color3.new(
		math.clamp(colour.R + amount, 0, 1),
		math.clamp(colour.G + amount, 0, 1),
		math.clamp(colour.B + amount, 0, 1))
end

-- The darker rim drawn behind a coloured face. Derived, so a new accent cannot forget one.
function UIKit.rim(colour: Color3): Color3
	return Color3.new(colour.R * 0.42, colour.G * 0.42, colour.B * 0.42)
end

-- ---------------------------------------------------------------- primitives

-- Thick dark outline + rounded corner, the signature treatment on every surface.
function UIKit.bevel(thickness: number?, colour: Color3?)
	return create("UIStroke") {
		Thickness = thickness or UITheme.STROKE.thick,
		Color = colour or UITheme.COLOR.outline,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}
end

function UIKit.corner(radius: number?)
	return create("UICorner") {
		CornerRadius = UDim.new(0, radius or UITheme.CORNER.normal),
	}
end

function UIKit.pad(amount: number?)
	local value = UDim.new(0, amount or UITheme.PAD.normal)
	return create("UIPadding") {
		PaddingTop = value, PaddingBottom = value,
		PaddingLeft = value, PaddingRight = value,
	}
end

-- Chunky display text -- the reference's signature. Light text gets the dark arcade outline;
-- dark text is already its own contrast on a bright face and stays flat. Outlining dark text
-- with the same dark colour turns small labels into an unreadable ink blot.
--
-- `colour` accepts a plain Color3 OR a source, so the outline policy follows reactive state
-- changes too (for example, a selection chip turning from dim to dark-on-gold).
function UIKit.text(props)
	local function colourOf(): Color3
		local value = props.colour
		if type(value) == "function" then
			return value()
		end
		return value or UITheme.COLOR.text
	end

	return create("TextLabel") {
		BackgroundTransparency = 1,
		Font = props.font or UITheme.FONT.display,
		Text = props.text,
		TextSize = props.size or UITheme.TEXT_SIZE.body,
		TextColor3 = colourOf,
		TextStrokeColor3 = UITheme.COLOR.textOutline,
		TextStrokeTransparency = function()
			if props.flat then
				return 1
			end
			return colourOf() == UITheme.COLOR.textOutline and 1 or 0
		end,
		TextXAlignment = props.align or Enum.TextXAlignment.Left,
		TextYAlignment = props.valign or Enum.TextYAlignment.Center,
		TextScaled = props.scaled,
		TextTruncate = props.truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		Size = props.size2 or UDim2.fromScale(1, 1),
		Position = props.position,
		AnchorPoint = props.anchor,
		LayoutOrder = props.order,
		ZIndex = props.zindex or 2,
		Visible = props.visible,
	}
end

-- The faint inset grid that gives big surfaces their moulded-plastic feel. Drawn from frames
-- rather than an image so it needs no asset and scales cleanly.
--
-- BOUNDED ON PURPOSE: columns * rows instances, and callers are expected to keep that small.
-- A stud grid on a card that appears twenty times is twenty times the cost, which is why
-- cards use a stripe instead (below) and only large fixed surfaces get studs.
function UIKit.studs(columns: number, rows: number, alpha: number?)
	local children = {}
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			table.insert(children, create("Frame") {
				BackgroundColor3 = Color3.fromRGB(255, 255, 255),
				BackgroundTransparency = alpha or 0.9,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromScale(0.6 / columns, 0.55 / rows),
				Position = UDim2.fromScale((column + 0.5) / columns, (row + 0.5) / rows),
				ZIndex = 1,
				create("UICorner") { CornerRadius = UDim.new(0, 3) },
			})
		end
	end
	return create("Frame") {
		Name = "Studs",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		table.unpack(children),
	}
end

-- A cheaper texture than studs: two diagonal highlight bands, as on the reference's header.
-- THREE instances regardless of surface size, so it is safe on a card that repeats.
function UIKit.stripes(alpha: number?)
	local bands = {}
	for index = 0, 1 do
		table.insert(bands, create("Frame") {
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = alpha or 0.92,
			BorderSizePixel = 0,
			Rotation = 22,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.30 + index * 0.22, 0.5),
			Size = UDim2.fromScale(0.10, 2.4),
			ZIndex = 1,
		})
	end
	return create("Frame") {
		Name = "Stripes",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		ZIndex = 1,
		table.unpack(bands),
	}
end

-- ---------------------------------------------------------------- surfaces

-- A panel: dark body, thick bevel, rounded. The workhorse container.
function UIKit.panel(props)
	return create("Frame") {
		Name = props.name or "Panel",
		BackgroundColor3 = props.colour or UITheme.COLOR.panel,
		BorderSizePixel = 0,
		Size = props.size,
		Position = props.position,
		AnchorPoint = props.anchor,
		LayoutOrder = props.order,
		Visible = props.visible,
		ZIndex = props.zindex,
		ClipsDescendants = props.clip,

		UIKit.corner(props.radius),
		UIKit.bevel(props.stroke, props.strokeColour),
		table.unpack(props.children or {}),
	}
end

-- ---------------------------------------------------------------- control handles

-- A button's press/hover state, addressable from code by the instance it belongs to.
--
-- WEAK-KEYED, so a destroyed button's entry disappears with it and this can never become a
-- leak that grows with every panel opened.
--
-- It exists because input state should be drivable without faking input: a test cannot Fire a
-- real RBXScriptSignal, and neither can a gamepad focus handler or a tutorial that wants to
-- show a button depressing. One seam serves all three.
local controls: { [Instance]: any } = setmetatable({}, { __mode = "k" }) :: any

function UIKit.controlOf(button: Instance)
	return controls[button]
end

-- ---------------------------------------------------------------- bubbly button
--
-- The interaction the whole UI is built on: press squashes the INNER FACE to 0.94, release
-- overshoots to ~1.035 and settles at 1, hover lifts slightly.
--
-- THE FACE SCALES, NEVER THE BUTTON. The outer TextButton keeps its layout size, so a
-- squashing control cannot shove its neighbours around or fight a UIListLayout. That is the
-- same rule the upgrade board follows for graph anchors, applied everywhere.
function UIKit.button(props)
	local pressed = source(false)
	local hovered = source(false)

	-- With Reduce Motion on, scaleFor collapses every target to 1, so this source never
	-- changes and the spring never moves. No branch, no special case: motion stops because
	-- there is nothing left to animate towards.
	local motion = UIKit.MOTION[props.motion or "subtle"] or UIKit.MOTION.subtle

	local scale = spring(function()
		if pressed() then
			return scaleFor(motion.press)
		elseif hovered() then
			return scaleFor(motion.hover or UIKit.HOVER_SCALE)
		end
		return 1
	end, motion.period, motion.damping)

	-- `accent` may be a plain Color3 OR a source, so a caller can recolour a control from
	-- state without rebuilding it. Resolved at read time rather than at construction.
	local function accentOf(): Color3
		local value = props.accent
		if type(value) == "function" then
			return value()
		end
		return value or UITheme.COLOR.green
	end

	-- Children are assembled explicitly rather than inline. A `cond and x or nil` inside a
	-- table constructor leaves a HOLE in the array part, and everything after it -- including
	-- the caller's own children -- silently stops being parented.
	local faceChildren = {
		create("UIScale") { Scale = scale },
		UIKit.corner(props.radius),
		UIKit.bevel(props.stroke),
	}
	if props.texture then
		table.insert(faceChildren, props.texture())
	end
	for _, child in ipairs(props.children or {}) do
		table.insert(faceChildren, child)
	end

	local face = create("Frame") {
		Name = "Face",
		BackgroundColor3 = function()
			local base = props.disabled and props.disabled() and UITheme.COLOR.locked or accentOf()
			if pressed() then
				return UIKit.shift(base, -0.10)
			elseif hovered() then
				return UIKit.shift(base, 0.06)
			end
			return base
		end,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,

		table.unpack(faceChildren),
	}

	local function activate()
		if props.disabled and props.disabled() then
			return
		end
		if props.onClick then
			props.onClick()
		end
	end

	local instance = create("TextButton") {
		Name = props.name or "Button",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = props.size or UDim2.new(1, 0, 0, UITheme.TOUCH_MIN),
		Position = props.position,
		AnchorPoint = props.anchor,
		LayoutOrder = props.order,
		Visible = props.visible,
		ZIndex = props.zindex or 2,

		MouseEnter = function() hovered(true) end,
		MouseLeave = function() hovered(false); pressed(false) end,
		MouseButton1Down = function() pressed(true) end,
		MouseButton1Up = function() pressed(false) end,
		Activated = activate,

		face,
	}

	controls[instance] = {
		pressed = pressed,
		hovered = hovered,
		activate = activate,
		scale = scale,
	}

	return instance
end

-- ---------------------------------------------------------------- checkbox

-- A square check control. Reads its value from a source and reports changes; it never holds
-- authoritative state, because the SERVER owns every policy this drives.
function UIKit.checkbox(props)
	return UIKit.button {
		name = props.name,
		size = props.size or UDim2.fromOffset(28, 28),
		order = props.order,
		radius = UITheme.CORNER.small,
		stroke = UITheme.STROKE.normal,
		accent = props.accent or UITheme.COLOR.slate,
		onClick = function()
			if props.onChanged then
				props.onChanged(not props.value())
			end
		end,
		children = {
			UIKit.text {
				text = function() return props.value() and "\u{2713}" or "" end,
				size = UITheme.TEXT_SIZE.body,
				align = Enum.TextXAlignment.Center,
				colour = UITheme.COLOR.text,
			},
		},
	}
end

-- ---------------------------------------------------------------- badge

-- The small rotated flag from the reference ("New!"). Rotation is fixed, not animated: a
-- permanently spinning badge on every new card would be noise, and Reduce Motion would have
-- to special-case it.
function UIKit.badge(props)
	return create("Frame") {
		Name = "Badge",
		BackgroundColor3 = props.colour or UITheme.COLOR.red,
		BorderSizePixel = 0,
		AnchorPoint = props.anchor or Vector2.new(0, 0),
		Position = props.position or UDim2.fromScale(0, 0),
		Size = props.size or UDim2.fromOffset(52, 22),
		Rotation = props.rotation or -8,
		Visible = props.visible,
		ZIndex = props.zindex or 6,

		UIKit.corner(UITheme.CORNER.small),
		UIKit.bevel(UITheme.STROKE.normal),
		UIKit.text {
			text = props.text,
			size = props.textSize or UITheme.TEXT_SIZE.small,
			align = Enum.TextXAlignment.Center,
			zindex = 7,
		},
	}
end

-- ---------------------------------------------------------------- gamepad safety

-- Claiming GuiService.SelectedObject without a gamepad attached produces a warning on every
-- open. Stage 2.1 hit this on the upgrade board; the fix belongs here so no future panel
-- rediscovers it.
function UIKit.gamepadPresent(): boolean
	return UserInputService.GamepadEnabled
end

return UIKit
