-- Server-owned ball lifecycle.
--
-- The server creates every ball from an IMMUTABLE DropSnapshot handed over by the inventory,
-- forces network ownership to itself so no client can influence the simulation, stamps the
-- owner and the drop id onto the part, and is the only thing that removes them. Clients never
-- create, move or report balls.
--
-- A ball's identity was decided at ROLL time and its Ball Value multiplier was frozen at
-- RESERVATION time. Nothing here re-decides either: spawn reads the snapshot, it never calls
-- the catalog's selector and never reads a live stat.
--
-- THE DROP ID IS THE LEDGER KEY. Every ball carries the drop id of the reservation that
-- produced it, and settlement is keyed on that id, so a payout and a refund for the same ball
-- can never both happen.
--
-- EVERY BALL IS PHYSICALLY IDENTICAL. Size, density, friction and elasticity come from
-- BallCatalog.PHYSICS for all rarities; only colour and material differ. A rare ball must
-- never behave differently on the table.
--
-- ONE service loop handles every ball: the one-way plate group switch, speed clamping,
-- lifetime, out-of-bounds and stuck detection. There is no per-ball connection.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BallCatalog = require(Shared:WaitForChild("BallCatalog"))
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))

local GameState = require(script.Parent:WaitForChild("GameState"))
local BallInventoryService = require(script.Parent:WaitForChild("BallInventoryService"))

local BallService = {}

BallService.OWNER_ATTR = "OwnerUserId"
BallService.BALL_ATTR = "IsRaffleBall"
BallService.BALL_ID_ATTR = "BallDefinitionId"
BallService.DROP_ID_ATTR = "DropId"
BallService.STABLE_ID_ATTR = "BallId"
BallService.MUTATION_ATTR = "MutationId"

local live: { [BasePart]: any } = {}
local liveCount = 0
local ballsFolder: Instance? = nil
local nextStableId = 0

BallService.onBallRemoved = nil
-- (player, ball, entry, reason) -- reason is "drained" or a cleanup cause.
BallService.onBallSettled = nil

BallService.stats = {
	spawned = 0, drained = 0, expired = 0, outOfBounds = 0,
	disconnected = 0, clamped = 0, unstuck = 0, passedPlate = 0,
}

-- ---------------------------------------------------------------- one-way plate

-- The plate is one-way through COLLISION GROUPS, not scripted repositioning. A ball is
-- created in the falling group, which is non-collidable against the plate, so it drops
-- through the glass; once its whole body is below the underside it switches to the default
-- group and the glass is solid to it from then on.
--
-- The switch is deliberately ONE-WAY. If a ball could be put back into the falling group,
-- a hard kick could push it up through the plate and strand it on top.
local function ensureCollisionGroups()
	for _, name in ipairs({ TableSpec.PLATE_GROUP, TableSpec.BALL_FALLING_GROUP }) do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(
		TableSpec.BALL_FALLING_GROUP, TableSpec.PLATE_GROUP, false)
end

function BallService.activeCount(): number return liveCount end
function BallService.liveBalls() return live end

function BallService.isBall(part: Instance): boolean
	return part:IsA("BasePart") and part:GetAttribute(BallService.BALL_ATTR) == true
end

function BallService.entryOf(part: Instance)
	return live[part]
end

-- The OWNER is carried on the ball itself, so a shared table can never credit the wrong
-- player. Never "the nearest player".
function BallService.ownerOf(part: Instance): Player?
	local entry = live[part]
	return entry and entry.player or nil
end

-- ---------------------------------------------------------------- spawn

-- Creates the physical ball for an already-reserved DropSnapshot.
--
-- ORDER MATTERS AND IS DELIBERATE. Size, colour, material, physical properties, attributes,
-- collision group, CFrame and VELOCITY are all set while the part is still parentless -- it
-- is exposed to simulation exactly once, by the single `Parent` assignment, already fully
-- configured. Nothing is adjusted afterwards from another module, which is how the release
-- velocity used to be applied.
function BallService.spawn(player: Player, snapshot, releaseCFrame: CFrame?, releaseVelocity: Vector3?): BasePart?
	if not ballsFolder or not snapshot then
		return nil
	end
	local definition = BallCatalog.get(snapshot.ballId)
	if not definition then
		warn("[RAFFLE] BallService: drop snapshot names unknown ball " .. tostring(snapshot.ballId))
		return nil
	end

	-- Reserve the active slot BEFORE anything is created, with no yield in between, so a
	-- duplicated call cannot exceed the cap.
	if not GameState.reserveBall(player, PinballTuning.MAX_ACTIVE_BALLS) then
		return nil
	end

	local physics = BallCatalog.PHYSICS
	nextStableId += 1

	local ball = Instance.new("Part")
	ball.Name = "Ball"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(physics.radius * 2, physics.radius * 2, physics.radius * 2)
	ball.Color = definition.colour
	ball.Material = definition.material
	ball.Anchored = false
	ball.CanCollide = true
	ball.CanQuery = true
	ball.CanTouch = true
	ball.CastShadow = false
	ball.TopSurface = Enum.SurfaceType.Smooth
	ball.BottomSurface = Enum.SurfaceType.Smooth
	ball.CustomPhysicalProperties = PhysicalProperties.new(
		physics.density, physics.friction, physics.elasticity, 1, 1)

	ball:SetAttribute(BallService.BALL_ATTR, true)
	ball:SetAttribute(BallService.OWNER_ATTR, snapshot.ownerUserId)
	ball:SetAttribute(BallService.BALL_ID_ATTR, snapshot.ballId)
	ball:SetAttribute(BallService.DROP_ID_ATTR, snapshot.dropId)
	ball:SetAttribute(BallService.STABLE_ID_ATTR, nextStableId)
	-- The mutation travels on the ball too, so presentation reads it from the part rather
	-- than needing a parallel lookup, and it is stamped from the FROZEN snapshot.
	ball:SetAttribute(BallService.MUTATION_ATTR, snapshot.mutationId or "NONE")

	-- Created ABOVE the one-way plate and therefore in the falling group, so the drop
	-- through the glass is a real fall rather than a spawn on the far side of it.
	ball.CollisionGroup = TableSpec.BALL_FALLING_GROUP

	ball.CFrame = releaseCFrame or CFrame.new(TableSpec.dropperPosition(0))
	if releaseVelocity then
		ball.AssemblyLinearVelocity = releaseVelocity
	end

	ball.Parent = ballsFolder
	-- Server keeps ownership unconditionally: no client may influence this simulation.
	pcall(function() ball:SetNetworkOwner(nil) end)

	live[ball] = {
		player = player,
		snapshot = snapshot,
		bank = 0,
		birth = os.clock(),
		lastMove = os.clock(),
		lastPos = ball.Position,
		abovePlate = true,
	}
	liveCount += 1
	BallService.stats.spawned += 1
	return ball
end

-- ---------------------------------------------------------------- bank

function BallService.addBank(ball: BasePart, points: number)
	local entry = live[ball]
	if entry then
		entry.bank += points
	end
end

-- ---------------------------------------------------------------- despawn

-- Settles EXACTLY ONCE, and the INVENTORY owns that guarantee rather than a local flag.
-- The drop id is removed from the reservation table BEFORE anything is paid, so a drain
-- racing a cleanup has exactly one winner and the loser silently does nothing. There is no
-- second "settled" boolean that could drift out of step with the ledger.
local function settle(ball: BasePart, entry, reason: string)
	if not entry.player then
		return
	end
	local inventory = GameState.inventory(entry.player)
	if not inventory then
		return
	end
	if not BallInventoryService.settle(inventory, entry.snapshot.dropId) then
		return
	end
	GameState.touchInventory(entry.player)
	if BallService.onBallSettled then
		BallService.onBallSettled(entry.player, ball, entry, reason)
	end
end

-- A ball whose owner is LEAVING goes back to storage and pays NOTHING. Keyed on the same
-- drop id, and the reservation is deleted first, so a settlement arriving afterwards finds
-- nothing and cannot also pay. That is the terminal-state guard working in both directions.
local function returnToStorage(entry): boolean
	if not entry.player then
		return false
	end
	local inventory = GameState.inventory(entry.player)
	if not inventory then
		return false
	end
	local ok = BallInventoryService.refund(inventory, entry.snapshot.dropId)
	if ok then
		GameState.touchInventory(entry.player)
	end
	return ok
end

local function remove(ball: BasePart, reason: string)
	local entry = live[ball]
	if not entry then
		return
	end
	live[ball] = nil
	liveCount = math.max(0, liveCount - 1)

	-- Cleanup still settles through the documented fallback pad, so a payout is never
	-- silently lost and never silently duplicated. The ONE exception is a leaving player:
	-- their unresolved balls are returned to storage unpaid, because settling a ball the
	-- player will never see drop would be inventing a payout.
	if reason == "disconnected" then
		returnToStorage(entry)
	else
		settle(ball, entry, reason)
	end

	if BallService.onBallRemoved then
		BallService.onBallRemoved(ball)
	end
	if entry.player then
		GameState.releaseBall(entry.player)
		GameState.push(entry.player)
	end
	BallService.stats[reason] = (BallService.stats[reason] or 0) + 1
	ball:Destroy()
end

-- How long a drained ball is left visible after it has settled. The drain sensor fires 9.3
-- studs into the 12-stud multiplier band -- 77% of the way down -- so destroying the part on
-- contact made balls appear to vanish INSIDE the box. This is presentation only: the payout,
-- the settlement and the active-ball slot have all already been released by the time the
-- part is detached, and it can no longer collide, score or be scored against.
local DRAIN_FALLTHROUGH_SECONDS = 0.55
local drainedFolder: Instance? = nil

function BallService.drain(ball: BasePart)
	local entry = live[ball]
	if not entry then
		return
	end
	settle(ball, entry, "drained")

	-- Retire it from every authoritative structure FIRST, then hand the inert part over to
	-- be watched falling. `remove` would destroy it immediately, so the bookkeeping is done
	-- here and the Destroy is deferred.
	live[ball] = nil
	liveCount = math.max(0, liveCount - 1)
	if BallService.onBallRemoved then
		BallService.onBallRemoved(ball)
	end
	if entry.player then
		GameState.releaseBall(entry.player)
		GameState.push(entry.player)
	end
	BallService.stats.drained = (BallService.stats.drained or 0) + 1

	ball.CanCollide = false
	ball.CanTouch = false
	ball.CanQuery = false
	ball:SetAttribute(BallService.BALL_ATTR, false)
	if drainedFolder then
		ball.Parent = drainedFolder
	end
	game:GetService("Debris"):AddItem(ball, DRAIN_FALLTHROUGH_SECONDS)
end

function BallService.removeAll()
	for ball in pairs(live) do
		remove(ball, "drained")
	end
end

-- Every live ball belonging to a leaving player. Their visuals are destroyed and the balls
-- are RETURNED TO STORAGE without payout -- see `remove`.
function BallService.removeAllOwnedBy(player: Player)
	for ball, entry in pairs(live) do
		if entry.player == player then
			remove(ball, "disconnected")
		end
	end
end

-- ---------------------------------------------------------------- service loop

local function serviceStep()
	local now = os.clock()
	local maxSpeed = PinballTuning.BALL_MAX_SPEED
	local plateClearY = TableSpec.plateClearY()
	local frame = TableSpec.playfieldCFrame()

	for ball, entry in pairs(live) do
		if not ball.Parent then
			remove(ball, "outOfBounds")
		else
			local lp = frame:PointToObjectSpace(ball.Position)

			-- Once the whole ball is under the glass it becomes solid against it, and stays
			-- solid. Switching only when it is fully clear keeps the change out of an
			-- overlap, which would otherwise eject the ball.
			if entry.abovePlate and lp.Y < plateClearY then
				ball.CollisionGroup = "Default"
				entry.abovePlate = false
				BallService.stats.passedPlate += 1
			end

			local v = ball.AssemblyLinearVelocity
			if v.Magnitude > maxSpeed then
				ball.AssemblyLinearVelocity = v.Unit * maxSpeed
				BallService.stats.clamped += 1
			end
			-- Angular clamp stops the visual "runaway spinning" a hard bumper hit can cause.
			local av = ball.AssemblyAngularVelocity
			if av.Magnitude > PinballTuning.BALL_MAX_SPIN then
				ball.AssemblyAngularVelocity = av.Unit * (PinballTuning.BALL_MAX_SPIN * 0.6)
			end

			-- Stuck detection: a ball that has barely moved gets a small impulse DOWN-SLOPE,
			-- the direction gravity already wants. Not a teleport.
			if (ball.Position - entry.lastPos).Magnitude > PinballTuning.STUCK_DISTANCE then
				entry.lastPos = ball.Position
				entry.lastMove = now
			elseif now - entry.lastMove > PinballTuning.STUCK_SECONDS then
				local down = frame:VectorToWorldSpace(Vector3.new(0, 0, -1))
				ball.AssemblyLinearVelocity = ball.AssemblyLinearVelocity + down * PinballTuning.STUCK_NUDGE
				entry.lastMove = now
				entry.lastPos = ball.Position
				BallService.stats.unstuck += 1
			end

			if ball.Position.Y < PinballTuning.BALL_OUT_OF_BOUNDS_Y or TableSpec.isOutOfBounds(lp) then
				remove(ball, "outOfBounds")
			elseif now - entry.birth > PinballTuning.BALL_LIFETIME then
				remove(ball, "expired")
			end
		end
	end
end

function BallService.start(root: Instance)
	ensureCollisionGroups()
	local plate = TableSpec.folder(root, TableSpec.BOUNCE_PLATE)
	if plate and plate:IsA("BasePart") then
		plate.CollisionGroup = TableSpec.PLATE_GROUP
	else
		warn("[RAFFLE] BallService: bounce plate not found; balls will fall to the field with no glass")
	end

	-- Somewhere inert for balls that have settled and are just falling out of frame, so they
	-- are never confused with live balls by anything counting the Balls folder.
	local drained = root:FindFirstChild("DrainedBalls")
	if not drained then
		drained = Instance.new("Folder")
		drained.Name = "DrainedBalls"
		drained.Parent = root
	end
	drainedFolder = drained

	ballsFolder = TableSpec.folder(root, TableSpec.BALLS_FOLDER)
	if not ballsFolder then
		local folder = Instance.new("Folder")
		folder.Name = TableSpec.BALLS_FOLDER
		folder.Parent = root
		ballsFolder = folder
	end

	local drain = TableSpec.folder(root, TableSpec.DRAIN_NAME)
	if drain and drain:IsA("BasePart") then
		drain.Touched:Connect(function(hit)
			if live[hit] then
				BallService.drain(hit)
			end
		end)
	else
		warn("[RAFFLE] BallService: drain sensor not found; relying on bounds fallback")
	end

	task.spawn(function()
		local interval = 1 / PinballTuning.SERVICE_HZ
		while true do
			task.wait(interval)
			serviceStep()
		end
	end)
end

return BallService
