--!strict
-- THE REBIRTH CONTRACT: cost, permanent rewards, reset boundary and milestones.
--
-- One module feeds both the server transaction and the client preview, so the button can
-- never promise a different reset or reward than the server applies. The client still sends
-- intent only; it never sends a cost, Token amount, Luck bonus or resulting rebirth count.
--
-- QUICK FIRST LOOPS ARE DELIBERATE. The first two requirements sit near the early Tier I
-- purchases, then the curve opens up. Upgrades persist through rebirth, so later loops are
-- naturally shorter than these raw requirements suggest as the machine becomes stronger.

local RebirthConfig = {}

RebirthConfig.CURRENCY_NAME = "Tokens"
RebirthConfig.LUCK_PER_REBIRTH = 0.10

-- Requirement for rebirth numbers 1..6. Beyond that, the last cost grows by 1.55 per step
-- and rounds to 500 Tickets so the displayed target remains readable rather than pretending
-- an arbitrary exponential result is meaningful down to the last Ticket.
RebirthConfig.EARLY_COSTS = { 1000, 2500, 5000, 9000, 15000, 24000 }
RebirthConfig.LATE_GROWTH = 1.55
RebirthConfig.COST_ROUNDING = 500
RebirthConfig.MAX_COST = 1e15

-- These are real mechanical milestones, not marketing copy. Adding a later Rebirth shop or
-- feature gate means adding a row here and teaching its owning system to read the same id.
RebirthConfig.MILESTONES = {
	{ rebirth = 3, id = "TOKEN_PAYOUT_II", title = "TOKEN PAYOUT II",
		description = "Future rebirths grant 2 Tokens." },
	{ rebirth = 6, id = "TOKEN_PAYOUT_III", title = "TOKEN PAYOUT III",
		description = "Future rebirths grant 3 Tokens." },
}

-- Explicit data, because a reset boundary hidden in prose will eventually drift from the
-- code. Latest approved direction: Tickets reset; every other current progression system
-- survives. Lifetime ticket stats also survive, so an achievement cannot be un-earned.
RebirthConfig.RESET = { "Tickets" }
RebirthConfig.KEEP = {
	"Upgrades", "Balls & Collection", "Achievements", "Settings", "Tokens",
}

local function whole(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.max(0, math.floor(value))
end

function RebirthConfig.costForNext(completed: number): number
	local nextRebirth = whole(completed) + 1
	local early = RebirthConfig.EARLY_COSTS[nextRebirth]
	if early then
		return early
	end
	local extra = nextRebirth - #RebirthConfig.EARLY_COSTS
	local raw = RebirthConfig.EARLY_COSTS[#RebirthConfig.EARLY_COSTS]
		* RebirthConfig.LATE_GROWTH ^ extra
	local rounded = math.floor(raw / RebirthConfig.COST_ROUNDING + 0.5)
		* RebirthConfig.COST_ROUNDING
	return math.min(RebirthConfig.MAX_COST, rounded)
end

-- The reward belongs to the rebirth ABOUT TO HAPPEN. Rebirth 3 itself is the first one that
-- pays 2, so the milestone is felt on the click that unlocks it rather than one loop later.
function RebirthConfig.tokensFor(nextRebirth: number): number
	local count = math.max(1, whole(nextRebirth))
	if count >= 6 then
		return 3
	elseif count >= 3 then
		return 2
	end
	return 1
end

function RebirthConfig.luckBonus(completed: number): number
	return whole(completed) * RebirthConfig.LUCK_PER_REBIRTH
end

function RebirthConfig.nextMilestone(completed: number)
	local count = whole(completed)
	for _, milestone in ipairs(RebirthConfig.MILESTONES) do
		if milestone.rebirth > count then
			return milestone
		end
	end
	return nil
end

function RebirthConfig.snapshot(completed: number, tokens: number, tickets: number)
	local count = whole(completed)
	local nextRebirth = count + 1
	local cost = RebirthConfig.costForNext(count)
	return {
		count = count,
		tokens = whole(tokens),
		cost = cost,
		reward = RebirthConfig.tokensFor(nextRebirth),
		eligible = whole(tickets) >= cost,
		luckBonus = RebirthConfig.luckBonus(count),
		nextLuckBonus = RebirthConfig.luckBonus(nextRebirth),
		nextMilestone = RebirthConfig.nextMilestone(count),
	}
end

local function validate()
	assert(#RebirthConfig.EARLY_COSTS >= 3, "RebirthConfig: early curve is too short")
	local previous = 0
	for index, cost in ipairs(RebirthConfig.EARLY_COSTS) do
		assert(type(cost) == "number" and cost > previous and cost == math.floor(cost),
			("RebirthConfig: cost %d must be a rising positive integer"):format(index))
		previous = cost
	end
	assert(RebirthConfig.LATE_GROWTH > 1, "RebirthConfig: late growth must exceed 1")
	for completed = #RebirthConfig.EARLY_COSTS, #RebirthConfig.EARLY_COSTS + 24 do
		local cost = RebirthConfig.costForNext(completed)
		assert(cost >= previous and cost == math.floor(cost),
			("RebirthConfig: late cost after %d rebirths is invalid"):format(completed))
		previous = cost
	end
	assert(RebirthConfig.LUCK_PER_REBIRTH > 0,
		"RebirthConfig: a rebirth must grant measurable permanent Luck")

	local seen, priorMilestone = {}, 0
	for index, milestone in ipairs(RebirthConfig.MILESTONES) do
		local where = ("RebirthConfig.MILESTONES[%d]"):format(index)
		assert(type(milestone.id) == "string" and not seen[milestone.id], where .. ": bad id")
		seen[milestone.id] = true
		assert(milestone.rebirth > priorMilestone, where .. ": milestones must be ordered")
		assert(type(milestone.title) == "string" and #milestone.title > 0, where .. ": title required")
		assert(type(milestone.description) == "string" and #milestone.description > 0,
			where .. ": description required")
		priorMilestone = milestone.rebirth
	end

	assert(#RebirthConfig.RESET == 1 and RebirthConfig.RESET[1] == "Tickets",
		"RebirthConfig: the approved reset boundary is Tickets only")
	assert(table.find(RebirthConfig.KEEP, "Tokens") ~= nil,
		"RebirthConfig: Tokens must survive Rebirth")
	assert(RebirthConfig.costForNext(0) == 1000, "RebirthConfig: first rebirth drifted")
	assert(RebirthConfig.tokensFor(2) == 1 and RebirthConfig.tokensFor(3) == 2
		and RebirthConfig.tokensFor(6) == 3, "RebirthConfig: Token milestones drifted")
end

validate()

return RebirthConfig
