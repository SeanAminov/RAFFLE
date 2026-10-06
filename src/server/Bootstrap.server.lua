-- Server entry point.
--
-- Wires the machine (unchanged) to the economy: rolls that credit a virtual inventory, the
-- hopper that reserves from it, Tickets, upgrades, and the persisted profile behind them.
--
-- INBOUND REMOTES ARE THE ONLY THING A CLIENT CAN TOUCH, and each one carries intent
-- only -- never an outcome. Every handler re-validates against server state and refuses
-- anything it does not like. The DEV remote is created only in Studio.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = ServerScriptService:WaitForChild("Server")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared:WaitForChild("Net"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local AchievementConfig = require(Shared:WaitForChild("AchievementConfig"))
local Economy = require(Shared:WaitForChild("Economy"))
local Settings = require(Shared:WaitForChild("Settings"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))
local PinballTuning = require(Shared:WaitForChild("PinballTuning"))

local GameState = require(Server:WaitForChild("GameState"))
local ProfileService = require(Server:WaitForChild("ProfileService"))
local BallService = require(Server:WaitForChild("BallService"))
local ScoreService = require(Server:WaitForChild("ScoreService"))
local RollService = require(Server:WaitForChild("RollService"))
local UpgradeService = require(Server:WaitForChild("UpgradeService"))
local RebirthService = require(Server:WaitForChild("RebirthService"))
local FlipperService = require(Server:WaitForChild("FlipperService"))
local DropperService = require(Server:WaitForChild("DropperService"))
local FeedService = require(Server:WaitForChild("FeedService"))
local BallInventoryService = require(Server:WaitForChild("BallInventoryService"))
local InventoryReplicator = require(Server:WaitForChild("InventoryReplicator"))
local SlotService = require(Server:WaitForChild("SlotService"))
local EventBus = require(Server:WaitForChild("EventBus"))
local AchievementService = require(Server:WaitForChild("AchievementService"))

local isStudio = RunService:IsStudio()
local netFolder = Net.buildServer(isStudio)

-- Fixed arcade presentation: no avatar, so nothing can walk into frame or fight the
-- scripted camera.
Players.CharacterAutoLoads = false

-- Set from code rather than left as a saved Workspace property, so the value that governs
-- table pace is reviewable in git alongside the tuning it was chosen against.
workspace.Gravity = PinballTuning.GRAVITY

-- Presentation lighting, applied server-side so every client gets the same fixed look.
Lighting.Brightness = PinballTuning.LIGHTING_BRIGHTNESS
Lighting.ExposureCompensation = PinballTuning.LIGHTING_EXPOSURE
Lighting.Ambient = PinballTuning.LIGHTING_AMBIENT
Lighting.OutdoorAmbient = PinballTuning.LIGHTING_OUTDOOR_AMBIENT
Lighting.EnvironmentDiffuseScale = PinballTuning.LIGHTING_ENV_DIFFUSE
Lighting.EnvironmentSpecularScale = PinballTuning.LIGHTING_ENV_SPECULAR
Lighting.GlobalShadows = true

local root = TableSpec.findRoot()
if not root then
	warn("[RAFFLE] " .. TableSpec.ROOT_NAME .. " not found in Workspace; machine inactive")
	return
end

-- Workspace.StreamingEnabled is on and CharacterAutoLoads is off, so a player has NO
-- replication focus: without one the client streams in nothing except models explicitly
-- marked Persistent, and the ground never reaches it.
local focusPart = TableSpec.folder(root, TableSpec.PLAYFIELD_NAME)
local function setReplicationFocus(player: Player)
	if focusPart and focusPart:IsA("BasePart") then
		player.ReplicationFocus = focusPart
	end
end
Players.PlayerAdded:Connect(setReplicationFocus)
for _, player in ipairs(Players:GetPlayers()) do
	setReplicationFocus(player)
end

-- LOAD BEFORE PLAY. The profile is read first and applied to the session record, so no roll,
-- purchase or drop can race the load and be overwritten by it.
--
-- The starter balls are given ONLY to a genuinely new profile. A returning player already
-- owns whatever they stored last session, and topping them up every login would be a slow
-- drip of free inventory.
GameState.onPlayerAdded = function(player)
	local status = ProfileService.load(player)
	if status == "new" then
		RollService.preload(player)
	end
	if ProfileService.isBlocked(player) then
		GameState.toast(player, "reject", "PROGRESS WILL NOT SAVE THIS SESSION")
	end

	-- EVALUATED ON LOAD, not only on events. Progress is derived from lifetime totals, so a
	-- returning player who already meets a newly added achievement unlocks it here rather
	-- than having to roll one more ball to trigger a re-check.
	AchievementService.evaluate(player)
end

-- Any inventory change marks the profile dirty. Nothing writes a DataStore per roll: the
-- autosave loop coalesces whatever accumulated into one jittered write.
GameState.onInventoryChanged = ProfileService.markDirty

-- ---------------------------------------------------------------- the event bridge
--
-- Each producer's single hook is pointed at the bus, and fan-out happens there. This is the
-- ONLY place that knows both a producer's hook and the event it becomes, which is what lets
-- a consumer subscribe without any producer learning its name.
--
-- Producers are deliberately untouched by this: they still raise one hook and know nothing
-- about who listens. See EventBus for why a single slot per producer stopped being enough.

RollService.onBallRolled = function(player, record, credit)
	EventBus.emit(GameEvents.BALL_ROLLED, {
		player = player, record = record, credit = credit,
	})

	-- DISCOVERY IS DERIVED FROM THE ROLL, not emitted independently, so "discovered" can
	-- never disagree with "rolled". credit.firstDiscovery is decided inside the same
	-- non-yielding credit that created the collection entry.
	if credit and credit.firstDiscovery then
		EventBus.emit(GameEvents.BALL_DISCOVERED, {
			player = player, variantKey = record.variantKey, record = record,
		})
	end
	if credit and credit.firstMutationDiscovery then
		EventBus.emit(GameEvents.MUTATION_DISCOVERED, {
			player = player, mutationId = record.mutationId,
			variantKey = record.variantKey, record = record,
		})
	end
end

FeedService.onBallReserved = function(player, snapshot)
	EventBus.emit(GameEvents.BALL_RESERVED, { player = player, snapshot = snapshot })
end

FeedService.onBallActivated = function(player, snapshot, ball)
	EventBus.emit(GameEvents.BALL_ACTIVATED, {
		player = player, snapshot = snapshot, ball = ball,
	})
end

ScoreService.onBumperHit = function(player, targetId, points, ball)
	EventBus.emit(GameEvents.BUMPER_HIT, {
		player = player, targetId = targetId, points = points, ball = ball,
	})
end

ScoreService.onSettled = function(player, snapshot, payout, pad)
	EventBus.emit(GameEvents.BALL_SETTLED, {
		player = player, snapshot = snapshot, payout = payout, pad = pad,
	})
end

UpgradeService.onPurchased = function(player, upgradeId, rank, cost)
	EventBus.emit(GameEvents.UPGRADE_PURCHASED, {
		player = player, upgradeId = upgradeId, rank = rank, cost = cost,
	})
end

RebirthService.onCompleted = function(player, count, tokensGranted)
	EventBus.emit(GameEvents.REBIRTH_COMPLETED, {
		player = player, count = count, tokensGranted = tokensGranted,
	})
end

AchievementService.onUnlocked = function(player, achievementId, definition)
	EventBus.emit(GameEvents.ACHIEVEMENT_UNLOCKED, {
		player = player, achievementId = achievementId, definition = definition,
	})
	GameState.toast(player, "unlock", ("ACHIEVEMENT  %s"):format(definition.displayName))
end

AchievementService.onClaimed = function(player, achievementId, reward)
	EventBus.emit(GameEvents.ACHIEVEMENT_CLAIMED, {
		player = player, achievementId = achievementId, reward = reward,
	})
	ProfileService.markDirty(player)
end

-- The snapshot needs achievements and GameState cannot require the service that computes
-- them (it would be a cycle). Injected here, like onInventoryChanged.
GameState.achievementSnapshot = AchievementService.snapshot

-- Mock in Studio, production only on a real server. ProfileStore refuses production under
-- IsStudio outright, so this cannot select it by mistake.
ProfileService.start()

GameState.start(netFolder)

BallService.start(root)
BallService.onBallRemoved = ScoreService.forgetBall
BallService.onBallSettled = ScoreService.settle

ScoreService.start(root, netFolder)
SlotService.start(root)
FlipperService.start(root)
DropperService.start(root)
RollService.start()
FeedService.start()

-- SUBSCRIBES AFTER the bridge is installed. Order matters only in that the bridge must exist
-- before an event can be emitted; both happen before any player can act.
AchievementService.start()
InventoryReplicator.start(netFolder)

-- Balls belonging to a leaving player are cleaned up rather than left orphaned on a shared
-- table, and their unresolved reservations are RETURNED TO STORAGE unpaid.
--
-- ORDER IS LOAD-BEARING, so this uses GameState's ordered hook rather than a second
-- PlayerRemoving connection. GameState connects to PlayerRemoving first and clears the
-- player's state at the end of its handler; a separate connection here would very likely run
-- AFTER that, find `GameState.inventory(player)` already nil, and silently fail to refund --
-- losing every ball that was in play. The hook runs BEFORE the state is discarded.
GameState.onPlayerRemoving = function(player)
	-- ORDER MATTERS AND IS THE WHOLE POINT OF DOING IT HERE. The balls still on the table are
	-- returned to storage FIRST, then the profile is saved, so those balls are inside the
	-- snapshot that gets written. Saving first would persist a profile that is missing every
	-- ball the player had in play.
	BallService.removeAllOwnedBy(player)
	ProfileService.release(player)
end

-- ---------------------------------------------------------------- inbound remotes

local function connect(name: string, handler)
	local remote = netFolder:FindFirstChild(name)
	if remote and remote:IsA("RemoteEvent") then
		remote.OnServerEvent:Connect(function(player, ...)
			-- Never let a handler error take the connection down with it.
			local ok, err = pcall(handler, player, ...)
			if not ok then
				warn(("[RAFFLE] %s handler failed: %s"):format(name, tostring(err)))
			end
		end)
	end
end

connect(Net.REQUEST_ROLL, function(player)
	local ok, reason = RollService.roll(player)
	if not ok and reason and reason ~= "too fast" then
		GameState.toast(player, "reject", reason)
	end
end)

connect(Net.REQUEST_PURCHASE, function(player, upgradeId, requestToken)
	local ok, reason = UpgradeService.purchase(player, upgradeId, requestToken)
	if ok then
		-- A purchase is significant enough to mark dirty immediately rather than waiting for
		-- an inventory change to do it.
		ProfileService.markDirty(player)
	end
	-- A nil reason means "say nothing": that is what a recognised duplicate packet gets, so
	-- a double-click never produces a spurious rejection toast.
	if not ok and reason then
		GameState.toast(player, "reject", reason)
	end
end)

connect(Net.SET_AUTO_ROLL, function(player, enabled)
	local ok, reason = UpgradeService.setAutoRoll(player, enabled)
	if not ok and reason and reason ~= "Too fast" then
		GameState.toast(player, "reject", reason)
	end
end)

-- ---------------------------------------------------------------- inventory intent
--
-- Three handlers, none of which can create, value or destroy a ball. Each re-validates from
-- scratch: the variant key is checked against the catalog, the policy patch is normalised
-- through FeedPolicy, and every path is rate limited. The worst a forged packet achieves is
-- to be refused.

connect(Net.REQUEST_INVENTORY, function(player)
	local state = GameState.get(player)
	if not state then
		return
	end
	local now = os.clock()
	if now - state.lastInventoryRequest < Economy.INVENTORY_REQUEST_COOLDOWN then
		return
	end
	state.lastInventoryRequest = now
	InventoryReplicator.requestFull(player)
end)

connect(Net.SET_VARIANT_POLICY, function(player, target, patch)
	local state = GameState.get(player)
	if not state then
		return
	end
	local now = os.clock()
	if now - state.lastPolicyEdit < Economy.POLICY_COOLDOWN then
		return
	end
	state.lastPolicyEdit = now

	-- Never trust the shape of an inbound value, let alone its content.
	if type(patch) ~= "table" then
		return
	end

	-- ONE KEY, OR A BOUNDED LIST OF THEM. The list form exists so a bulk edit costs one
	-- packet: N packets in one frame would be thrown away by the cooldown above after the
	-- first, and a bulk action that applied to exactly one variant would be worse than none.
	--
	-- The list widens the payload, NOT the authority. Each entry runs the identical
	-- validation a single key runs, so the loop cannot do anything a run of single calls
	-- could not, and MAX_POLICY_BATCH bounds the work a forged packet can ask for.
	local keys
	if type(target) == "string" then
		keys = { target }
	elseif type(target) == "table" then
		keys = target
	else
		return
	end

	local applied = 0
	local limit = math.min(#keys, Economy.MAX_POLICY_BATCH)
	for index = 1, limit do
		local key = keys[index]
		-- setPolicy validates the key against the catalog and normalises the patch; anything
		-- unreadable falls back to the default for that variant's kind rather than erroring.
		if type(key) == "string" and BallInventoryService.setPolicy(state.inventory, key, patch) then
			applied += 1
		end
	end

	-- ONE touch and ONE dirty mark for the whole batch. Marking per key would queue the same
	-- save several hundred times for a single button press.
	if applied > 0 then
		GameState.touchInventory(player)
		ProfileService.markDirty(player)
	end
end)

connect(Net.SET_SETTINGS, function(player, settings)
	local state = GameState.get(player)
	if not state then
		return
	end
	-- NORMALISED, NOT TRUSTED. Anything unreadable coerces to a default, so a hostile payload
	-- can only ever produce a legal presentation config.
	--
	-- STORED AND NEVER READ. This is the only server line that writes it, and the only other
	-- place it appears is the profile. No gameplay path may branch on a settings value --
	-- that is what preserves the guarantee the old no-remote rule used to give structurally.
	state.settings = Settings.normalise(settings)
	ProfileService.markDirty(player)
end)

connect(Net.CLAIM_ACHIEVEMENT, function(player, achievementId)
	local state = GameState.get(player)
	if not state or type(achievementId) ~= "string" then
		return
	end
	local now = os.clock()
	if now - state.lastClaim < Economy.CLAIM_COOLDOWN then
		return
	end
	state.lastClaim = now

	-- CARRIES AN ID AND NOTHING ELSE. The reward comes from the server's own config and
	-- whether it is met is re-derived from the server's own state, so a forged packet can
	-- only ask for something and be refused. Double-paying is prevented by the claimed flag
	-- being set before the grant, not by this cooldown.
	local ok, reward, reason = AchievementService.claim(player, achievementId)
	if ok then
		local def = AchievementConfig.get(achievementId)
		GameState.toast(player, "reward",
			("+%s  %s"):format(Economy.formatTickets(reward or 0), def and def.displayName or ""))
		ProfileService.markDirty(player)
	elseif reason then
		GameState.toast(player, "reject", reason)
	end
	GameState.push(player)
end)

connect(Net.REQUEST_REBIRTH, function(player, requestToken)
	-- Intent only. The client sends no requirement, Token amount, Luck value or reset list;
	-- RebirthService derives all of it from server state and the shared definition.
	local ok, reason, reward = RebirthService.rebirth(player, requestToken)
	if ok then
		ProfileService.markDirty(player)
		local state = GameState.get(player)
		GameState.toast(player, "rebirth", ("REBIRTH %d  +%d TOKENS")
			:format(state and state.rebirths or 0, reward or 0))
	elseif reason and reason ~= "Too fast" then
		GameState.toast(player, "reject", reason)
	end
	GameState.push(player)
end)

connect(Net.REQUEST_DROP_NEXT, function(player, variantKey)
	local state = GameState.get(player)
	if not state or type(variantKey) ~= "string" then
		return
	end
	-- Decrements nothing. The inventory is only touched when a physical slot opens, so a
	-- request that is never served costs the player nothing.
	local ok, reason = BallInventoryService.requestDropNext(state.inventory, variantKey)
	if not ok and reason then
		GameState.toast(player, "reject", reason)
	end
	GameState.push(player)
end)

-- Steady heartbeat so Ticket totals and the affordable badge stay live without a push on
-- every single bumper contact.
task.spawn(function()
	while true do
		task.wait(0.2)
		GameState.pushAll()
	end
end)

if isStudio then
	local DevTools = require(Server:WaitForChild("DevTools"))
	DevTools.start(netFolder)
end

-- THE VOCABULARY IS CHECKED BEFORE ANYTHING USES IT. An event constant that never made it
-- into GameEvents.ALL produces a channel nobody can subscribe to, which is invisible until
-- someone notices a feature quietly not working.
local eventsOk, eventProblems = GameEvents.validate()
if not eventsOk then
	warn("[RAFFLE] GameEvents is inconsistent: " .. table.concat(eventProblems, "; "))
end

local achievementsOk, achievementProblems = AchievementConfig.validate()
if not achievementsOk then
	warn("[RAFFLE] AchievementConfig is invalid: " .. table.concat(achievementProblems, "; "))
end

-- Events with a PRODUCER but no listener are normal and fine. Reported anyway, because the
-- opposite mistake -- a consumer that silently failed to subscribe -- looks identical from
-- the outside, and a count is the cheapest way to tell them apart.
local wiredEvents = 0
for _, count in pairs(EventBus.wiring()) do
	if count > 0 then
		wiredEvents += 1
	end
end

print(("[RAFFLE] Stage 3 ready (studio=%s) | targets=%s restamped=%s | profiles=%s | events=%d/%d listened | achievements=%d")
	:format(tostring(isStudio), tostring(ScoreService.stats.wiredTargets),
		tostring(ScoreService.stats.restamped), require(Server.ProfileStore).mode(),
		wiredEvents, #GameEvents.ALL, AchievementConfig.count()))
