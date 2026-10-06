-- Server-authoritative scoring and settlement.
--
-- This service has NO knowledge of any specific target. It reads everything from
-- ATTRIBUTES stamped on the target parts (TargetId / BaseScore / HitCooldown / Enabled /
-- Style), so adding a bumper requires no branch here at all.
--
-- The client cannot participate: there is no inbound scoring remote, hits are detected
-- from server-owned physics bodies, and the event sent to the client is presentation only
-- -- the award has already happened.
--
-- TWO THINGS HAPPEN ON A VALID CONTACT:
--   1. a small immediate Ticket trickle, so the machine always feels like it is paying
--   2. the target's BaseScore is added to that ball's BANK -- raw points, worth nothing
--      until the ball drains
--
-- SETTLEMENT, exactly once per ball:
--     payout = floor(bank * drainPad * ballRarityValue * ballValueUpgrade * mutationValue
--                    * DRAIN_SCALE)
-- with every one of those numbers living in Rewards, except the three carried on the ball's
-- own frozen DropSnapshot (rarity value, mutation value and the Ball Value multiplier frozen
-- at reservation).
-- Each factor is applied exactly once. The INVENTORY owns the exactly-once guarantee: a drop
-- id can reach exactly one terminal state, and this service is simply the callback fired by
-- the transition that won.
--
-- A ball resting against a bumper cannot farm: every award is gated by a PER-BALL,
-- PER-TARGET cooldown, and the kick is gated by the same check, so a ball that cannot
-- score also cannot be re-kicked.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rewards = require(Shared:WaitForChild("Rewards"))
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))
local TargetConfig = require(Shared:WaitForChild("TargetConfig"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))
local Net = require(Shared:WaitForChild("Net"))

local GameState = require(script.Parent:WaitForChild("GameState"))
local BallService = require(script.Parent:WaitForChild("BallService"))

local ScoreService = {}

-- (player, targetId, points, ball) and (player, snapshot, payout, pad). Progression listens
-- here rather than reaching into settlement. Wired by Bootstrap.
ScoreService.onBumperHit = nil
ScoreService.onSettled = nil

-- ball -> { [targetId] = expiryClock }
local cooldowns: { [BasePart]: { [string]: number } } = {}
local remotes: { [string]: RemoteEvent } = {}

local eventWindowStart = 0
local eventsThisWindow = 0

ScoreService.stats = {
	awarded = 0,
	blockedByCooldown = 0,
	blockedDisabled = 0,
	eventsDropped = 0,
	settled = 0,
	settledByFallback = 0,
	ticketsFromHits = 0,
	ticketsFromDrains = 0,
	restamped = 0,
	settledMutated = 0,
}

function ScoreService.forgetBall(ball: BasePart)
	cooldowns[ball] = nil
end

local function canBroadcast(): boolean
	local now = os.clock()
	if now - eventWindowStart >= 1 then
		eventWindowStart = now
		eventsThisWindow = 0
	end
	if eventsThisWindow >= PinballTuning.MAX_SCORE_EVENTS_PER_SEC then
		ScoreService.stats.eventsDropped += 1
		return false
	end
	eventsThisWindow += 1
	return true
end

local function onTargetTouched(target: BasePart, hit: BasePart)
	if not BallService.isBall(hit) then
		return
	end

	if target:GetAttribute(TargetConfig.ATTR_ENABLED) == false then
		ScoreService.stats.blockedDisabled += 1
		return
	end

	local targetId = target:GetAttribute(TargetConfig.ATTR_ID)
	local baseScore = target:GetAttribute(TargetConfig.ATTR_SCORE)
	if type(targetId) ~= "string" or type(baseScore) ~= "number" then
		return
	end

	local cooldown = target:GetAttribute(TargetConfig.ATTR_COOLDOWN)
	if type(cooldown) ~= "number" or cooldown <= 0 then
		cooldown = PinballTuning.DEFAULT_HIT_COOLDOWN
	end

	-- PER-BALL, PER-TARGET debounce. Touched fires many times per physical contact; this
	-- is what stops one contact paying repeatedly.
	local now = os.clock()
	local perBall = cooldowns[hit]
	if not perBall then
		perBall = {}
		cooldowns[hit] = perBall
	end
	local expiry = perBall[targetId]
	if expiry and now < expiry then
		ScoreService.stats.blockedByCooldown += 1
		return
	end
	perBall[targetId] = now + cooldown

	-- Credit the BALL'S OWNER, carried on the ball. Never whoever happens to be nearby.
	local player = BallService.ownerOf(hit)
	if not player then
		return
	end

	local points = math.max(1, math.floor(baseScore))

	-- 1. immediate trickle
	local tickets = GameState.addTickets(player, Rewards.TICKETS_PER_HIT)
	ScoreService.stats.ticketsFromHits += tickets

	-- 2. bank, settled later through a drain pad
	BallService.addBank(hit, points)
	ScoreService.stats.awarded += 1

	-- Lifetime bumper contacts, for progression. Counted from SERVER-OWNED physics AFTER the
	-- per-ball per-target cooldown, so this is a count of real scoring contacts and cannot be
	-- inflated by a ball resting against a bumper.
	local state = GameState.get(player)
	if state then
		state.bumperHits += 1
	end
	if ScoreService.onBumperHit then
		ScoreService.onBumperHit(player, targetId, points, hit)
	end

	-- Kick, applied server-side and clamped. Gated by the SAME cooldown as the award.
	local style = target:GetAttribute(TargetConfig.ATTR_STYLE)
	local kickPower, kickMax, liftHeight = 0, 0, 0
	if style == "pop" then
		kickPower, kickMax = PinballTuning.BUMPER_KICK, PinballTuning.BUMPER_KICK_MAX
		liftHeight = PinballTuning.BUMPER_LIFT_HEIGHT
	elseif style == "sling" then
		kickPower, kickMax = PinballTuning.SLING_KICK, PinballTuning.SLING_KICK_MAX
	end
	if kickPower > 0 then
		-- Resolved in PLAYFIELD-LOCAL space and split in two: a planar push away from the
		-- mechanism, clamped on its own, plus a separate vertical lift. The planar
		-- direction is taken flat because the raw 3D vector from a bumper centre to a
		-- rolling ball points slightly DOWNWARD, into the surface.
		local frame = TableSpec.playfieldCFrame()
		local localAway = frame:VectorToObjectSpace(hit.Position - target.Position)
		local planar = Vector3.new(localAway.X, 0, localAway.Z)
		if planar.Magnitude > 0.05 then
			local velocity = hit.AssemblyLinearVelocity
			local localV = frame:VectorToObjectSpace(velocity)

			local combined = Vector3.new(localV.X, 0, localV.Z) + planar.Unit * kickPower
			if combined.Magnitude > kickMax then
				combined = combined.Unit * kickMax
			end

			local lift = 0
			if liftHeight > 0 then
				-- Converted from a height with the LIVE gravity, so a gravity change cannot
				-- silently stop pops from reaching the glass.
				local full = math.sqrt(2 * workspace.Gravity * liftHeight)
				lift = full * math.clamp(velocity.Magnitude / PinballTuning.BUMPER_LIFT_REF,
					PinballTuning.BUMPER_LIFT_MIN, 1)
			end

			hit.AssemblyLinearVelocity =
				frame:VectorToWorldSpace(Vector3.new(combined.X, lift, combined.Z))
		end
	end

	local remote = remotes[Net.SCORE_EVENT]
	if remote and canBroadcast() then
		remote:FireClient(player, targetId, points, target.Position)
	end
end

-- Called by BallService exactly once per ball. `reason` is "drained" for a real drain, or
-- a cleanup cause (out of bounds, expiry, disconnect).
function ScoreService.settle(player: Player, ball: BasePart, entry, reason: string)
	local bank = entry.bank or 0
	if bank <= 0 then
		return
	end

	local pad
	if reason == "drained" then
		local localX = TableSpec.playfieldCFrame():PointToObjectSpace(ball.Position).X
		pad = TableSpec.slotAt(localX)
	else
		-- Documented fallback: a ball removed by cleanup never reaches a pad, so it
		-- settles through the worst one. Never silently dropped, never duplicated.
		pad = Rewards.FALLBACK_PAD_MULTIPLIER
		ScoreService.stats.settledByFallback += 1
	end

	-- EVERY MULTIPLIER COMES OFF THE FROZEN SNAPSHOT, including Ball Value.
	--
	-- Ball Value used to be read LIVE from the player's current stat, which meant buying an
	-- upgrade while a ball was mid-flight retroactively re-valued it. It is now frozen at
	-- RESERVATION: a ball waiting in storage does gain from a later purchase, but a ball
	-- already on the table is fixed from the moment the hopper claimed it.
	--
	-- Rarity and mutation were fixed earlier still, at roll time. Nothing downstream of the
	-- reservation may consult a live stat, or a payout would depend on when it happened to
	-- be computed.
	local snapshot = entry.snapshot
	local rarity = snapshot and snapshot.baseValue or 1
	local upgrade = snapshot and snapshot.ballValueUpgrade or 1
	local mutation = snapshot and snapshot.mutationMultiplier or 1

	local payout = math.floor(bank * pad * rarity * upgrade * mutation * Rewards.DRAIN_SCALE)
	if payout < Rewards.MIN_DRAIN_PAYOUT then
		payout = Rewards.MIN_DRAIN_PAYOUT
	end
	if payout <= 0 then
		return
	end

	local granted = GameState.addTickets(player, payout)
	-- BEFORE the hook, not after. An achievement listening for the first settle reads the
	-- lifetime count, and a count bumped after the hook would still read zero on the very
	-- settle that should have unlocked it.
	GameState.noteSettled(player)
	if ScoreService.onSettled then
		ScoreService.onSettled(player, snapshot, granted, pad)
	end
	ScoreService.stats.settled += 1
	if mutation > 1 then
		ScoreService.stats.settledMutated += 1
	end
	ScoreService.stats.ticketsFromDrains += granted

	local remote = remotes[Net.SCORE_EVENT]
	if remote and canBroadcast() then
		local mutationId = snapshot and snapshot.mutationId or "NONE"
		remote:FireClient(player, ("DRAIN_x%d"):format(pad), granted, ball.Position, mutationId)
	end
end

function ScoreService.start(root: Instance, netFolder: Folder)
	for _, child in ipairs(netFolder:GetChildren()) do
		if child:IsA("RemoteEvent") then
			remotes[child.Name] = child
		end
	end

	-- RE-STAMP payouts from the spec before wiring, so changing a number in Rewards.lua and
	-- pressing Play is enough and the geometry can never disagree with the config.
	local restamped, missing = 0, {}
	for _, def in ipairs(TableSpec.BUMPERS) do
		local part = root:FindFirstChild(def.id, true)
		if part and part:IsA("BasePart") then
			part:SetAttribute(TargetConfig.ATTR_SCORE, def.score)
			part:SetAttribute(TargetConfig.ATTR_COOLDOWN, def.cooldown)
			restamped += 1
		else
			table.insert(missing, def.id)
		end
	end
	ScoreService.stats.restamped = restamped
	if #missing > 0 then
		warn(("[RAFFLE] ScoreService: %d bumpers in the spec have no part (%s)")
			:format(#missing, table.concat(missing, ", ")))
	end

	-- Wiring is driven by the ATTRIBUTE rather than by any folder path, so a future
	-- mechanism anywhere in the table wires itself.
	local wired = 0
	for _, part in ipairs(root:GetDescendants()) do
		if part:IsA("BasePart") and part:GetAttribute(TargetConfig.ATTR_ID) ~= nil then
			wired += 1
			part.Touched:Connect(function(hit)
				onTargetTouched(part, hit)
			end)
		end
	end
	ScoreService.stats.wiredTargets = wired
	if wired == 0 then
		warn("[RAFFLE] ScoreService: no stamped scoring parts found")
	end
end

return ScoreService
