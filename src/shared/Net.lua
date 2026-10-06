--!strict
-- Single registry for every remote in the game. Keeping the surface here means the attack
-- surface is auditable in one place.
--
-- Remotes are CREATED BY THE SERVER at runtime (Net.buildServer) rather than being
-- Studio-authored, so no stray instances end up baked into the place file.
--
-- WHAT THE CLIENT MAY SEND, in full:
--
--   RequestRoll       ()                        -- "I pressed Roll"
--   RequestPurchase   (upgradeId, requestToken) -- "I want to buy this upgrade"
--   SetAutoRoll       (enabled)                 -- "turn Auto Roll on/off"
--   RequestInventory  ()                        -- "I opened Collection, send me everything"
--   SetVariantPolicy  (variantKey|keys, patch)  -- "auto-feed / hold / favourite / reserve"
--   RequestDropNext   (variantKey)              -- "drop one of these next"
--   SetSettings       (settings)                -- "remember my presentation choices"
--   ClaimAchievement  (achievementId)           -- "pay me for the one I finished"
--   RequestRebirth    (requestToken)             -- "rebirth if the server says I can"
--
-- That is the entire inbound gameplay surface, and none of it carries an OUTCOME. The
-- client cannot send a ball identity, a Luck value, a price, a reward, a count, a
-- mutation, a drop order or a drain multiplier; the server derives every one of those
-- from its own state. A client that lies can only ask for something it is not allowed to
-- have, and be refused.
--
-- THE THREE INVENTORY REMOTES CARRY INTENT ONLY, and this is worth being explicit about
-- because they are the first ones that name a specific item:
--
--   * `variantKey` is a LOOKUP KEY, not a quantity and not a value. The server validates it
--     against the catalog and refuses anything unknown. It can never be used to conjure a
--     ball -- only to point at one the player already owns.
--   * `patch` is four booleans and a reserve number, normalised server-side through
--     FeedPolicy. A malformed or hostile patch coerces to a legal policy; it cannot make a
--     protected variant feedable without the player's own instruction.
--   * SetVariantPolicy also accepts a LIST of variant keys in place of one, so a bulk edit is
--     a single packet. This widens the payload but not the authority: every key in the list
--     goes through exactly the same catalog validation as a single key, the patch is
--     normalised once, and the list is truncated at Economy.MAX_POLICY_BATCH. A list of
--     garbage applies the readable entries and silently drops the rest, which is the same
--     outcome as sending them one at a time.
--   * RequestDropNext sets ONE pending slot. It decrements nothing -- the inventory is only
--     touched when a physical slot actually opens -- so spamming it costs the player nothing
--     and gains an attacker nothing.
--
-- `requestToken` is an opaque idempotency string, not an outcome: the server uses it only to
-- recognise a retransmission of the same intent and refuse to charge twice. Forging one can
-- only suppress the forger's own next purchase.
--
-- SETTINGS DO CROSS NOW, AND THE RULE CHANGED WITH THEM (2026-09-02).
--
-- Hit Numbers, Effects, Reduced Motion and Sound used to have no remote at all, which made it
-- STRUCTURALLY impossible for them to affect gameplay: the server could not know them. They
-- are persisted now, so the client sends them -- and the guarantee has to be restated rather
-- than quietly dropped.
--
-- THE SERVER STORES THEM AND NEVER READS THEM. They are written to the profile and echoed
-- back once on join, and no server module outside that path may branch on a settings value.
-- The purpose of the old rule survives; only the mechanism changed.
--
-- The payload is four presentation values, normalised server-side through Settings.normalise:
-- an unreadable or hostile one coerces to a default. It carries no outcome and touches no
-- RNG, physics, payout or instance count.
--
-- DevAction is created ONLY in Studio and is the sole path to forced results.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

Net.FOLDER = "RaffleNet"

-- server -> client. Full per-player snapshot; see GameState.snapshot.
Net.STATE_UPDATE = "StateUpdate"

-- server -> client. (reveal: table) The result of one roll, for the reveal animation.
Net.ROLL_RESULT = "RollResult"

-- server -> client. (targetId: string, points: number, worldPosition: Vector3,
--                    mutationId: string?)
-- Presentation only: the award already happened server-side.
Net.SCORE_EVENT = "ScoreEvent"

-- server -> client. (kind: string, text: string) Short floating message.
Net.TOAST = "Toast"

-- server -> client. (payload: table) The player's own inventory, either a FULL revisioned
-- snapshot or a bounded revisioned delta. See InventoryReplicator for the shape and for why
-- it is coalesced rather than fired per roll.
Net.INVENTORY_SYNC = "InventorySync"

-- client -> server.
Net.REQUEST_ROLL = "RequestRoll"
Net.REQUEST_PURCHASE = "RequestPurchase"
Net.SET_AUTO_ROLL = "SetAutoRoll"

-- client -> server. Inventory intent. See the header for why these carry no outcome.
Net.REQUEST_INVENTORY = "RequestInventory"
Net.SET_VARIANT_POLICY = "SetVariantPolicy"
Net.REQUEST_DROP_NEXT = "RequestDropNext"

-- client -> server. Presentation only; stored, never read for gameplay.
Net.SET_SETTINGS = "SetSettings"

-- client -> server. (achievementId: string) Carries an ID and nothing else -- not a reward,
-- not a progress value, not an unlock. The server re-derives whether it is met from its own
-- state and pays the amount from its own config, so the worst a forged packet achieves is to
-- ask for something already claimed and be refused.
Net.CLAIM_ACHIEVEMENT = "ClaimAchievement"

-- client -> server. An opaque idempotency token only. The server owns the requirement,
-- reset, Token reward, Luck bonus and resulting count.
Net.REQUEST_REBIRTH = "RequestRebirth"

-- client -> server, STUDIO ONLY. (action: string, value: any)
Net.DEV_ACTION = "DevAction"

Net.SERVER_TO_CLIENT = {
	Net.STATE_UPDATE, Net.ROLL_RESULT, Net.SCORE_EVENT, Net.TOAST, Net.INVENTORY_SYNC,
}
Net.CLIENT_TO_SERVER = {
	Net.REQUEST_ROLL, Net.REQUEST_PURCHASE, Net.SET_AUTO_ROLL,
	Net.REQUEST_INVENTORY, Net.SET_VARIANT_POLICY, Net.REQUEST_DROP_NEXT,
	Net.SET_SETTINGS, Net.CLAIM_ACHIEVEMENT, Net.REQUEST_REBIRTH,
}

-- The decision recorded above was taken on 2026-09-02: settings are persisted, and the
-- invariant was rewritten rather than abandoned.

-- Called once by the server. `includeDev` must only ever be true in Studio.
function Net.buildServer(includeDev: boolean): Folder
	local existing = ReplicatedStorage:FindFirstChild(Net.FOLDER)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = Net.FOLDER

	local names = {}
	for _, name in ipairs(Net.SERVER_TO_CLIENT) do
		table.insert(names, name)
	end
	for _, name in ipairs(Net.CLIENT_TO_SERVER) do
		table.insert(names, name)
	end
	if includeDev then
		table.insert(names, Net.DEV_ACTION)
	end

	for _, name in ipairs(names) do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end

	folder.Parent = ReplicatedStorage
	return folder
end

function Net.waitForFolder(timeout: number?): Folder?
	local deadline = os.clock() + (timeout or 10)
	while os.clock() < deadline do
		local folder = ReplicatedStorage:FindFirstChild(Net.FOLDER)
		if folder and folder:IsA("Folder") then
			return folder
		end
		task.wait(0.05)
	end
	return nil
end

return Net
