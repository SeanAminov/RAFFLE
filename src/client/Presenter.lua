--!strict
-- THE presenter. Every cosmetic effect in the game is created, gated and destroyed here.
--
-- PURELY COSMETIC, WITHOUT EXCEPTION. The server has already validated the hit, applied the
-- cooldown, awarded the Tickets and settled the ball before this module hears anything.
-- Deleting this file would leave the machine mechanically identical: balls would still
-- launch, score, mutate and drain -- silently.
--
-- ONE PLACE DECIDES. No other client file branches on a settings value; they call in here and
-- this module answers. That is what makes "does this effect play?" have a single answer, and
-- what makes the Full-vs-Minimal ledger equivalence testable rather than hopeful.
--
-- COST MODEL:
--   * popups come from a POOL that is grown lazily and shrunk on demand
--   * with Hit Numbers OFF the pool is DESTROYED -- zero instances, not hidden labels
--   * everything animates inside the ONE shared Ticker step
--   * there is no per-ball, per-popup or per-effect frame connection anywhere
--
-- WHAT IS NEVER SUPPRESSED, at any settings level: the physical balls, the rolled ball's
-- identity, the mutation badge, the Tickets balance, queue state, purchase confirmation and
-- drain settlements. Those are gameplay information, not decoration. Settings.ALWAYS_VISIBLE
-- names them; the drain and mutation paths below bypass the Hit Numbers filter entirely.

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))
local TargetConfig = require(Shared:WaitForChild("TargetConfig"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))
local UITheme = require(Shared:WaitForChild("UITheme"))
local Settings = require(Shared:WaitForChild("Settings"))

local Ticker = require(script.Parent:WaitForChild("Ticker"))

local Presenter = {}

local settings = Settings.normalise(nil)

local popupPool = {}
local activePopups = {}
local activeFlashes = {}
local targets: { [string]: BasePart } = {}
local targetDecorations: { [BasePart]: any } = {}
local ambient: any = nil
local ambientClock = 0
local ambientAccumulator = 0
local machineBurst = 0
local effectsFolder: Folder? = nil

-- Colour changes do not need a 60 Hz write rate. The analytic motion stays time-based, while
-- a 30 Hz presentation budget roughly halves property traffic on low-end devices.
local AMBIENT_UPDATE_INTERVAL = 1 / 30

-- A restrained arcade palette, shared by every idle effect. This is deliberately a four-
-- colour carousel rather than a free-running HSV rainbow: the machine moves, but keeps the
-- teal / violet / pink / gold identity established by the Studio-authored visual pass.
local AMBIENT_PALETTE = {
	Color3.fromRGB(43, 205, 199),
	Color3.fromRGB(151, 104, 245),
	Color3.fromRGB(236, 91, 174),
	Color3.fromRGB(252, 202, 66),
}
local WHITE = Color3.new(1, 1, 1)

-- Coalescing state: targetId -> { until, popup } so repeated hits on one bumper merge into
-- the label already on screen instead of stacking new ones.
local coalescing: { [string]: any } = {}

Presenter.stats = {
	shown = 0,
	dropped = 0,
	suppressedByHitNumbers = 0,
	coalesced = 0,
	activeEffects = 0,
	popupInstances = 0,
	flashesSuppressed = 0,
	evictedForDrain = 0,
}

local function paletteAt(phase: number): Color3
	local wrapped = phase % 1
	local position = wrapped * #AMBIENT_PALETTE
	local index = math.floor(position) + 1
	local nextIndex = index % #AMBIENT_PALETTE + 1
	return AMBIENT_PALETTE[index]:Lerp(AMBIENT_PALETTE[nextIndex], position % 1)
end

local function decorationsFor(part: BasePart)
	local cached = targetDecorations[part]
	if cached then
		return cached
	end
	local decorations = {}
	for _, suffix in ipairs({ "_Ring", "_Top" }) do
		local decoration = part.Parent and part.Parent:FindFirstChild(part.Name .. suffix)
		if decoration and decoration:IsA("BasePart") then
			table.insert(decorations, {
				part = decoration,
				baseMaterial = decoration.Material,
				baseColor = decoration.Color,
				baseTransparency = decoration.Transparency,
			})
		end
	end
	targetDecorations[part] = decorations
	return decorations
end

-- ---------------------------------------------------------------- popup pool

local function createPopup()
	local anchor = Instance.new("Part")
	anchor.Name = "ScorePopup"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(5.0, 2.0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = ""
	label.TextStrokeColor3 = Color3.fromRGB(16, 10, 30)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Parent = billboard

	Presenter.stats.popupInstances += 1
	return { anchor = anchor, billboard = billboard, label = label }
end

-- The live cap: whichever is smaller, the effects policy or the global tuning ceiling.
local function popupCap(): number
	if settings.hitNumbers == Settings.HIT_NUMBERS.OFF then
		return 0
	end
	return math.min(Settings.policy(settings.effects).popupCap, PinballTuning.MAX_CONCURRENT_EFFECTS)
end

local function destroyPopup(popup)
	popup.anchor:Destroy()
	Presenter.stats.popupInstances -= 1
end

-- Brings the pool in line with the current cap. Turning Hit Numbers OFF destroys every
-- instance -- pooled AND in flight -- so the promise of "zero popup instances" is literal.
local function reconcilePool()
	local cap = popupCap()

	if cap == 0 then
		for _, entry in ipairs(activePopups) do
			destroyPopup(entry.popup)
		end
		table.clear(activePopups)
		for _, popup in ipairs(popupPool) do
			destroyPopup(popup)
		end
		table.clear(popupPool)
		table.clear(coalescing)
		return
	end

	-- Retire surplus pooled instances when the cap drops (Full -> Minimal). In-flight ones
	-- are left to finish and are simply not returned to an over-full pool.
	while #popupPool + #activePopups > cap and #popupPool > 0 do
		destroyPopup(table.remove(popupPool))
	end
end

-- ---------------------------------------------------------------- ambient machine

local function ambientPart(name: string, size: Vector3, colour: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = colour
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function buildAmbient(root: Instance, parent: Instance)
	local visualRoot = root:FindFirstChild("VisualRefresh")
	if not visualRoot then
		return nil
	end
	local generated = Instance.new("Folder")
	generated.Name = "AmbientMachine"
	generated.Parent = parent

	local visualParts = {}
	for _, item in ipairs(visualRoot:GetDescendants()) do
		if item:IsA("BasePart") then
			table.insert(visualParts, {
				part = item,
				baseColor = item.Color,
				baseTransparency = item.Transparency,
			})
		end
	end
	table.sort(visualParts, function(a, b)
		return a.part.Name < b.part.Name
	end)

	-- One cached light packet per authored lane makes the direction of travel readable in a
	-- still-dark playfield. These are client-only, non-queryable parts; no light instances,
	-- trails or per-packet connections are created.
	local lanePackets = {}
	for index, entry in ipairs(visualParts) do
		local name = entry.part.Name
		if string.find(name, "Path", 1, true) == 1 or name == "CentreSpine" then
			local size = entry.part.Size
			local alongX = size.X >= size.Z
			local long = alongX and size.X or size.Z
			local short = alongX and size.Z or size.X
			local packetLong = math.clamp(long * 0.14, 1.1, 2.6)
			local packetShort = math.clamp(short * 1.55, 0.32, 0.72)
			local packetSize = alongX
				and Vector3.new(packetLong, 0.12, packetShort)
				or Vector3.new(packetShort, 0.12, packetLong)
			local packet = ambientPart("LanePacket_" .. name, packetSize,
				AMBIENT_PALETTE[index % #AMBIENT_PALETTE + 1], generated)
			table.insert(lanePackets, {
				part = packet,
				guide = entry.part,
				alongX = alongX,
				length = long,
				phase = (#lanePackets * 0.19) % 1,
			})
		end
	end

	local bumperBodies = {}
	local bumperParts = {}
	for _, target in pairs(targets) do
		table.insert(bumperBodies, { part = target, baseColor = target.Color })
		for _, decoration in ipairs(decorationsFor(target)) do
			table.insert(bumperParts, decoration)
		end
	end
	table.sort(bumperBodies, function(a, b)
		return a.part.Name < b.part.Name
	end)
	table.sort(bumperParts, function(a, b)
		return a.part:GetFullName() < b.part:GetFullName()
	end)

	local boardPart = nil
	local playfield = root:FindFirstChild("Playfield", true)
	if playfield and playfield:IsA("BasePart") then
		boardPart = { part = playfield, baseColor = playfield.Color }
	end

	local scannerArms = {}
	if boardPart then
		local board = boardPart.part
		local armLength = math.min(board.Size.X, board.Size.Z) * 0.42
		for index = 1, 2 do
			local arm = ambientPart("ScannerArm" .. index,
				Vector3.new(index == 1 and 0.34 or 0.18, 0.08, armLength),
				AMBIENT_PALETTE[index], generated)
			table.insert(scannerArms, { part = arm, length = armLength, phase = (index - 1) * math.pi })
		end
	end

	local dropperParts = {}
	local dropperLight = nil
	local carriage = root:FindFirstChild("DropperCarriage", true)
	if carriage then
		for _, item in ipairs(carriage:GetDescendants()) do
			if item:IsA("BasePart") and (string.find(item.Name, "_Band", 1, true)
				or string.find(item.Name, "_Fin", 1, true)
				or string.find(item.Name, "_Eye", 1, true)) then
				table.insert(dropperParts, { part = item, baseColor = item.Color })
			elseif item:IsA("PointLight") then
				dropperLight = {
					light = item,
					baseColor = item.Color,
					baseBrightness = item.Brightness,
				}
			end
		end
	end
	table.sort(dropperParts, function(a, b)
		return a.part.Name < b.part.Name
	end)

	local slotStrokes = {}
	for _, item in ipairs(root:GetDescendants()) do
		if item.Name == "VisualRefresh_Border" then
			local stroke = item:FindFirstChildOfClass("UIStroke")
			if stroke then
				table.insert(slotStrokes, {
					stroke = stroke,
					baseColor = stroke.Color,
					baseTransparency = stroke.Transparency,
				})
			end
		end
	end
	table.sort(slotStrokes, function(a, b)
		return a.stroke:GetFullName() < b.stroke:GetFullName()
	end)

	local apronGradient = nil
	local apronGui = root:FindFirstChild("VisualRefresh_ApronGui", true)
	if apronGui then
		local stripe = apronGui:FindFirstChild("AccentStripe", true)
		local gradient = stripe and stripe:FindFirstChildOfClass("UIGradient")
		if gradient then
			apronGradient = {
				gradient = gradient,
				baseOffset = gradient.Offset,
				baseRotation = gradient.Rotation,
			}
		end
	end

	return {
		visualParts = visualParts,
		lanePackets = lanePackets,
		scannerArms = scannerArms,
		boardPart = boardPart,
		bumperBodies = bumperBodies,
		bumperParts = bumperParts,
		dropperParts = dropperParts,
		dropperLight = dropperLight,
		slotStrokes = slotStrokes,
		apronGradient = apronGradient,
		dirty = false,
	}
end

local function restoreAmbient()
	if not ambient or not ambient.dirty then
		return
	end
	for _, entry in ipairs(ambient.visualParts) do
		entry.part.Color = entry.baseColor
		entry.part.Transparency = entry.baseTransparency
	end
	for _, entry in ipairs(ambient.lanePackets) do
		entry.part.Transparency = 1
	end
	for _, entry in ipairs(ambient.scannerArms) do
		entry.part.Transparency = 1
	end
	if ambient.boardPart then
		ambient.boardPart.part.Color = ambient.boardPart.baseColor
	end
	for _, entry in ipairs(ambient.bumperBodies) do
		entry.part.Color = entry.baseColor
	end
	for _, entry in ipairs(ambient.bumperParts) do
		entry.part.Color = entry.baseColor
		entry.part.Transparency = entry.baseTransparency
	end
	for _, entry in ipairs(ambient.dropperParts) do
		entry.part.Color = entry.baseColor
	end
	if ambient.dropperLight then
		ambient.dropperLight.light.Color = ambient.dropperLight.baseColor
		ambient.dropperLight.light.Brightness = ambient.dropperLight.baseBrightness
	end
	for _, entry in ipairs(ambient.slotStrokes) do
		entry.stroke.Color = entry.baseColor
		entry.stroke.Transparency = entry.baseTransparency
	end
	if ambient.apronGradient then
		ambient.apronGradient.gradient.Offset = ambient.apronGradient.baseOffset
		ambient.apronGradient.gradient.Rotation = ambient.apronGradient.baseRotation
	end
	ambient.dirty = false
end

local function ambientStrength(): number
	if settings.effects == Settings.EFFECTS.FULL then
		return 1
	elseif settings.effects == Settings.EFFECTS.REDUCED then
		return 0.38
	end
	return 0
end

local function stepAmbient(dt: number)
	if not ambient then
		return
	end

	local strength = ambientStrength()
	if strength <= 0 then
		restoreAmbient()
		ambientAccumulator = 0
		machineBurst = 0
		return
	end

	ambientClock += dt * (settings.effects == Settings.EFFECTS.FULL and 1 or 0.55)
	machineBurst = math.max(0, machineBurst - dt * 1.8)
	ambientAccumulator += dt
	if ambientAccumulator < AMBIENT_UPDATE_INTERVAL then
		return
	end
	ambientAccumulator %= AMBIENT_UPDATE_INTERVAL
	local burst = machineBurst * strength
	local breath = 0.5 + 0.5 * math.sin(ambientClock * 1.35)
	ambient.dirty = true

	-- The lane strips are the readable chase: colour drifts slowly while brightness travels
	-- from segment to segment. The shared breath keeps separate strips inhaling as one board;
	-- a score burst lifts the whole route briefly toward white.
	for index, entry in ipairs(ambient.visualParts) do
		local chase = 0.5 + 0.5 * math.sin(ambientClock * 2.2 - index * 0.72)
		local wave = breath * 0.62 + chase * 0.38
		local colour = paletteAt(ambientClock * 0.055 + index / #ambient.visualParts)
		entry.part.Color = entry.baseColor:Lerp(colour, 0.42 * strength):Lerp(WHITE, burst * 0.62)
		entry.part.Transparency = math.clamp(
			entry.baseTransparency - strength * (0.025 + wave * 0.16) - burst * 0.16, 0, 1)
	end
	if ambient.boardPart then
		local boardColour = ambient.boardPart.baseColor
			:Lerp(paletteAt(ambientClock * 0.018), 0.022 * strength)
			:Lerp(WHITE, strength * (0.018 + breath * 0.038) + burst * 0.08)
		ambient.boardPart.part.Color = boardColour
	end

	for index, entry in ipairs(ambient.lanePackets) do
		local travel = (ambientClock * 0.24 + entry.phase) % 1
		local distance = (travel - 0.5) * entry.length * 0.86
		local height = entry.guide.Size.Y * 0.5 + entry.part.Size.Y * 0.5 + 0.025
		local offset = entry.alongX and Vector3.new(distance, height, 0)
			or Vector3.new(0, height, distance)
		local edgeFade = math.sin(travel * math.pi)
		entry.part.CFrame = entry.guide.CFrame * CFrame.new(offset)
		entry.part.Color = paletteAt(ambientClock * 0.11 + index / #ambient.lanePackets)
		entry.part.Transparency = math.clamp(
			1 - edgeFade * strength * (0.72 + breath * 0.24) - burst * 0.08, 0.02, 1)
	end

	if ambient.boardPart then
		local board = ambient.boardPart.part
		local centre = board.CFrame * CFrame.new(0, board.Size.Y * 0.5 + 0.07, 0)
		for index, entry in ipairs(ambient.scannerArms) do
			local angle = ambientClock * (index == 1 and 0.34 or -0.24) + entry.phase
			entry.part.CFrame = centre * CFrame.Angles(0, angle, 0)
				* CFrame.new(0, 0, -entry.length * 0.5)
			entry.part.Color = paletteAt(ambientClock * 0.045 + index * 0.24)
			entry.part.Transparency = math.clamp(
				1 - strength * (0.10 + breath * 0.08) - burst * 0.08, 0.72, 1)
		end
	end

	-- Bodies share the slow inhale, while each cap is slightly out of phase with its neighbour.
	-- Only colour/transparency move: collision geometry remains completely untouched.
	for index, entry in ipairs(ambient.bumperBodies) do
		local offset = 0.5 + 0.5 * math.sin(ambientClock * 1.35 - index * 0.11)
		entry.part.Color = entry.baseColor:Lerp(
			WHITE, strength * (0.018 + offset * 0.065) + burst * 0.05)
	end
	for index, entry in ipairs(ambient.bumperParts) do
		local offset = 0.5 + 0.5 * math.sin(ambientClock * 1.7 - index * 0.32)
		local wave = breath * 0.7 + offset * 0.3
		local colour = paletteAt(ambientClock * 0.04 + index / #ambient.bumperParts)
		entry.part.Color = entry.baseColor:Lerp(
			colour, strength * (0.13 + wave * 0.15)):Lerp(WHITE, wave * strength * 0.06)
		entry.part.Transparency = math.clamp(
			entry.baseTransparency + (1 - wave) * strength * 0.08, 0, 1)
	end

	local scanner = 0.5 + 0.5 * math.sin(ambientClock * 3.1)
	local scannerColour = paletteAt(ambientClock * 0.12)
	for index, entry in ipairs(ambient.dropperParts) do
		local mix = strength * (0.38 + 0.24 * math.sin(ambientClock * 2.4 + index))
		entry.part.Color = entry.baseColor:Lerp(scannerColour, math.clamp(mix, 0, 0.72))
	end
	if ambient.dropperLight then
		ambient.dropperLight.light.Color = ambient.dropperLight.baseColor:Lerp(
			scannerColour, strength * 0.62)
		ambient.dropperLight.light.Brightness = ambient.dropperLight.baseBrightness
			+ strength * (0.25 + scanner * 0.75) + burst * 1.8
	end

	-- The payout rail reads as a travelling selection lamp, not seven flashing boxes at once.
	for index, entry in ipairs(ambient.slotStrokes) do
		local wave = 0.5 + 0.5 * math.sin(ambientClock * 2.8 - index * 0.86)
		entry.stroke.Color = entry.baseColor:Lerp(
			paletteAt(ambientClock * 0.07 + index / #ambient.slotStrokes), strength * 0.52)
		entry.stroke.Transparency = math.clamp(
			entry.baseTransparency - wave * strength * 0.34 - burst * 0.18, 0, 1)
	end

	if ambient.apronGradient then
		ambient.apronGradient.gradient.Offset = Vector2.new(
			math.sin(ambientClock * 1.25) * 0.72 * strength, 0)
		ambient.apronGradient.gradient.Rotation = ambient.apronGradient.baseRotation
			+ math.sin(ambientClock * 0.55) * 5 * strength
	end
end

-- ---------------------------------------------------------------- steps

local function stepPopups(dt: number)
	local i = 1
	while i <= #activePopups do
		local entry = activePopups[i]
		entry.elapsed += dt
		local a = math.min(entry.elapsed / PinballTuning.POPUP_TIME, 1)

		entry.popup.anchor.CFrame =
			CFrame.new(entry.startPos + Vector3.new(0, PinballTuning.POPUP_RISE * a, 0))
		entry.popup.label.TextTransparency = a
		entry.popup.label.TextStrokeTransparency = a

		if a >= 1 then
			if entry.targetId then
				coalescing[entry.targetId] = nil
			end
			entry.popup.billboard.Enabled = false
			entry.popup.anchor.Parent = nil
			-- Return to the pool only if the pool still has room under the LIVE cap; a cap
			-- that shrank mid-flight retires the instance instead of hoarding it.
			if #popupPool + #activePopups - 1 < popupCap() then
				table.insert(popupPool, entry.popup)
			else
				destroyPopup(entry.popup)
			end
			table.remove(activePopups, i)
		else
			i += 1
		end
	end
end

local function stepFlashes(dt: number)
	local i = 1
	while i <= #activeFlashes do
		local flash = activeFlashes[i]
		flash.elapsed += dt
		local a = math.min(flash.elapsed / PinballTuning.HIT_FLASH_TIME, 1)

		if flash.light then
			flash.light.Brightness = PinballTuning.HIT_FLASH_BRIGHTNESS
				+ (PinballTuning.TARGET_LIGHT_BRIGHTNESS - PinballTuning.HIT_FLASH_BRIGHTNESS) * a
		end
		-- Brief emissive burst, then straight back to the recorded idle material.
		flash.part.Material = (a < 1) and Enum.Material.Neon or flash.baseMaterial
		for _, decoration in ipairs(flash.decorations) do
			local burst = 1 - a
			decoration.part.Material = (a < 1) and Enum.Material.Neon or decoration.baseMaterial
			decoration.part.Color = decoration.baseColor:Lerp(WHITE, burst * 0.68)
			decoration.part.Transparency = math.clamp(
				decoration.baseTransparency - burst * 0.16, 0, 1)
		end

		if a >= 1 then
			if flash.light then
				flash.light.Brightness = PinballTuning.TARGET_LIGHT_BRIGHTNESS
			end
			flash.part.Material = flash.baseMaterial
			for _, decoration in ipairs(flash.decorations) do
				decoration.part.Material = decoration.baseMaterial
				decoration.part.Color = decoration.baseColor
				decoration.part.Transparency = decoration.baseTransparency
			end
			table.remove(activeFlashes, i)
		else
			i += 1
		end
	end
end

local function step(dt: number)
	stepAmbient(dt)
	stepPopups(dt)
	stepFlashes(dt)
	Presenter.stats.activeEffects = #activePopups + #activeFlashes
	if #activePopups == 0 and #activeFlashes == 0
		and (not ambient or ambientStrength() <= 0) then
		Ticker.unregister("Presenter")
	end
end

-- ---------------------------------------------------------------- effects

local function startFlash(part: BasePart)
	if not Settings.policy(settings.effects).bumperFlash then
		Presenter.stats.flashesSuppressed += 1
		return
	end
	local light = part:FindFirstChildOfClass("PointLight")
	local decorations = decorationsFor(part)
	-- Restart rather than stack if this target is already reacting, so rapid repeat hits
	-- cannot create competing controllers for the same part.
	for _, flash in ipairs(activeFlashes) do
		if flash.part == part then
			flash.elapsed = 0
			return
		end
	end
	table.insert(activeFlashes, {
		part = part,
		light = light,
		decorations = decorations,
		elapsed = 0,
		baseMaterial = part.Material,
	})
	Ticker.register("Presenter", step)
end

-- Shows one floating number. `kind` is "hit" | "drain" | "mutation" | "bonus".
--
-- The Hit Numbers filter applies to "hit" only. Drains, mutations and bonuses are gameplay
-- results, not decoration, and are shown at every level except OFF.
local function floatingNumber(kind: string, text: string, colour: Color3, worldPosition: Vector3,
	targetId: string?, points: number, oneIn: number?)

	if settings.hitNumbers == Settings.HIT_NUMBERS.OFF then
		Presenter.stats.suppressedByHitNumbers += 1
		return
	end
	if settings.hitNumbers == Settings.HIT_NUMBERS.IMPORTANT
		and not Settings.isImportant(kind, points, oneIn) then
		Presenter.stats.suppressedByHitNumbers += 1
		return
	end

	-- COALESCE. Repeated hits on the same target inside the window update the label already
	-- on screen and restart its rise, instead of allocating another one. This merges the
	-- VISUAL only -- the server already granted every one of those awards separately.
	local window = Settings.policy(settings.effects).coalesceWindow
	if targetId and window > 0 then
		local existing = coalescing[targetId]
		if existing and existing.entry.elapsed < window then
			existing.total += points
			existing.entry.elapsed = 0
			existing.entry.popup.label.Text = "+" .. existing.total
			existing.entry.popup.label.TextTransparency = 0
			existing.entry.popup.label.TextStrokeTransparency = 0
			Presenter.stats.coalesced += 1
			return
		end
	end

	local cap = popupCap()

	-- A DRAIN OUTRANKS TRICKLE. Both used to share one pool and one cap, and because bumper
	-- hits outnumber drains roughly twenty to one, a settlement arriving while the pool was
	-- saturated was silently dropped -- the single number the player most needs to see,
	-- losing to the one they least need. A drain now evicts the oldest ordinary hit instead.
	local popup = table.remove(popupPool)
	if not popup and #activePopups >= cap then
		if kind == "drain" then
			-- The oldest entry that carries a targetId is an ordinary hit; drains are stored
			-- without one, so a drain can never evict another drain.
			for index, entry in ipairs(activePopups) do
				if entry.targetId then
					coalescing[entry.targetId] = nil
					popup = entry.popup
					table.remove(activePopups, index)
					Presenter.stats.evictedForDrain += 1
					break
				end
			end
		end
		if not popup then
			Presenter.stats.dropped += 1
			return
		end
	end
	if not popup then
		popup = createPopup()
	end

	popup.label.Text = text
	popup.label.TextColor3 = colour
	popup.label.TextTransparency = 0
	popup.label.TextStrokeTransparency = 0
	popup.billboard.Enabled = true

	local start = worldPosition + Vector3.new(0, 3.0, 0)
	popup.anchor.CFrame = CFrame.new(start)
	popup.anchor.Parent = effectsFolder

	local entry = { popup = popup, elapsed = 0, startPos = start, targetId = targetId }
	table.insert(activePopups, entry)
	if targetId then
		coalescing[targetId] = { entry = entry, total = points }
	end
	Presenter.stats.shown += 1
	Ticker.register("Presenter", step)
end

-- Called when the SERVER reports a scored hit. Nothing here decides anything.
function Presenter.onScore(targetId: string, points: number, worldPosition: Vector3, mutationId: string?)
	local part = targets[targetId]
	local scoreBurst = math.clamp(points / 500, 0.16, 0.52)
	if mutationId and mutationId ~= "NONE" then
		scoreBurst = 0.9
	end
	machineBurst = math.max(machineBurst, scoreBurst)
	if part then
		startFlash(part)
	end

	local isDrain = targetId:sub(1, 6) == "DRAIN_"
	local colour = part and part.Color or Color3.fromRGB(255, 255, 255)
	if isDrain then
		colour = UITheme.COLOR.gold
	end
	if mutationId and mutationId ~= "NONE" then
		colour = UITheme.COLOR.blue
	end

	floatingNumber(
		isDrain and "drain" or "hit",
		"+" .. points,
		colour,
		worldPosition,
		-- Drains are never coalesced: each one is a distinct settlement.
		(not isDrain) and targetId or nil,
		points,
		nil)
end

-- The reveal payload has already been decided by the server. Its presentation magnitude is
-- safe to reuse as a machine-wide celebratory pulse; this does not infer rarity or outcomes.
function Presenter.onReveal(reveal)
	local presentation = reveal and reveal.presentation
	local revealStrength = presentation and presentation.reveal
	if type(revealStrength) ~= "number" then
		revealStrength = 0.28
	end
	if reveal and reveal.mutationId and reveal.mutationId ~= "NONE" then
		revealStrength = math.max(revealStrength, 0.82)
	end
	machineBurst = math.max(machineBurst, math.clamp(revealStrength, 0.2, 1))
end

-- ---------------------------------------------------------------- UI motion

-- The one scaler for UI bounce. Reduced Motion flattens it to nothing; Minimal effects do
-- the same. Callers pass their intended magnitude and get back what they may actually use.
function Presenter.motion(amount: number): number
	return amount * Settings.bounceScale(settings.effects, settings.reducedMotion)
end

-- Tween helper that respects Reduced Motion by snapping instead of animating.
function Presenter.tween(instance: Instance, info: TweenInfo, goal: { [string]: any }): Tween?
	if Settings.bounceScale(settings.effects, settings.reducedMotion) <= 0 then
		for property, value in pairs(goal) do
			(instance :: any)[property] = value
		end
		return nil
	end
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	return tween
end

function Presenter.soundEnabled(): boolean
	return settings.sound
end

-- ---------------------------------------------------------------- settings

function Presenter.setSettings(next)
	settings = Settings.normalise(next)
	reconcilePool()
	if ambientStrength() <= 0 then
		restoreAmbient()
	elseif ambient then
		Ticker.register("Presenter", step)
	end
end

function Presenter.settings()
	return settings
end

function Presenter.start()
	local root = TableSpec.findRoot()
	if root then
		-- Resolved by attribute across the whole table, so no target-specific code and no
		-- folder path is baked in here either.
		for _, part in ipairs(root:GetDescendants()) do
			local id = part:GetAttribute(TargetConfig.ATTR_ID)
			if part:IsA("BasePart") and type(id) == "string" then
				targets[id] = part
			end
		end
	end
	local folder = Instance.new("Folder")
	folder.Name = "RafflePresenterFX"
	folder.Parent = workspace
	effectsFolder = folder

	ambient = root and buildAmbient(root, folder) or nil
	if ambient then
		Ticker.register("Presenter", step)
	end

	-- The pool is grown LAZILY. Nothing is pre-created, so a session that opens with Hit
	-- Numbers OFF never allocates a single popup instance.
end

return Presenter
