-- Upgrade purchases. The server is the only thing that may grant a rank.
--
-- The client sends an upgrade ID and nothing else. It cannot send a price, a rank, or a
-- stat value, so the worst a forged request can do is ask for something and be refused.
-- Every purchase is re-validated here from scratch against the server's own state:
-- existence, purchasability, prerequisites, rank cap, price, and request rate.
--
-- Tickets are deducted BEFORE the rank is granted, with no yield in between, so a
-- duplicated request finds the tickets already gone and cannot buy the same rank twice.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
local UpgradeConfig = require(Shared:WaitForChild("UpgradeConfig"))

local GameState = require(script.Parent:WaitForChild("GameState"))

local UpgradeService = {}

-- (player, upgradeId, rank, cost) raised ONLY for a purchase that was actually paid for.
-- `rank` is the rank after the purchase. Wired by Bootstrap.
UpgradeService.onPurchased = nil

UpgradeService.stats = {
	purchased = 0,
	rejectedUnknown = 0,
	rejectedPreview = 0,
	rejectedMaxRank = 0,
	rejectedRequirements = 0,
	rejectedFunds = 0,
	rejectedRate = 0,
	rejectedDuplicate = 0,
}

-- Returns (ok, reason). `reason` is player-facing text on failure; nil means "say nothing",
-- which is what a duplicate packet gets.
--
-- IDEMPOTENCY. `requestToken` is an opaque string the client mints once per deliberate
-- activation and repeats on every retransmission of that same intent. The server remembers
-- the token of the last ACCEPTED purchase and refuses an exact repeat, so a duplicated
-- packet -- or a double-click that reaches the wire twice -- cannot buy two ranks. It
-- deliberately keys off ACCEPTED rather than SEEN, so a genuine retry after a refusal (not
-- enough Tickets, then enough) is never silently swallowed.
--
-- The token is not trusted for anything else. It carries no price, rank or outcome; the
-- worst a forged token can do is suppress the forger's own next purchase.
function UpgradeService.purchase(player: Player, upgradeId: any, requestToken: any): (boolean, string?)
	local state = GameState.get(player)
	if not state then
		return false, "no session"
	end

	-- Never trust the shape of an inbound value, let alone its content.
	if type(upgradeId) ~= "string" then
		UpgradeService.stats.rejectedUnknown += 1
		return false, "Unknown upgrade"
	end

	if type(requestToken) == "string" and #requestToken > 0 and #requestToken <= 64
		and state.lastAcceptedPurchaseToken == requestToken then
		UpgradeService.stats.rejectedDuplicate += 1
		return false, nil
	end

	local now = os.clock()
	if now - state.lastPurchase < Economy.PURCHASE_COOLDOWN then
		UpgradeService.stats.rejectedRate += 1
		return false, "Too fast"
	end
	state.lastPurchase = now

	local upgrade = UpgradeConfig.get(upgradeId)
	if not upgrade then
		UpgradeService.stats.rejectedUnknown += 1
		return false, "Unknown upgrade"
	end
	if upgrade.preview then
		UpgradeService.stats.rejectedPreview += 1
		return false, "Coming soon"
	end

	local rank = state.ranks[upgradeId] or 0
	if rank >= upgrade.maxRank then
		UpgradeService.stats.rejectedMaxRank += 1
		return false, "Already maxed"
	end

	local met, why = UpgradeConfig.requirementsMet(upgradeId, state.ranks)
	if not met then
		UpgradeService.stats.rejectedRequirements += 1
		return false, why
	end

	local cost = UpgradeConfig.costOfNext(upgradeId, rank)
	if not cost then
		UpgradeService.stats.rejectedMaxRank += 1
		return false, "Already maxed"
	end

	-- Consume before granting, no yield between.
	if not GameState.trySpend(player, cost) then
		UpgradeService.stats.rejectedFunds += 1
		return false, ("Need %s %s"):format(Economy.formatTickets(cost), Economy.CURRENCY_NAME)
	end

	state.ranks[upgradeId] = rank + 1
	if type(requestToken) == "string" and #requestToken > 0 and #requestToken <= 64 then
		state.lastAcceptedPurchaseToken = requestToken
	end
	UpgradeService.stats.purchased += 1

	-- Losing Auto Roll's prerequisite is impossible today, but if a rank is ever refunded
	-- the toggle must not be left on with the unlock gone.
	if not GameState.autoRollUnlocked(player) then
		state.autoRoll = false
	end

	-- AFTER the rank is granted and the tickets are gone, so a listener can never observe a
	-- purchase that did not happen. Before the push, so the snapshot the client receives
	-- already reflects anything a listener changed.
	if UpgradeService.onPurchased then
		UpgradeService.onPurchased(player, upgradeId, rank + 1, cost)
	end

	GameState.toast(player, "purchase", ("%s  Lv %d"):format(upgrade.displayName, rank + 1))
	GameState.push(player)
	return true, nil
end

function UpgradeService.setAutoRoll(player: Player, enabled: any): (boolean, string?)
	local state = GameState.get(player)
	if not state then
		return false, "no session"
	end
	if type(enabled) ~= "boolean" then
		return false, "bad request"
	end

	local now = os.clock()
	if now - state.lastAutoToggle < Economy.AUTOROLL_TOGGLE_COOLDOWN then
		return false, "Too fast"
	end
	state.lastAutoToggle = now

	if enabled and not GameState.autoRollUnlocked(player) then
		return false, "Auto Roll not unlocked"
	end

	state.autoRoll = enabled
	GameState.push(player)
	return true, nil
end

-- What the board needs to render one node. Computed server-side truth; the client uses it
-- for display and never to decide whether a purchase is legal.
function UpgradeService.nodeState(player: Player, upgradeId: string)
	local state = GameState.get(player)
	local upgrade = UpgradeConfig.get(upgradeId)
	if not state or not upgrade then
		return nil
	end
	local rank = state.ranks[upgradeId] or 0
	local met = UpgradeConfig.requirementsMet(upgradeId, state.ranks)
	local cost = UpgradeConfig.costOfNext(upgradeId, rank)
	return {
		rank = rank,
		maxRank = upgrade.maxRank,
		cost = cost,
		unlocked = met,
		unmet = UpgradeConfig.unmetRequirements(upgradeId, state.ranks),
		affordable = cost ~= nil and state.tickets >= cost,
		maxed = upgrade.maxRank > 0 and rank >= upgrade.maxRank,
		preview = upgrade.preview == true,
	}
end

-- True when at least one upgrade can be bought right now. Drives the badge on the
-- UPGRADES button.
function UpgradeService.hasAffordable(player: Player): boolean
	local state = GameState.get(player)
	if not state then
		return false
	end
	for _, upgrade in ipairs(UpgradeConfig.all()) do
		if not upgrade.preview and upgrade.maxRank > 0 then
			local rank = state.ranks[upgrade.id] or 0
			if rank < upgrade.maxRank and UpgradeConfig.requirementsMet(upgrade.id, state.ranks) then
				local cost = UpgradeConfig.costOfNext(upgrade.id, rank)
				if cost and state.tickets >= cost then
					return true
				end
			end
		end
	end
	return false
end

return UpgradeService
