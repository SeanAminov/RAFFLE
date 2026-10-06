--!strict
-- Server-authoritative Rebirth transaction.
--
-- The client asks to rebirth and supplies only an opaque idempotency token. Cost, reward,
-- eligibility, reset scope and the resulting totals all come from server-owned state and
-- RebirthConfig. A forged packet can ask early and be refused; it cannot name an award.
--
-- CONSUME BEFORE PAY: Tickets are set to zero before the permanent counters move, with no
-- yield between. The accepted token is recorded in the same non-yielding section, so a
-- duplicate request finds the completed transaction and cannot grant Tokens twice.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
local RebirthConfig = require(Shared:WaitForChild("RebirthConfig"))

local GameState = require(script.Parent:WaitForChild("GameState"))

local RebirthService = {}

-- (player, count, tokensGranted) raised only after a completed transaction. Bootstrap routes
-- it onto EventBus so later unlocks can subscribe without living inside this service.
RebirthService.onCompleted = nil

RebirthService.stats = {
	completed = 0,
	rejectedFunds = 0,
	rejectedRate = 0,
	rejectedDuplicate = 0,
}

-- Pure state seam used by Edit-mode verification. `now` is supplied so rate limiting can be
-- proved without sleeping or entering Play Mode.
local function applyToState(state: any, requestToken: any, now: number): (boolean, string?, number?)
	if type(state) ~= "table" then
		return false, "no session", nil
	end

	if type(requestToken) == "string" and #requestToken > 0 and #requestToken <= 64
		and state.lastAcceptedRebirthToken == requestToken then
		RebirthService.stats.rejectedDuplicate += 1
		return false, nil, nil
	end

	local last = type(state.lastRebirth) == "number" and state.lastRebirth or -math.huge
	if now - last < Economy.REBIRTH_COOLDOWN then
		RebirthService.stats.rejectedRate += 1
		return false, "Too fast", nil
	end
	state.lastRebirth = now

	local completed = math.max(0, math.floor(state.rebirths or 0))
	local cost = RebirthConfig.costForNext(completed)
	if type(state.tickets) ~= "number" or state.tickets < cost then
		RebirthService.stats.rejectedFunds += 1
		return false, ("Need %s Tickets"):format(Economy.formatTickets(cost)), nil
	end

	local nextRebirth = completed + 1
	local reward = RebirthConfig.tokensFor(nextRebirth)

	-- The approved boundary is Tickets ONLY. Ranks, inventory, discoveries, achievements,
	-- settings and lifetime counters are deliberately untouched here.
	state.tickets = 0
	state.rebirths = nextRebirth
	state.tokens = math.max(0, math.floor(state.tokens or 0)) + reward
	if type(requestToken) == "string" and #requestToken > 0 and #requestToken <= 64 then
		state.lastAcceptedRebirthToken = requestToken
	end

	RebirthService.stats.completed += 1
	return true, nil, reward
end

RebirthService.applyToStateForTest = applyToState

function RebirthService.rebirth(player: Player, requestToken: any): (boolean, string?, number?)
	local state = GameState.get(player)
	local ok, reason, reward = applyToState(state, requestToken, os.clock())
	if ok and RebirthService.onCompleted then
		RebirthService.onCompleted(player, state.rebirths, reward)
	end
	return ok, reason, reward
end

return RebirthService
