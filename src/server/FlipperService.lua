-- Automatic flippers, INTERVAL DRIVEN.
--
-- The flippers are deliberately not smart. They do not look for balls, do not aim, and
-- have no trigger regions: each bat simply flaps on its own timer. That is what makes the
-- machine feel like a machine rather than something being played, and it is the hook a
-- later upgrade tunes -- a faster flap rate is a purchase, not a cleverer algorithm.
--
-- The previous build scanned a trigger region per flipper and fired on ball proximity. It
-- fired rarely and at unconvincing moments, so it is gone entirely.
--
-- Timing is a fixed interval plus a small jitter so the two sides do not lock into an
-- obviously mechanical rhythm. Speed and torque stay bounded by the servo, and setting a
-- TARGET ANGLE is idempotent, so nothing can accumulate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))

local FlipperService = {}

local flippers = {}
local rng = Random.new()

FlipperService.stats = { flips = 0, count = 0 }
FlipperService.intervalOverride = nil

-- The single knob a future upgrade turns down.
function FlipperService.interval(): number
	return FlipperService.intervalOverride or PinballTuning.FLIPPER_INTERVAL
end

function FlipperService.setInterval(seconds: number?)
	FlipperService.intervalOverride = seconds
end

local function scheduleNext(entry, now: number)
	local j = PinballTuning.FLIPPER_INTERVAL_JITTER
	entry.nextFlip = now + math.max(0.15, FlipperService.interval() + rng:NextNumber(-j, j))
end

local function fire(entry, now: number)
	entry.hinge.TargetAngle = entry.flipSign * PinballTuning.FLIPPER_FLIP_ANGLE
	entry.returnAt = now + PinballTuning.FLIPPER_HOLD
	FlipperService.stats.flips += 1
end

local function step()
	local now = os.clock()
	for _, entry in ipairs(flippers) do
		if entry.returnAt and now >= entry.returnAt then
			entry.hinge.TargetAngle = PinballTuning.FLIPPER_REST_ANGLE
			entry.returnAt = nil
		end
		if now >= entry.nextFlip then
			fire(entry, now)
			scheduleNext(entry, now)
		end
	end
end

-- Studio-only aid.
function FlipperService.testFlip(sideFilter: number?)
	local now = os.clock()
	for _, entry in ipairs(flippers) do
		if not sideFilter or entry.side == sideFilter then
			fire(entry, now)
		end
	end
end

function FlipperService.tipPositions()
	local t = {}
	for _, entry in ipairs(flippers) do
		-- The pivot is the bat's -X end on BOTH sides, so the tip is always +L/2.
		t[entry.side] = (entry.arm.CFrame * CFrame.new(TableSpec.FLIPPER_LENGTH / 2, 0, 0)).Position
	end
	return t
end

function FlipperService.start(root: Instance)
	local folder = TableSpec.folder(root, TableSpec.FLIPPERS_FOLDER)
	if not folder then
		warn("[RAFFLE] FlipperService: no Flippers folder")
		return
	end

	local now = os.clock()
	for _, arm in ipairs(folder:GetChildren()) do
		if arm:IsA("BasePart") and arm.Name:sub(1, #TableSpec.FLIPPER_PREFIX) == TableSpec.FLIPPER_PREFIX then
			local hinge = arm:FindFirstChildOfClass("HingeConstraint")
			local side = arm:GetAttribute(TableSpec.FLIPPER_SIDE_ATTR)
			if hinge and type(side) == "number" then
				hinge.TargetAngle = PinballTuning.FLIPPER_REST_ANGLE
				local entry = {
					arm = arm,
					hinge = hinge,
					side = side,
					flipSign = arm:GetAttribute("FlipSign") or 1,
					returnAt = nil,
					-- Offset the two sides so they do not flap in lockstep.
					nextFlip = now + (side < 0 and 0.25 or 0.25 + PinballTuning.FLIPPER_INTERVAL * 0.5),
				}
				table.insert(flippers, entry)
			end
		end
	end
	FlipperService.stats.count = #flippers

	task.spawn(function()
		local dt = 1 / PinballTuning.FLIPPER_TICK_HZ
		while true do
			task.wait(dt)
			step()
		end
	end)
end

return FlipperService
