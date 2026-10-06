--!strict
-- Fixed arcade camera.
--
-- No panning, no zoom, no follow, no avatar subject.
--
-- The shot is FITTED to a dedicated gameplay framing target rather than to the model's
-- whole bounding box. Fitting the whole box dragged the decorative backboard behind the
-- gold top rail into shot as a large blue rectangle; the framing target stops at the rail
-- and its two gold corner blocks, so those are the highest machine pieces on screen and
-- anything behind them falls above the top edge.
--
-- The fit is a real search against the LIVE viewport, not a formula: the camera is pushed
-- out until every corner of the framing target is inside the frame, and no further. That
-- keeps the machine as large as it can be at any aspect ratio without cropping the
-- multiplier strip at the bottom.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local TableSpec = require(Shared:WaitForChild("TableSpec"))

local CameraRig = {}

-- Fraction of the viewport kept clear at the tightest fit, on the sides and the bottom.
local FIT_MARGIN = 0.012
-- Clearance above the gold top rail, in pixels, measured from the RAW top of the viewport.
--
-- Deliberately NOT offset by GuiService:GetGuiInset(). The topbar overlays the top of the
-- 3D viewport (58 px here) and reserving room for it pushed the machine down and left the
-- world background showing above the rail. The machine is meant to render behind the
-- CoreGui overlay, so the rail sits against the true top of the frame.
-- Slightly NEGATIVE on purpose: at 0 the rail's top edge landed ~1 px down and left a
-- single row of world background above it. Letting the fit overshoot by a pixel puts the
-- rail's own top row at the very first pixel of the frame, so nothing shows above it. The
-- rail bar is ~17 px tall on screen, so the pixel this trims is not perceptible.
local TOP_CLEARANCE_PX = -1
local SEARCH_NEAR, SEARCH_FAR, SEARCH_STEPS = 20, 700, 34

-- The band the framing volume is fitted into: hard against the top of the viewport, with a
-- small margin at the bottom so the volume's front edge is never clipped. The apron sits
-- forward of the volume and therefore still fills the last few pixels to the bottom edge.
local function usableBand(camera: Camera): (number, number)
	local bottom = camera.ViewportSize.Y - camera.ViewportSize.Y * FIT_MARGIN
	return TOP_CLEARANCE_PX, bottom
end

-- Projected screen extent of the framing target at the camera's current pose.
local function project(camera: Camera, points: { Vector3 })
	local loX, hiX, loY, hiY = math.huge, -math.huge, math.huge, -math.huge
	local behind = false
	for _, p in ipairs(points) do
		local screen = camera:WorldToViewportPoint(p)
		if screen.Z <= 0 then
			behind = true
		end
		loX, hiX = math.min(loX, screen.X), math.max(hiX, screen.X)
		loY, hiY = math.min(loY, screen.Y), math.max(hiY, screen.Y)
	end
	return loX, hiX, loY, hiY, behind
end

local function allInside(camera: Camera, points: { Vector3 }): boolean
	local vp = camera.ViewportSize
	local mx = vp.X * FIT_MARGIN
	local top, bottom = usableBand(camera)
	local loX, hiX, loY, hiY, behind = project(camera, points)
	if behind then
		return false
	end
	return loX >= mx and hiX <= vp.X - mx and loY >= top and hiY <= bottom
end

function CameraRig.apply()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = TableSpec.CAMERA_FOV
	camera.CameraSubject = nil

	local root = TableSpec.findRoot()
	local points = TableSpec.framingCorners(root)
	local centre = TableSpec.framingCentre(root)
	if not points or not centre then
		-- table has not replicated yet; fall back to the spec's own dimensions
		local position, lookAt = TableSpec.cameraFromBounds(root)
		camera.CFrame = CFrame.lookAt(position, lookAt)
		return
	end

	local direction = TableSpec.CAMERA_DIRECTION.Unit
	local vp = camera.ViewportSize

	local function fitDistance(aim: Vector3): number
		local near, far = SEARCH_NEAR, SEARCH_FAR
		camera.CFrame = CFrame.lookAt(aim + direction * far, aim)
		if not allInside(camera, points) then
			return far
		end
		for _ = 1, SEARCH_STEPS do
			local mid = (near + far) * 0.5
			camera.CFrame = CFrame.lookAt(aim + direction * mid, aim)
			if allInside(camera, points) then
				far = mid
			else
				near = mid
			end
		end
		return far
	end

	-- Fitting from the target's 3D centre leaves the shot bottom-heavy: this is a tilted
	-- perspective view, so the near end of the machine projects larger than the far end and
	-- the fit ends up limited by the front rim while slack piles up above the top rail.
	-- Re-aim so the PROJECTED extent is centred, then refit, a few times. That pulls the
	-- gold rail up towards the top edge without ever letting the bottom strip clip.
	local aim = centre
	local distance = fitDistance(aim)
	for _ = 1, 8 do
		camera.CFrame = CFrame.lookAt(aim + direction * distance, aim)
		local _, _, loY, hiY = project(camera, points)
		-- Centre within the USABLE band, not the raw viewport, or the shot ends up pushed
		-- up under the topbar by half the inset.
		local top, bottom = usableBand(camera)
		local offsetPixels = ((loY + hiY) * 0.5) - ((top + bottom) * 0.5)
		if math.abs(offsetPixels) < 0.5 then
			break
		end
		-- Convert a pixel offset into world units at the aim plane. Screen Y grows DOWNWARD,
		-- so a positive offset means the image is sitting too low and the camera has to move
		-- DOWN to lift it. Adding here instead of subtracting made each pass push the image
		-- further down, and the refit then pulled the camera back to compensate -- the two
		-- fought to a stable but badly framed answer with a gap above the rail.
		local worldPerPixel = (2 * distance * math.tan(math.rad(camera.FieldOfView / 2))) / vp.Y
		aim -= camera.CFrame.UpVector * (offsetPixels * worldPerPixel)
		distance = fitDistance(aim)
	end

	-- CAMERA_FILL is slack on top of the tightest fit: 1.0 is as large as the machine can
	-- be drawn without clipping the framing target.
	camera.CFrame = CFrame.lookAt(aim + direction * (distance * TableSpec.CAMERA_FILL), aim)
end

function CameraRig.start()
	CameraRig.apply()

	-- Re-apply when anything that the fit DEPENDS ON changes:
	--
	--   * the viewport size -- the fit is solved against the live viewport, so a shot framed
	--     at one size is wrong at another. This is not hypothetical: the first frame after
	--     Play begins is a different size from the settled window, and framing once at
	--     startup left the camera 10 studs too far back with a visible gap above the rail.
	--   * the framing volume -- the gold rail streams in after the first frame, so the fit
	--     may have been solved against the fallback dimensions.
	--   * the camera type -- Roblox re-asserts the default camera in a few situations.
	--
	-- Coarse polling, so it never needs a per-frame connection.
	task.spawn(function()
		local lastViewport, lastTop
		while true do
			local camera = workspace.CurrentCamera
			if camera then
				local viewport = camera.ViewportSize
				local _, maxV = TableSpec.framingBox(TableSpec.findRoot())
				if camera.CameraType ~= Enum.CameraType.Scriptable
					or viewport ~= lastViewport
					or (lastTop and (maxV - lastTop).Magnitude > 0.01)
				then
					CameraRig.apply()
					lastViewport = camera.ViewportSize
				end
				lastTop = maxV
			end
			task.wait(0.4)
		end
	end)
end

return CameraRig
