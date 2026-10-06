-- The dropper carriage.
--
-- A container that tracks left and right along the top of the table and releases balls as
-- it goes. It replaces the launch lane, plunger, return rail and exit wheel outright.
--
-- Why: every one of those was a clog source. A ball that could not carry itself through
-- the lane and around the return simply rolled back and sat there; across three 80 s soaks
-- the lane held 49%, 65% and 70% of all ball-samples, with single balls stuck up to 43
-- seconds. A moving drop point cannot clog, and because the carriage is somewhere
-- different on each release, entry position varies with no scripted randomisation and no
-- invisible steering.
--
-- The carriage is anchored and driven by CFrame. It is a machine part on a rail, not a
-- physics body, so it cannot be knocked out of alignment by a ball.
--
-- ---------------------------------------------------------------------------------------
-- STAGE 2.1: three structural fixes to how balls leave it.
--
-- 1. ONE SCHEDULER. The carriage used to be posed on its own `task.wait(1/30)` loop while
--    the feed ran on a separate `task.wait(1/20)` loop. Release POSITION was read back off
--    `carriage.Position` (last posed value) while release VELOCITY was derived from `phase`
--    (already advanced) -- two clocks, and near a turnaround they disagreed about which way
--    the carriage was even going. Both now run on Heartbeat, and `pose()` publishes one
--    immutable snapshot per frame that the feed reads.
--
-- 2. ONE RELEASE POINT. A `BallRelease` Attachment is created under the carriage at runtime
--    and every release derives its CFrame from that attachment's WorldCFrame. Not from the
--    spec, not from three constants added together, and not from the carriage's centre.
--    (Runtime-only: it is created on start and never saved into the place.)
--
-- 3. NO INSTANT REVERSAL. The sweep is a cosine-blended trapezoid instead of a triangle, so
--    carriage velocity eases to exactly zero at each turnaround instead of flipping sign in
--    one frame. Position and velocity come out of the SAME closed-form curve in TableSpec.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))
local BallCatalog = require(Shared:WaitForChild("BallCatalog"))

local DropperService = {}

local carriage: BasePart? = nil
local releaseAttachment: Attachment? = nil
local phase = 0

-- The single per-frame snapshot. Everything downstream reads this, never `phase` directly,
-- so nothing can sample a position from one frame and a velocity from another.
local current = {
	phase = 0,
	localX = -TableSpec.DROPPER_TRAVEL,
	localVX = 0,
	tau = 0,
	toTurnaround = 0,
	cframe = CFrame.new(),
	worldVelocity = Vector3.zero,
}

DropperService.stats = { sweeps = 0, blockedReleases = 0, overlapChecks = 0 }

-- Overlap query reused every release rather than rebuilt, and configured once.
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.MaxParts = 8

local function refresh()
	local x, vx, tau, toEnd = TableSpec.dropperSweep(phase)
	current.phase = phase
	current.localX = x
	current.localVX = vx
	current.tau = tau
	current.toTurnaround = toEnd
	current.cframe = TableSpec.toWorld(x, TableSpec.DROPPER_Y, TableSpec.DROPPER_Z)
	current.worldVelocity = TableSpec.playfieldCFrame():VectorToWorldSpace(Vector3.new(vx, 0, 0))
end

-- The immutable pose for this frame.
function DropperService.pose()
	return current
end

function DropperService.localX(): number
	return current.localX
end

-- World-space velocity of the carriage right now, from the same curve as its position.
function DropperService.currentVelocity(): Vector3
	return current.worldVelocity
end

-- ---------------------------------------------------------------- release geometry

-- Where a ball is created, straight off the authoritative attachment. Falls back to the
-- spec path only if the carriage part is missing entirely.
function DropperService.releaseCFrame(): CFrame
	if releaseAttachment then
		return releaseAttachment.WorldCFrame
	end
	return TableSpec.toWorld(current.localX, TableSpec.releaseLocalY(), TableSpec.DROPPER_Z)
end

function DropperService.releasePosition(): Vector3
	return DropperService.releaseCFrame().Position
end

-- The velocity a ball leaves with: a bounded share of the carriage's CURRENT lateral motion
-- (from the same curve that posed it) plus a small downward component so it visibly falls
-- out of the mouth instead of being left behind by a carriage sliding out from under it.
--
-- Both parts are resolved in PLAYFIELD-LOCAL space and converted once, so the "down" here is
-- down the table, not world down.
function DropperService.releaseVelocity(): Vector3
	local frame = TableSpec.playfieldCFrame()
	local lateral = current.localVX * PinballTuning.DROP_INHERIT
	return frame:VectorToWorldSpace(Vector3.new(lateral, -PinballTuning.DROP_DOWN_SPEED, 0))
end

-- Is the release sphere, plus its clearance skin, completely clear of every collider?
--
-- Only the carriage is excluded, because it is CanCollide-false decoration the ball is
-- created inside by design. Balls are deliberately NOT excluded: a previous ball still
-- sitting in the mouth is the single most likely blocker and the exact condition this check
-- exists to catch. The one-way plate is skipped too -- a released ball is in the falling
-- collision group and is not collidable against it, so it cannot be blocked by it.
function DropperService.releaseIsClear(): boolean
	DropperService.stats.overlapChecks += 1
	local exclude = {}
	if carriage then
		table.insert(exclude, carriage)
	end
	overlapParams.FilterDescendantsInstances = exclude

	local radius = BallCatalog.PHYSICS.radius + PinballTuning.RELEASE_SKIN
	local hits = workspace:GetPartBoundsInRadius(DropperService.releasePosition(), radius, overlapParams)
	for _, part in ipairs(hits) do
		if part.CanCollide and part.Name ~= TableSpec.BOUNCE_PLATE then
			return false
		end
	end
	return true
end

-- ---------------------------------------------------------------- instrumentation
--
-- Studio-only measurement of what actually happens at a release, so hopper tuning is done
-- against numbers rather than impressions. Off unless explicitly armed.

DropperService.samples = {}
local recording = false

function DropperService.setRecording(on: boolean)
	recording = on
	if on then
		table.clear(DropperService.samples)
	end
end

function DropperService.isRecording(): boolean
	return recording
end

-- Which part of the sweep a release happened in. Five cohorts, so edge behaviour is
-- reported separately from the cruise rather than averaged away.
function DropperService.cohort(): string
	local travel = TableSpec.DROPPER_TRAVEL
	if current.toTurnaround < travel * 0.12 then
		return current.localX < 0 and "leftTurnaround" or "rightTurnaround"
	end
	if math.abs(current.localX) < travel * 0.25 then
		return "centre"
	end
	return current.localVX > 0 and "travelRight" or "travelLeft"
end

function DropperService.recordRelease(ball: BasePart, clear: boolean)
	if not recording then
		return
	end
	local cf = DropperService.releaseCFrame()
	table.insert(DropperService.samples, {
		t = os.clock(),
		cohort = DropperService.cohort(),
		localX = current.localX,
		localVX = current.localVX,
		toTurnaround = current.toTurnaround,
		outletPos = cf.Position,
		spawnOffset = (ball.Position - cf.Position).Magnitude,
		initialVelocity = ball.AssemblyLinearVelocity,
		networkOwner = "server",
		clearAtSpawn = clear,
		ball = ball,
		peakSpeed = 0,
		firstContactAt = nil,
		firstContact = nil,
	})
end

-- Peak speed over each recorded ball's first 0.25 s, sampled inside this service's own
-- Heartbeat. Walks backwards from the newest sample and stops as soon as it passes the
-- window, so the cost is proportional to the handful of balls currently inside it -- not to
-- the whole recording, and with no per-ball connection.
local function observeRecent()
	if not recording then
		return
	end
	local now = os.clock()
	for i = #DropperService.samples, 1, -1 do
		local sample = DropperService.samples[i]
		local age = now - sample.t
		if age > 0.25 then
			return
		end
		local ball = sample.ball
		if ball and ball.Parent then
			sample.peakSpeed = math.max(sample.peakSpeed, ball.AssemblyLinearVelocity.Magnitude)
		end
	end
end

function DropperService.noteContact(ball: BasePart, otherName: string)
	if not recording then
		return
	end
	for i = #DropperService.samples, 1, -1 do
		local sample = DropperService.samples[i]
		if sample.ball == ball then
			if not sample.firstContactAt then
				sample.firstContactAt = os.clock() - sample.t
				sample.firstContact = otherName
			end
			return
		end
		if os.clock() - sample.t > 1 then
			return
		end
	end
end

-- ---------------------------------------------------------------- motion

local function step(dt: number)
	local before = math.floor(phase)
	phase += dt / PinballTuning.DROPPER_PERIOD
	if math.floor(phase) > before then
		DropperService.stats.sweeps += 1
	end
	refresh()
	if carriage then
		carriage.CFrame = current.cframe
	end
	observeRecent()
end

function DropperService.start(root: Instance)
	local found = TableSpec.folder(root, TableSpec.DROPPER_NAME)
	if found and found:IsA("BasePart") then
		carriage = found

		-- ONE authoritative release point, created at runtime under the real part. Reused if
		-- a previous run already made it, so repeated Play sessions do not stack attachments.
		local existing = found:FindFirstChild(TableSpec.BALL_RELEASE_ATTACHMENT)
		if existing and existing:IsA("Attachment") then
			releaseAttachment = existing
		else
			local attachment = Instance.new("Attachment")
			attachment.Name = TableSpec.BALL_RELEASE_ATTACHMENT
			attachment.Parent = found
			releaseAttachment = attachment
		end
		releaseAttachment.Position = TableSpec.releaseOffsetIn(found)
	else
		warn("[RAFFLE] DropperService: carriage not found; releases will use the spec path")
	end

	refresh()
	if carriage then
		carriage.CFrame = current.cframe
	end

	-- Heartbeat, not task.wait. task.wait(1/30) delivers a variable dt with poor granularity,
	-- which is what made the carriage visibly judder on the client; Heartbeat is the same
	-- clock the physics step runs on and gives a true dt.
	RunService.Heartbeat:Connect(step)
end

return DropperService
