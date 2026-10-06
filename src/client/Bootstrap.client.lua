-- Client entry point.
--
-- Presentation and INTENT only. Outbound remotes carry button presses, stable lookup ids,
-- bounded policy patches, presentation settings and opaque idempotency tokens. Nothing here
-- computes a reward, outcome, price, count, rarity, Rebirth requirement or Token grant.
-- Deleting this whole layer would leave gameplay mechanically identical.
--
-- SETTINGS cross the wire only to persist. The server stores and echoes them and never reads
-- them for gameplay; see the structural guarantee in Net.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Economy = require(Shared:WaitForChild("Economy"))
local TableSpec = require(Shared:WaitForChild("TableSpec"))

local Vide = require(Shared:WaitForChild("Vide"))

local Client = script.Parent
local Ticker = require(Client:WaitForChild("Ticker"))
local UIKit = require(Client:WaitForChild("UIKit"))
local CameraRig = require(Client:WaitForChild("CameraRig"))
local HUD = require(Client:WaitForChild("HUD"))
local Presenter = require(Client:WaitForChild("Presenter"))
local DevPanel = require(Client:WaitForChild("DevPanel"))

-- BEFORE ANY UI IS BUILT. Vide connects its own Heartbeat when it is required; handing frame
-- ownership to the Ticker immediately keeps the client at exactly one per-frame connection
-- and puts Vide's springs behind the same hitch clamp everything else uses.
Ticker.driveVide(Vide)

-- Wait for the Studio-authored table so camera framing derives from its real bounds.
local deadline = os.clock() + 10
while not TableSpec.findRoot() and os.clock() < deadline do
	task.wait(0.1)
end

local netFolder = Net.waitForFolder(15)
if not netFolder then
	warn("[RAFFLE] client: net folder never appeared; presentation inactive")
	CameraRig.start()
	return
end

local stateUpdate = netFolder:WaitForChild(Net.STATE_UPDATE)
local rollResult = netFolder:WaitForChild(Net.ROLL_RESULT)
local scoreEvent = netFolder:WaitForChild(Net.SCORE_EVENT)
local toast = netFolder:WaitForChild(Net.TOAST)
local inventorySync = netFolder:WaitForChild(Net.INVENTORY_SYNC)
local requestRoll = netFolder:WaitForChild(Net.REQUEST_ROLL)
local requestPurchase = netFolder:WaitForChild(Net.REQUEST_PURCHASE)
local setAutoRoll = netFolder:WaitForChild(Net.SET_AUTO_ROLL)
local requestInventory = netFolder:WaitForChild(Net.REQUEST_INVENTORY)
local setVariantPolicy = netFolder:WaitForChild(Net.SET_VARIANT_POLICY)
local requestDropNext = netFolder:WaitForChild(Net.REQUEST_DROP_NEXT)
local claimAchievement = netFolder:WaitForChild(Net.CLAIM_ACHIEVEMENT)
local setSettings = netFolder:WaitForChild(Net.SET_SETTINGS)
local requestRebirth = netFolder:WaitForChild(Net.REQUEST_REBIRTH)

CameraRig.start()
Presenter.start()

local latest = nil
local hud

hud = HUD.start({
	onRoll = function()
		requestRoll:FireServer()
		-- Local acknowledgement only. The server still decides whether the roll happened.
		if hud then
			hud.pulseRoll(Economy.ROLL_COOLDOWN)
		end
	end,
	onPurchase = function(upgradeId, requestToken)
		-- Intent plus an idempotency token. No price, no rank, no outcome.
		requestPurchase:FireServer(upgradeId, requestToken)
	end,
	onSettingsChanged = function(settings)
		Presenter.setSettings(settings)
		-- Reduce Motion also governs UI springs, which the Presenter does not own.
		UIKit.setReducedMotion(settings.reducedMotion)
		-- Sent so they survive the session. The server stores them and never reads them.
		setSettings:FireServer(settings)
	end,
	onToggleAuto = function()
		if latest then
			setAutoRoll:FireServer(not latest.autoRoll)
		end
	end,

	-- INVENTORY INTENT. None of these carries an outcome: the server validates the variant,
	-- normalises the policy and answers through the ordinary sync. Opening the panel asks for
	-- the whole truth; a sync gap asks for it again.
	onRequestInventory = function()
		requestInventory:FireServer()
	end,
	onSetVariantPolicy = function(variantKey, patch)
		setVariantPolicy:FireServer(variantKey, patch)
	end,
	-- BULK, on the same remote and with the same authority. One packet carrying a list, not a
	-- burst of singles: the server's policy cooldown drops everything after the first, so a
	-- burst would apply a bulk action to exactly one variant.
	onSetVariantPolicyMany = function(variantKeys, patch)
		setVariantPolicy:FireServer(variantKeys, patch)
	end,
	onDropNext = function(variantKey)
		requestDropNext:FireServer(variantKey)
	end,

	-- CARRIES AN ID AND NOTHING ELSE. Not a reward, not a progress value, not an unlock --
	-- the server re-derives whether the goal is met and pays from its own config.
	onClaimAchievement = function(achievementId)
		claimAchievement:FireServer(achievementId)
	end,

	-- Opaque token only. The server decides whether the requirement is met and owns every
	-- reset and grant; the client cannot submit any of those values.
	onRebirth = function(requestToken)
		requestRebirth:FireServer(requestToken)
	end,
})

-- APPLIED ONCE, on the first snapshot after joining. The server is the store of record for
-- PERSISTENCE; the client stays authoritative for LIVE presentation. Applying on every push
-- would let a stale echo stamp on a change the player just made, before it round-tripped.
local settingsRestored = false

stateUpdate.OnClientEvent:Connect(function(state)
	latest = state
	if not settingsRestored and state.settings then
		settingsRestored = true
		hud.applySavedSettings(state.settings)
	end
	hud.setState(state)
end)

rollResult.OnClientEvent:Connect(function(reveal)
	hud.setReveal(reveal)
	Presenter.onReveal(reveal)
end)

scoreEvent.OnClientEvent:Connect(function(targetId, points, worldPosition, mutationId)
	Presenter.onScore(targetId, points, worldPosition, mutationId)
end)

toast.OnClientEvent:Connect(function(kind, text)
	hud.toast(kind, text)
end)

-- The panel decides whether a payload is a usable delta or a reason to ask for the whole
-- truth again; the resync request routes back through onRequestInventory above.
inventorySync.OnClientEvent:Connect(function(payload)
	hud.applyInventorySync(payload)
end)

local devPanel = DevPanel.start(netFolder:FindFirstChild(Net.DEV_ACTION), function()
	return latest
end)

-- STUDIO-ONLY MEASUREMENT BRIDGE, mirroring the server's.
--
-- A command-bar context runs in its own Lua VM, so `require` there returns fresh copies and
-- a test driven that way would inspect an empty parallel HUD rather than the one on screen.
-- A BindableFunction crosses into THIS VM, so presentation tests dispatch through it.
--
-- Guarded by IsStudio AND by the DEV panel having been built, which itself only happens when
-- the server created the DEV remote -- i.e. never in production.
if game:GetService("RunService"):IsStudio() and devPanel then
	local Settings = require(Shared:WaitForChild("Settings"))
	local clientBridge = Instance.new("BindableFunction")
	clientBridge.Name = "RaffleDevClientBridge"
	clientBridge.OnInvoke = function(command, a, b)
		if command == "ping" then
			return { ok = true }

		elseif command == "getSettings" then
			return { ok = true, settings = Presenter.settings() }

		elseif command == "setSettings" then
			-- Routed through the PANEL, not straight into the Presenter, so the test exercises
			-- the same path a player's click takes.
			hud.settingsPanel:set(a)
			return { ok = true, settings = Presenter.settings() }

		elseif command == "presenterStats" then
			local stats = {}
			for k, v in pairs(Presenter.stats) do stats[k] = v end
			return { ok = true, stats = stats }

		elseif command == "popupInstances" then
			-- Counted from the DataModel, not from the Presenter's own bookkeeping, so the
			-- "zero instances with Hit Numbers off" claim is checked against reality.
			local folder = workspace:FindFirstChild("RafflePresenterFX")
			local anchors, billboards, labels = 0, 0, 0
			if folder then
				for _, d in ipairs(folder:GetDescendants()) do
					if d:IsA("BasePart") and d.Name == "ScorePopup" then anchors += 1 end
					if d:IsA("BillboardGui") then billboards += 1 end
					if d:IsA("TextLabel") then labels += 1 end
				end
			end
			return { ok = true, folderExists = folder ~= nil,
				anchors = anchors, billboards = billboards, labels = labels,
				reported = Presenter.stats.popupInstances }

		elseif command == "board" then
			if a == "open" then hud.openBoard(true) elseif a == "close" then hud.openBoard(false) end
			return { ok = true, open = hud.boardOpen() }

		elseif command == "settingsPanel" then
			if a == "open" then hud.settingsPanel:setOpen(true)
			elseif a == "close" then hud.settingsPanel:setOpen(false) end
			return { ok = true, open = hud.settingsPanel:isOpen() }

		elseif command == "collection" then
			if a == "open" then hud.openCollection(true)
			elseif a == "close" then hud.openCollection(false) end
			return { ok = true, open = hud.collectionOpen() }

		elseif command == "rebirth" then
			if a == "open" then hud.openRebirth(true)
			elseif a == "close" then hud.openRebirth(false) end
			return { ok = true, open = hud.rebirthOpen() }

		elseif command == "devPanel" then
			if a == "open" then devPanel.setOpen(true) elseif a == "close" then devPanel.setOpen(false) end
			return { ok = true, open = devPanel.isOpen() }

		elseif command == "counts" then
			local gui = 0
			for _, d in ipairs(game:GetService("Players").LocalPlayer.PlayerGui:GetDescendants()) do
				if d:IsA("GuiObject") then gui += 1 end
			end
			local balls = 0
			local root = workspace:FindFirstChild("PinballTable")
			local folder = root and root:FindFirstChild("Balls", true)
			if folder then balls = #folder:GetChildren() end
			return { ok = true, guiObjects = gui, balls = balls,
				totalInstances = #workspace:GetDescendants(),
				luaHeapKb = collectgarbage("count") }

		elseif command == "levels" then
			return { ok = true, order = Settings.EFFECTS_ORDER, hit = Settings.HIT_NUMBERS_ORDER }
		end
		return { ok = false, reason = "unknown command " .. tostring(command) }
	end
	clientBridge.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end
