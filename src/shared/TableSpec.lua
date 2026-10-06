--!strict
-- The contract between Studio-authored table geometry and Rojo-managed code.
--
-- The table is BUILT in Studio (Studio owns geometry) but the
-- builder and every service read their coordinates from HERE, so there is ONE derivation
-- of where things are and the layout is reviewable in git.
--
-- COORDINATE FRAME: playfield-local, relative to TableRoot, converted with toWorld.
--     +X across the table, +Y up out of the surface, +Z up-slope toward the back.
-- The playfield is tilted so the back is raised, which rolls balls down to the flippers
-- under ordinary gravity instead of needing scripted motion.
--
-- BALL FEED: a DROPPER CARRIAGE tracks left and right along the top and releases balls as
-- it goes. There is no launch lane, plunger, habitrail or exit wheel. Every one of those
-- was a clog source: a ball that could not carry itself through the lane and around the
-- return rolled back and sat there. Across three 80 s soaks the lane held 49%, 65% and 70%
-- of all ball-samples, with single balls stuck up to 43 seconds. A moving drop point
-- cannot clog, and because the carriage is elsewhere on each release, entry position
-- varies with no scripted randomisation.
--
-- Removing the lane frees the full interior width, so EVERYTHING IS SYMMETRIC ABOUT x = 0.

-- Payout VALUES live in Rewards, not here. This file owns where things are; Rewards owns
-- what they are worth, so the numbers most likely to be retuned sit in one small file.
local Rewards = require(script.Parent:WaitForChild("Rewards"))
local PinballTuning = require(script.Parent:WaitForChild("PinballTuning"))

local TableSpec = {}

-- ---------------------------------------------------------------- instance names

TableSpec.ROOT_NAME = "PinballTable"
-- The previous mixed-furniture build is preserved in Workspace as PinballTable_Classic,
-- parked outside the camera. Swapping back is a rename + move, not a rebuild.
TableSpec.VARIANT = "BumperField"
TableSpec.TABLE_ROOT = "TableRoot"

TableSpec.CORE_FOLDER = "Core"
TableSpec.MECHANISMS_FOLDER = "Mechanisms"
TableSpec.SCORING_FOLDER = "Scoring"
TableSpec.SOCKETS_FOLDER = "Sockets"

TableSpec.CABINET_FOLDER = "Cabinet"
TableSpec.FIELD_FOLDER = "Field"
TableSpec.FEED_FOLDER = "Feed"
TableSpec.DRAIN_FOLDER = "Drain"
TableSpec.WALLS_FOLDER = "Walls"

TableSpec.FLIPPERS_FOLDER = "Flippers"
TableSpec.BUMPERS_FOLDER = "Bumpers"
TableSpec.SLINGSHOTS_FOLDER = "Slingshots"

TableSpec.TARGETS_FOLDER = "Targets"
TableSpec.SPINNER_FOLDER = "Spinner"
TableSpec.ROLLOVERS_FOLDER = "Rollovers"

TableSpec.BALLS_FOLDER = "Balls"
TableSpec.LIGHTS_FOLDER = "Lights"
TableSpec.PLATES_FOLDER = "UpgradePlates"

TableSpec.PLAYFIELD_NAME = "Playfield"
TableSpec.DRAIN_NAME = "DrainSensor"
TableSpec.SAVER_NAME = "BallSaverGate"
TableSpec.FLIPPER_PREFIX = "Flipper"

-- A part and its folder must NEVER share a name: a recursive FindFirstChild returns the
-- folder. That exact collision silently left the drain sensor unwired, and later the
-- spinwheel motor, both only caught in Play Mode.
TableSpec.DROPPER_NAME = "DropperCarriage"
-- Invisible ceiling over the whole interior, above the carriage. Nothing visible, pure
-- containment for the short stretch a freshly released ball spends above the plate.
TableSpec.LID_NAME = "TableLid"
TableSpec.LID_Y = 9.9
TableSpec.LID_THICKNESS = 1.0

TableSpec.FLIPPER_SIDE_ATTR = "FlipperSide"
TableSpec.SOCKET_ID_ATTR = "SocketId"
TableSpec.PLATE_ID_ATTR = "PlateId"
TableSpec.COLLISION_PROXY_ATTR = "CollisionProxy"

-- ---------------------------------------------------------------- scale

-- Shrunk from 1.9: with fat bumpers the field read as cramped. Smaller ball + wider
-- spacing gives the bouncing room to breathe.
TableSpec.BALL_DIAMETER = 1.5
TableSpec.BALL_RADIUS = 0.75
TableSpec.MIN_CORRIDOR = 2.2

TableSpec.OUTER_WIDTH = 54
-- LENGTHENED from 72. The band behind the old back wall held a decorative backboard and a
-- large blue apron slab no ball could ever reach, which read as a dead strip across the top
-- of frame. The playfield itself now occupies that space.
TableSpec.OUTER_LENGTH = 84
TableSpec.WALL_THICKNESS = 2
-- Visible wall height. The invisible collision proxies run from below the surface all the
-- way up to the lid, so the strip between the visible wall top and the lid -- which a
-- freshly released ball passes through -- is still enclosed.
TableSpec.WALL_HEIGHT = 8
TableSpec.WALL_PROXY_BOTTOM = -3

function TableSpec.wallProxyTop(): number
	return TableSpec.LID_Y - TableSpec.LID_THICKNESS / 2
end
TableSpec.SURFACE_THICKNESS = 1.6
TableSpec.CABINET_DEPTH = 9

TableSpec.TILT_DEGREES = 7
TableSpec.ORIGIN_HEIGHT = 10

TableSpec.INNER_X_MIN = -25
TableSpec.INNER_X_MAX = 25
TableSpec.INNER_Z_MIN = -34
-- The field grows UP-SLOPE only: the drain and the multiplier band at the front stay where
-- they are, so extending the back is what turns dead cabinet into playable floor.
TableSpec.INNER_Z_MAX = 46

-- The interior is no longer symmetric about z = 0, so anything spanning the whole field is
-- built about this centre rather than about the origin.
function TableSpec.fieldCentreZ(): number
	return (TableSpec.INNER_Z_MIN + TableSpec.INNER_Z_MAX) / 2
end

function TableSpec.fieldLength(): number
	return TableSpec.INNER_Z_MAX - TableSpec.INNER_Z_MIN
end

TableSpec.PF_X_MIN = -25
TableSpec.PF_X_MAX = 25
TableSpec.PF_CENTRE_X = 0

TableSpec.WIDTH = TableSpec.OUTER_WIDTH
TableSpec.LENGTH = TableSpec.OUTER_LENGTH

-- ---------------------------------------------------------------- frame

function TableSpec.playfieldCFrame(): CFrame
	return CFrame.new(0, TableSpec.ORIGIN_HEIGHT, 0)
		* CFrame.Angles(-math.rad(TableSpec.TILT_DEGREES), 0, 0)
end

function TableSpec.toWorld(x: number, y: number, z: number): CFrame
	return TableSpec.playfieldCFrame() * CFrame.new(x, y, z)
end

function TableSpec.toWorldPosition(x: number, y: number, z: number): Vector3
	return TableSpec.toWorld(x, y, z).Position
end

-- ---------------------------------------------------------------- dropper carriage

-- Moved to the very top of the interior: the band above the old 28.5 was dead space that
-- no ball ever used. The carriage now releases at the back wall and the whole length of the
-- table is playable.
TableSpec.DROPPER_Z = 42.5
-- The carriage sits ABOVE the one-way plate and is purely visual (CanCollide false): a
-- ball is released inside it, falls straight down through the plate, and nothing can ever
-- be pinned between the moving carriage and anything else.
-- Sized and placed so the hopper sits flush ON the glass and its whole decorated height
-- still clears the containment lid: 5.70 (plate top) .. 8.75 (top of the cap).
TableSpec.DROPPER_Y = 7.0
-- Wall to wall, less the back-corner fills the carriage now sweeps in front of: at
-- DROPPER_Z the corner diagonal reaches x 22.5, so a released ball needs its whole body
-- inside that. Checked by the builder rather than assumed.
TableSpec.DROPPER_TRAVEL = 22
TableSpec.DROPPER_SIZE = Vector3.new(4.6, 2.6, 4.2)

-- ---------------------------------------------------------------- one-way plate

-- Glass spanning the whole interior, BELOW the carriage. Balls dropped from above fall
-- through it; balls thrown up off the bumpers hit its underside and come back down.
--
-- The one-way behaviour is a COLLISION GROUP, not scripted teleporting: a ball is created
-- in BALL_FALLING_GROUP, which is set non-collidable against the plate, and is switched to
-- the default group the moment its whole body is below the plate. The switch is one-way,
-- so nothing that is already in the field can get back above the glass.
TableSpec.BOUNCE_PLATE = "BouncePlate"
TableSpec.BOUNCE_PLATE_Y = 5.5
TableSpec.BOUNCE_PLATE_THICKNESS = 0.4
TableSpec.PLATE_GROUP = "OneWayPlate"
TableSpec.BALL_FALLING_GROUP = "BallFalling"

function TableSpec.bouncePlateBottom(): number
	return TableSpec.BOUNCE_PLATE_Y - TableSpec.BOUNCE_PLATE_THICKNESS / 2
end

-- The height below which a falling ball is switched to the solid group. Chosen so the
-- ball's TOP is clear of the plate's underside at the instant it becomes solid, otherwise
-- the switch would happen mid-overlap and physics would eject the ball.
function TableSpec.plateClearY(): number
	return TableSpec.bouncePlateBottom() - TableSpec.BALL_RADIUS - 0.1
end

-- SAFETY INVARIANT, checked by the builder: the highest a ball can come to rest in the
-- field (on a bumper top) must be below plateClearY, or a ball could sit above the
-- threshold forever, never turn solid, and hang half-inside the glass.
function TableSpec.highestRestingBallY(): number
	return TableSpec.BUMPER_HEIGHT + TableSpec.BALL_RADIUS
end

-- ---------------------------------------------------------------- sweep profile
--
-- ONE CURVE produces BOTH the carriage position and the carriage velocity. They are returned
-- together from a single function so a caller physically cannot pair a fresh position with a
-- stale velocity, which is what the old split (position from `carriage.Position`, direction
-- from a separately-advanced `phase`) allowed.
--
-- The profile is a trapezoid with cosine-blended ends. Writing e for DROPPER_EASE, the
-- velocity SHAPE over one half-sweep tau in [0,1] is
--
--     v(tau) = (1 - cos(pi*tau/e)) / 2          tau < e            (ease out of a turnaround)
--     v(tau) = 1                                e <= tau <= 1-e    (cruise)
--     v(tau) = (1 - cos(pi*(1-tau)/e)) / 2      tau > 1-e          (ease into a turnaround)
--
-- and its integral over [0,1] is exactly (1 - e). Position is that integral, rescaled to the
-- full 2*TRAVEL span; speed is the shape scaled by
--
--     Vpeak = 4 * TRAVEL / (PERIOD * (1 - e))
--
-- so the carriage still covers the same range in the same period. Velocity is exactly zero at
-- both turnarounds and C1 continuous everywhere -- there is no instant reversal to inherit.

local function easeShape(tau: number, ease: number): number
	if ease <= 0 then
		return 1
	end
	if tau < ease then
		return (1 - math.cos(math.pi * tau / ease)) / 2
	end
	if tau > 1 - ease then
		return (1 - math.cos(math.pi * (1 - tau) / ease)) / 2
	end
	return 1
end

-- Integral of easeShape from 0 to tau. Closed form, so position and velocity are the same
-- curve rather than one being a numerical estimate of the other.
local function easeIntegral(tau: number, ease: number): number
	if ease <= 0 then
		return tau
	end
	local k = ease / (2 * math.pi)
	if tau < ease then
		return tau / 2 - k * math.sin(math.pi * tau / ease)
	end
	if tau > 1 - ease then
		local r = 1 - tau
		return (1 - ease) - (r / 2 - k * math.sin(math.pi * r / ease))
	end
	return ease / 2 + (tau - ease)
end

-- Returns (localX, localVelocityX, tau, studsToTurnaround) for a phase.
-- `tau` is progress through the current half-sweep in [0,1); 0 and 1 are the turnarounds.
function TableSpec.dropperSweep(phase: number): (number, number, number, number)
	local ease = math.clamp(PinballTuning.DROPPER_EASE, 0, 0.49)
	local travel = TableSpec.DROPPER_TRAVEL
	local period = PinballTuning.DROPPER_PERIOD

	local s = phase % 1
	local forward = s < 0.5
	local tau = (s % 0.5) * 2

	local u = easeIntegral(tau, ease) / (1 - ease)
	local x = forward and (-travel + 2 * travel * u) or (travel - 2 * travel * u)

	local peak = (4 * travel) / (period * (1 - ease))
	local vx = (forward and 1 or -1) * peak * easeShape(tau, ease)

	local toEnd = math.min(math.abs(x + travel), math.abs(x - travel))
	return x, vx, tau, toEnd
end

-- Phase 0..1 ping-pongs, so the carriage sweeps left, right and back.
function TableSpec.dropperLocalX(phase: number): number
	local x = TableSpec.dropperSweep(phase)
	return x
end

function TableSpec.dropperPosition(phase: number): Vector3
	return TableSpec.toWorldPosition(TableSpec.dropperLocalX(phase), TableSpec.DROPPER_Y, TableSpec.DROPPER_Z)
end

-- The ball leaves from the carriage's MOUTH, just clear of the glass, rather than from the
-- middle of the shell: it is seen to come out of the container and drop through the plate
-- instead of appearing inside the bodywork. Still fully above the plate at the moment of
-- release, so the fall through the glass is real. (An earlier cut released BELOW the plate,
-- which is why a 70 s soak recorded zero rebounds.)
function TableSpec.releaseLocalY(): number
	return TableSpec.BOUNCE_PLATE_Y + TableSpec.BOUNCE_PLATE_THICKNESS / 2
		+ TableSpec.BALL_RADIUS + 0.15
end

-- THE authoritative release point. An Attachment of this name is created under the carriage
-- at runtime (never saved into the place) and every release derives its CFrame from that
-- attachment's WorldCFrame -- not from the spec, not from three separate constants, and not
-- from the carriage's centre. If the carriage part is ever moved in Studio, the release
-- follows it, because there is only one source.
TableSpec.BALL_RELEASE_ATTACHMENT = "BallRelease"

-- Offset of that attachment inside the carriage part, in the carriage's own space.
-- Derived from the carriage's REAL height and the release plane, so the mouth is wherever
-- the built part actually is. Y only: the mouth is centred in X and Z by construction.
function TableSpec.releaseOffsetIn(carriage: BasePart): Vector3
	local carriageLocalY = TableSpec.playfieldCFrame():PointToObjectSpace(carriage.Position).Y
	return Vector3.new(0, TableSpec.releaseLocalY() - carriageLocalY, 0)
end

-- ---------------------------------------------------------------- flippers

-- NO FLIPPERS in the BumperField variant: the user cut them after testing (balls rested
-- on the giant bats). The bottom is fully open and the full-width drain collects
-- everything. The constants below are kept for a future flippered variant; FlipperService
-- finds no bats and idles.
TableSpec.FLIPPER_LENGTH = 22.6
TableSpec.FLIPPER_WIDTH = 2.6
TableSpec.FLIPPER_HEIGHT = 2.0
TableSpec.FLIPPER_PIVOT_Z = -20
TableSpec.FLIPPER_PIVOT_SPREAD = 23.2
TableSpec.FLIPPER_Y = 1.2

TableSpec.FLIPPER_HOME_DEG = 18
TableSpec.FLIPPER_ACTIVE_DEG = 28

function TableSpec.flipperPivotLocal(side: number): Vector3
	return Vector3.new(TableSpec.PF_CENTRE_X + side * TableSpec.FLIPPER_PIVOT_SPREAD,
		TableSpec.FLIPPER_Y, TableSpec.FLIPPER_PIVOT_Z)
end

function TableSpec.flipperAngle(side: number, active: boolean): number
	local magnitude = active and TableSpec.FLIPPER_ACTIVE_DEG or -TableSpec.FLIPPER_HOME_DEG
	if side < 0 then
		return magnitude
	end
	return 180 - magnitude
end

function TableSpec.flipperTipLocal(side: number, active: boolean): Vector3
	local pivot = TableSpec.flipperPivotLocal(side)
	local a = math.rad(TableSpec.flipperAngle(side, active))
	return Vector3.new(pivot.X + math.cos(a) * TableSpec.FLIPPER_LENGTH, pivot.Y,
		pivot.Z + math.sin(a) * TableSpec.FLIPPER_LENGTH)
end

function TableSpec.flipperRestGap(): number
	return TableSpec.flipperTipLocal(1, false).X - TableSpec.flipperTipLocal(-1, false).X
end

function TableSpec.flipperSweepRadius(): number
	return TableSpec.FLIPPER_LENGTH + TableSpec.FLIPPER_WIDTH / 2
end

-- ---------------------------------------------------------------- drain / return / saver

-- No BallReturn in this variant. There is no lane and no plunger to return a ball TO, and
-- its housing sat in the middle of the multiplier slots. Removing the constants with the
-- geometry: a name that points at a part which no longer exists is how the DrainSensor
-- collision went unnoticed once already.
TableSpec.DRAIN_Z = -33
TableSpec.DRAIN_WIDTH = 48
TableSpec.SAVER_Z = -29
TableSpec.SAVER_WIDTH = 9

function TableSpec.drainLocal(): Vector3
	return Vector3.new(TableSpec.PF_CENTRE_X, TableSpec.FLIPPER_Y + 0.8, TableSpec.DRAIN_Z)
end

-- The drain sensor spans the whole play volume, floor to glass. Now that bumper kicks
-- carry lift a ball can be airborne when it reaches the bottom, and a sensor that only
-- covered the rolling plane would let it sail over the drain and rattle off the front wall.
function TableSpec.drainSensorSpan(): (number, number)
	return -2.6, TableSpec.bouncePlateBottom()
end

function TableSpec.saverLocal(): Vector3
	return Vector3.new(TableSpec.PF_CENTRE_X, TableSpec.FLIPPER_Y + 0.6, TableSpec.SAVER_Z)
end

-- ---------------------------------------------------------------- multiplier zones

-- The open bottom is divided into flush multiplier slots. Each ball BANKS the points it
-- earns from bumper hits; the slot it drains through multiplies the delivered bank.
-- The VALUES come from Rewards; this file only decides where the band sits.
TableSpec.MULTIPLIER_SLOTS = Rewards.SLOTS
-- The slots tile the bottom EDGE TO EDGE with no gaps and no margin at the side walls:
-- X runs the full interior width and each pad is exactly one seventh of it. Anything less
-- left bare strips between the pads and against the walls.
TableSpec.SLOT_Z_MIN = -33.5
TableSpec.SLOT_Z_MAX = -21.5
TableSpec.SLOT_X_MIN = TableSpec.INNER_X_MIN
TableSpec.SLOT_X_MAX = TableSpec.INNER_X_MAX

function TableSpec.slotCount(): number
	return #TableSpec.MULTIPLIER_SLOTS
end

-- One derivation of the pad geometry, shared by the builder and by slotAt, so what the
-- player sees and what the payout uses can never drift apart.
function TableSpec.slotWidth(): number
	return (TableSpec.SLOT_X_MAX - TableSpec.SLOT_X_MIN) / TableSpec.slotCount()
end

function TableSpec.slotCentreX(index: number): number
	return TableSpec.SLOT_X_MIN + TableSpec.slotWidth() * (index - 0.5)
end

function TableSpec.slotAt(localX: number): number
	local n = TableSpec.slotCount()
	local span = TableSpec.SLOT_X_MAX - TableSpec.SLOT_X_MIN
	local i = math.floor((localX - TableSpec.SLOT_X_MIN) / span * n) + 1
	return TableSpec.MULTIPLIER_SLOTS[math.clamp(i, 1, n)].mult
end

-- ---------------------------------------------------------------- mechanisms (symmetric)

-- BUMPER FIELD: the user's direction is a machine that is mostly bouncers, like the
-- reference screenshot's fat pop bumpers. 14 of them in a staggered grid. Centre spacing
-- is 8 within rows and ~8.9 diagonally, so every corridor is ~2.8 studs -- wider than the
-- ball with margin. Big cylinders, not pins: this is a bumper field, not pachinko.
TableSpec.BUMPER_RADIUS = 2.6
-- The white skirt is 1.5x the body, and it is the SKIRT -- not the body -- that reads as
-- the bumper's edge. Laying the field out on the body radius is what pushed the outer
-- skirts 0.5 studs straight through the side wall.
TableSpec.BUMPER_RING_SCALE = 1.5
-- Visible gap left between the outermost skirt and the inner wall face.
TableSpec.BUMPER_WALL_CLEARANCE = 1.0

function TableSpec.bumperFootprintRadius(): number
	return TableSpec.BUMPER_RADIUS * TableSpec.BUMPER_RING_SCALE
end

-- Furthest a bumper centre may sit and still leave its whole skirt inside the field.
function TableSpec.bumperMaxX(): number
	return TableSpec.INNER_X_MAX - TableSpec.bumperFootprintRadius()
		- TableSpec.BUMPER_WALL_CLEARANCE
end

TableSpec.BUMPERS = {}
do
	local COLOURS = {
		Color3.fromRGB(58, 190, 186),   -- teal
		Color3.fromRGB(240, 110, 36),   -- orange
		Color3.fromRGB(246, 200, 68),   -- gold
		Color3.fromRGB(236, 240, 244),  -- white
		Color3.fromRGB(232, 106, 168),  -- pink
		Color3.fromRGB(138, 104, 220),  -- purple
	}

	-- HORIZONTAL: a wide row spans -bumperMaxX..+bumperMaxX in equal steps; a narrow row sits
	-- on the half-step offsets between them. Both are symmetric about x = 0 and evenly spaced
	-- by construction, and every skirt clears the wall by BUMPER_WALL_CLEARANCE.
	local maxX = TableSpec.bumperMaxX()
	local WIDE = 4
	local step = (maxX * 2) / (WIDE - 1)
	local wide, narrow = {}, {}
	for i = 0, WIDE - 1 do
		table.insert(wide, -maxX + step * i)
	end
	for i = 0, WIDE - 2 do
		table.insert(narrow, -maxX + step * (i + 0.5))
	end

	-- VERTICAL: five rows spread evenly across the LENGTHENED field. The top row clears the
	-- carriage's swept body and the bottom row clears the multiplier band, each by a full
	-- skirt plus margin, so the spacing is a property of the field's length rather than
	-- something eyeballed.
	local ring = TableSpec.bumperFootprintRadius()
	local topZ = TableSpec.DROPPER_Z - 2.9 - ring - 1.8
	local bottomZ = TableSpec.SLOT_Z_MAX + ring + 1.6
	local ROWS = 5
	local gap = (topZ - bottomZ) / (ROWS - 1)

	local n = 0
	for r = 0, ROWS - 1 do
		local z = topZ - gap * r
		local xs = (r % 2 == 0) and narrow or wide
		for _, x in ipairs(xs) do
			n += 1
			local id = ("POP_%02d"):format(n)
			table.insert(TableSpec.BUMPERS, {
				id = id,
				x = x, z = z, radius = TableSpec.BUMPER_RADIUS,
				colour = COLOURS[(n - 1) % #COLOURS + 1],
				-- Payout read from Rewards, and re-stamped onto the built parts by ScoreService
				-- at startup, so retuning it never needs a rebuild.
				score = Rewards.bumperScore(id, x == 0),
				cooldown = Rewards.BUMPER_HIT_COOLDOWN,
				style = "pop",
			})
		end
	end
end

-- Slim rails on the side walls, set between the rows. Giving every skirt real clearance
-- leaves a lane wider than a ball between the outer bumpers and the wall; these break it up
-- so nothing can run the length of the table untouched. A bumper cannot do that job and
-- keep its skirt inside the field at the same time -- the skirt overhangs the body by 1.3
-- studs and the lane has to be under 1.5 to stop a ball.
-- ANGLED, not square. A blunt block facing up-slope is a dam: gravity pulls the ball into
-- its uphill face and holds it there, which measured as a 17.4 s dwell against the guide at
-- z 15. Each guide instead runs from flush-with-the-wall at its top edge to PROTRUSION at
-- its bottom edge, so a descending ball meets a narrowing channel and is steered inward
-- with no face for it to rest against. The step back to the wall at the bottom edge faces
-- down-slope, where a descending ball cannot catch on it.
TableSpec.SIDE_RAIL_PROTRUSION = 1.2
TableSpec.SIDE_RAIL_THICKNESS = 1.4
-- Kept under twice the gap from a guide to the neighbouring row's skirt edge (2.34), so a
-- guide never intersects a bumper skirt.
TableSpec.SIDE_RAIL_LENGTH = 4

function TableSpec.sideRailZs(): { number }
	local seen, sorted = {}, {}
	for _, b in ipairs(TableSpec.BUMPERS) do
		if not seen[b.z] then seen[b.z] = true; table.insert(sorted, b.z) end
	end
	table.sort(sorted, function(a, b) return a > b end)
	local zs = {}
	for i = 1, #sorted - 1 do
		table.insert(zs, (sorted[i] + sorted[i + 1]) / 2)
	end
	return zs
end

TableSpec.BUMPER_HEIGHT = 3.4

-- No slingshots: they sat inside the giant flippers' swept volume.
TableSpec.SLINGSHOTS = {}
TableSpec.SLINGSHOT_HEIGHT = 2.8

-- No posts in the bumper-field variant: bouncers do all the work.
TableSpec.POSTS = {}
TableSpec.POST_RADIUS = 0.8
TableSpec.POST_HEIGHT = 2.8

-- ---------------------------------------------------------------- scoring furniture

-- No rollovers / spinners / drop targets in this variant.
TableSpec.ROLLOVERS = {}
TableSpec.ROLLOVER_WIDTH = 3.6

TableSpec.SPINNERS = {}

TableSpec.TARGET_BANKS = {}
TableSpec.TARGET_SIZE = Vector3.new(1.3, 2.4, 2.8)

-- ---------------------------------------------------------------- plates / sockets

TableSpec.PLATES = {
	{ id = "PLATE_BONUS_BUMPER", x = -13, z = -3, size = Vector3.new(5.5, 0.2, 5.5) },
	{ id = "PLATE_RAISED_RAMP", x = 13, z = -3, size = Vector3.new(5.5, 0.2, 5.5) },
	{ id = "PLATE_MULTIBALL_FEEDER", x = 0, z = -11, size = Vector3.new(5.5, 0.2, 5.5) },
}

TableSpec.SOCKETS = {
	{ id = "SOCKET_BACK", x = 0, y = 0, z = 40, size = Vector3.new(40, 10, 14) },
	{ id = "SOCKET_LEFT", x = -34, y = 0, z = 0, size = Vector3.new(14, 10, 40) },
	{ id = "SOCKET_RIGHT", x = 34, y = 0, z = 0, size = Vector3.new(14, 10, 40) },
	{ id = "SOCKET_UPPER", x = 0, y = 13, z = 14, size = Vector3.new(30, 10, 26) },
}

-- ---------------------------------------------------------------- camera

TableSpec.CAMERA_FOV = 42
-- Slack on top of the camera's TIGHTEST fit to the gameplay framing target, applied by
-- CameraRig. 1.0 draws the machine as large as it can be without clipping that target;
-- above 1.0 pulls back. This is no longer a fudge factor standing in for the framing --
-- CameraRig searches the real viewport for the distance that fits.
TableSpec.CAMERA_FILL = 1.0
TableSpec.CAMERA_MARGIN = 0
-- Strongly top-down and head on: fills the frame, keeps the backboard's top edge out of
-- shot, and leaves the left/right gutters free for UI.
TableSpec.CAMERA_DIRECTION = Vector3.new(0, 0.88, -0.475)

function TableSpec.cameraLookAt(): Vector3
	return TableSpec.toWorldPosition(TableSpec.PF_CENTRE_X, 2, 0)
end

function TableSpec.cameraDistance(): number
	local halfExtent = TableSpec.OUTER_LENGTH * 0.5 + TableSpec.CAMERA_MARGIN
	return (halfExtent / math.tan(math.rad(TableSpec.CAMERA_FOV / 2))) * TableSpec.CAMERA_FILL
end

function TableSpec.cameraPosition(): Vector3
	return TableSpec.cameraLookAt() + TableSpec.CAMERA_DIRECTION.Unit * TableSpec.cameraDistance()
end

function TableSpec.coreBounds(root: Instance?): (Vector3?, Vector3?)
	if not root then
		return nil, nil
	end
	local core = root:FindFirstChild(TableSpec.CORE_FOLDER)
	if not core then
		return nil, nil
	end
	local minV, maxV
	for _, d in ipairs(core:GetDescendants()) do
		if d:IsA("BasePart") then
			local half = d.Size * 0.5
			local lo, hi = d.Position - half, d.Position + half
			if not minV then
				minV, maxV = lo, hi
			else
				minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
				maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
			end
		end
	end
	return minV, maxV
end

-- ---------------------------------------------------------------- camera framing target

-- The gold pieces that form the machine's top edge. The camera frames so that the top of
-- these sits at the top of the viewport, which crops everything behind them.
--
-- The HORIZONTAL BAR sets the frame's top height, not the corner blocks. The blocks stand
-- 0.7 studs proud of the bar, and pinning the frame to them left a 6 px strip of world
-- background showing above the bar between them. Framing on the bar instead trims a couple
-- of pixels off the tops of the blocks, which is invisible at this scale, and puts the bar
-- itself against the top edge.
local TOP_RAIL_BAR = "RimBackCap"
local TOP_RAIL_NAMES = { "RimBackCap", "PillarCap-11", "PillarCap11" }

-- How far in FRONT of the reward strip the frame extends. The cabinet's front lip is
-- allowed to bleed off the bottom edge; the reward strip is not.
TableSpec.FRAME_FRONT_MARGIN = 1.5
-- How far BELOW the playfield surface the frame reaches. The cabinet body and skirt hang
-- lower than this and are deliberately outside the frame.
TableSpec.FRAME_FLOOR_Y = -2.0

-- Fallbacks, used only if the gold rail has not replicated yet. They mirror the built
-- cabinet: the corner caps are 3.0 cubes centred at y 8.8 on the rim line.
local FALLBACK_TOP_Y = 8.5
local FALLBACK_TOP_MARGIN = 1.5

-- The framing VOLUME, in playfield-local space, whose top-back edge is the top of the gold
-- rail. Fitting this box is what puts the rail at the top of the screen: anything behind or
-- above it -- the corner fills' peaks, the backboard, the world background -- falls outside
-- the viewport rather than being framed in.
--
-- Deliberately a volume rather than the union of every part's corners. Fitting the parts
-- meant the topmost thing on screen was whichever piece happened to poke highest, and the
-- rotated corner fills reach further back than the rail does.
function TableSpec.framingBox(root: Instance?): (Vector3, Vector3)
	local topY, topZ, topX = nil, nil, nil
	if root then
		for _, name in ipairs(TOP_RAIL_NAMES) do
			local part = root:FindFirstChild(name, true)
			if part and part:IsA("BasePart") then
				local half = part.Size * 0.5
				for _, sx in ipairs({ -1, 1 }) do
					for _, sy in ipairs({ -1, 1 }) do
						for _, sz in ipairs({ -1, 1 }) do
							local world = (part.CFrame * CFrame.new(half.X * sx, half.Y * sy, half.Z * sz)).Position
							local l = TableSpec.playfieldCFrame():PointToObjectSpace(world)
							-- height comes from the BAR alone; depth and width from all of them
							if name == TOP_RAIL_BAR then
								topY = math.max(topY or -math.huge, l.Y)
							end
							topZ = math.max(topZ or -math.huge, l.Z)
							topX = math.max(topX or 0, math.abs(l.X))
						end
					end
				end
			end
		end
	end
	if not topZ or not topY then
		topY = FALLBACK_TOP_Y
		topZ = TableSpec.INNER_Z_MAX + TableSpec.WALL_THICKNESS + 0.6 + FALLBACK_TOP_MARGIN
		topX = TableSpec.INNER_X_MAX + 3.1
	end
	local minV = Vector3.new(-topX, TableSpec.FRAME_FLOOR_Y, TableSpec.SLOT_Z_MIN - TableSpec.FRAME_FRONT_MARGIN)
	local maxV = Vector3.new(topX, topY, topZ)
	return minV, maxV
end

-- The eight corners of that volume, in world space, which is what the camera fits.
function TableSpec.framingCorners(root: Instance?): { Vector3 }?
	local minV, maxV = TableSpec.framingBox(root)
	local pts = {}
	for _, x in ipairs({ minV.X, maxV.X }) do
		for _, y in ipairs({ minV.Y, maxV.Y }) do
			for _, z in ipairs({ minV.Z, maxV.Z }) do
				table.insert(pts, TableSpec.toWorldPosition(x, y, z))
			end
		end
	end
	return pts
end

function TableSpec.framingCentre(root: Instance?): Vector3?
	local minV, maxV = TableSpec.framingBox(root)
	local mid = (minV + maxV) * 0.5
	return TableSpec.toWorldPosition(mid.X, mid.Y, mid.Z)
end

function TableSpec.cameraFromBounds(root: Instance?): (Vector3, Vector3)
	local minV, maxV = TableSpec.coreBounds(root)
	if minV and maxV then
		local size = maxV - minV
		local centre = (minV + maxV) * 0.5
		local halfExtent = size.Z * 0.5 + TableSpec.CAMERA_MARGIN
		local distance = (halfExtent / math.tan(math.rad(TableSpec.CAMERA_FOV / 2))) * TableSpec.CAMERA_FILL
		return centre + TableSpec.CAMERA_DIRECTION.Unit * distance, centre
	end
	return TableSpec.cameraPosition(), TableSpec.cameraLookAt()
end

-- ---------------------------------------------------------------- resolution helpers

-- Bounds a live ball must stay within, derived from the field rather than hardcoded.
-- These WERE fixed numbers (|z| > 38), which silently deleted every ball the moment the
-- field was lengthened and the carriage began dropping at z 42.5.
TableSpec.BOUNDS_MARGIN_X = 3
TableSpec.BOUNDS_MARGIN_Z = 4
TableSpec.BOUNDS_FLOOR_Y = -3

function TableSpec.isOutOfBounds(localPos: Vector3): boolean
	return math.abs(localPos.X) > TableSpec.INNER_X_MAX + TableSpec.BOUNDS_MARGIN_X
		or localPos.Z > TableSpec.INNER_Z_MAX + TableSpec.BOUNDS_MARGIN_Z
		or localPos.Z < TableSpec.INNER_Z_MIN - TableSpec.BOUNDS_MARGIN_Z
		or localPos.Y < TableSpec.BOUNDS_FLOOR_Y
end

function TableSpec.findRoot(): Instance?
	return workspace:FindFirstChild(TableSpec.ROOT_NAME)
end

function TableSpec.folder(root: Instance?, name: string): Instance?
	if not root then
		return nil
	end
	return root:FindFirstChild(name, true)
end

function TableSpec.ballsFolder(): Instance?
	return TableSpec.folder(TableSpec.findRoot(), TableSpec.BALLS_FOLDER)
end

return TableSpec
