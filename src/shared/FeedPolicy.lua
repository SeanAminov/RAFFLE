--!strict
-- WHAT THE HOPPER IS ALLOWED TO TAKE, and what the player has said about each variant.
--
-- The rules live here, in shared code, so the Collection panel explains exactly the rule the
-- server enforces rather than a parallel approximation of it. The SERVER is still the only
-- thing that decides: the client calls these functions to draw a checkbox and a count, never
-- to authorise a drop.
--
-- ONE ELIGIBILITY RULE, used by every automatic consumer:
--
--     available(count, keepAtLeast) > 0   AND   not hold   AND   autoFeed
--
-- Anything automatic -- the ordinary weighted feed, the Prize Sorter's best-pick, and any
-- future sink -- must go through `isAutoEligible`. A Hold blocks all of them, unconditionally.
--
-- Drop Next is MANUAL and therefore ignores `autoFeed` (turning off automatic feeding is not
-- the same as refusing to drop one on request), but it still respects Hold and the reserve.
-- Those two are the player saying "do not spend these", and a manual request is still a spend.

-- Required ONLY by the validator, to tie the Prize Sorter interval table to the node's real
-- rank count. UpgradeConfig itself requires nothing, so this cannot form a cycle.
local UpgradeConfig = require(script.Parent:WaitForChild("UpgradeConfig"))

local FeedPolicy = {}

-- ---------------------------------------------------------------- reserve

-- "Keep at least ALL of them." Stored as a sentinel rather than math.huge because the value
-- is persisted and must survive a JSON round-trip.
FeedPolicy.KEEP_ALL = -1

-- Offered as buttons in the Collection panel. ALL is last so the list reads as increasing
-- protection.
FeedPolicy.KEEP_PRESETS = { 0, 1, 10, 100, FeedPolicy.KEEP_ALL }

-- The largest numeric reserve a player may set. Above this, ALL is the honest choice.
FeedPolicy.KEEP_MAX = 1000000

function FeedPolicy.keepLabel(keepAtLeast: number): string
	if keepAtLeast == FeedPolicy.KEEP_ALL then
		return "ALL"
	end
	return tostring(math.floor(keepAtLeast))
end

-- How many of a stack an automatic consumer may actually spend.
function FeedPolicy.available(count: number, keepAtLeast: number): number
	if keepAtLeast == FeedPolicy.KEEP_ALL then
		return 0
	end
	return math.max(0, count - math.max(0, keepAtLeast))
end

-- ---------------------------------------------------------------- per-variant policy

FeedPolicy.NORMAL_DEFAULT = table.freeze({
	autoFeed = true,
	hold = false,
	favorite = false,
	keepAtLeast = 0,
})

-- A newly discovered MUTATED variant arrives protected. A Charged Basic that vanished into
-- the hopper before the player ever looked at it would be indistinguishable from never having
-- rolled it, so the default is "hold it for me" and the player opts in to feeding it.
FeedPolicy.MUTATED_DEFAULT = table.freeze({
	autoFeed = false,
	hold = false,
	favorite = false,
	keepAtLeast = 1,
})

function FeedPolicy.defaultFor(isMutated: boolean)
	local source = isMutated and FeedPolicy.MUTATED_DEFAULT or FeedPolicy.NORMAL_DEFAULT
	return {
		autoFeed = source.autoFeed,
		hold = source.hold,
		favorite = source.favorite,
		keepAtLeast = source.keepAtLeast,
	}
end

-- Coerces anything -- a hand-edited profile, an old schema, a malicious payload -- into a
-- legal policy. Never errors: an unreadable field falls back to the default for its kind.
function FeedPolicy.normalise(raw: any, isMutated: boolean)
	local out = FeedPolicy.defaultFor(isMutated)
	if type(raw) ~= "table" then
		return out
	end
	if type(raw.autoFeed) == "boolean" then
		out.autoFeed = raw.autoFeed
	end
	if type(raw.hold) == "boolean" then
		out.hold = raw.hold
	end
	if type(raw.favorite) == "boolean" then
		out.favorite = raw.favorite
	end
	if type(raw.keepAtLeast) == "number" then
		local keep = raw.keepAtLeast
		if keep == FeedPolicy.KEEP_ALL then
			out.keepAtLeast = FeedPolicy.KEEP_ALL
		else
			out.keepAtLeast = math.clamp(math.floor(keep), 0, FeedPolicy.KEEP_MAX)
		end
	end
	return out
end

-- True when the policy is exactly the default for its kind. Used to keep the profile small:
-- a variant the player has never touched needs no stored policy at all.
function FeedPolicy.isDefault(policy: any, isMutated: boolean): boolean
	local base = isMutated and FeedPolicy.MUTATED_DEFAULT or FeedPolicy.NORMAL_DEFAULT
	return policy.autoFeed == base.autoFeed
		and policy.hold == base.hold
		and policy.favorite == base.favorite
		and policy.keepAtLeast == base.keepAtLeast
end

-- ---------------------------------------------------------------- eligibility

-- THE automatic-consumer gate. Returns (eligible, availableCount, reason).
function FeedPolicy.isAutoEligible(count: number, policy: any): (boolean, number, string?)
	if policy.hold then
		return false, 0, "held"
	end
	if not policy.autoFeed then
		return false, 0, "auto feed off"
	end
	local available = FeedPolicy.available(count, policy.keepAtLeast)
	if available <= 0 then
		return false, 0, count > 0 and "reserved" or "none owned"
	end
	return true, available, nil
end

-- The MANUAL gate, for Drop Next. Ignores autoFeed; still refuses a Hold or a reserve.
function FeedPolicy.isManualEligible(count: number, policy: any): (boolean, number, string?)
	if count <= 0 then
		return false, 0, "none owned"
	end
	if policy.hold then
		return false, 0, "held"
	end
	local available = FeedPolicy.available(count, policy.keepAtLeast)
	if available <= 0 then
		return false, 0, "reserved"
	end
	return true, available, nil
end

-- ---------------------------------------------------------------- Prize Sorter
--
-- PRIZE SORTER I ("Best Drop") is ONE PAID UPGRADE and a plain capability. Own it, and every
-- automatic feed takes the single highest-value eligible ball out of your WHOLE stored
-- collection -- not the best of a batch, not the best of the next few, the best you own.
--
-- There is deliberately NO cadence, no interval and no rank ladder. An earlier design fired
-- only every Nth feed, which meant the upgrade did nothing visible most of the time and
-- needed an invisible counter to explain itself. "Always drops your best ball" is one
-- sentence, needs no counter, and is trivially checkable.
--
-- It is self-limiting without any tuning: rare balls are rare, so the good ones drop promptly
-- and the feed falls back to whatever is common. That IS the intended feel -- a rare you just
-- rolled reaches the table next, instead of queueing behind a pile of Basics.
--
-- It reorders ONLY what the player already owns. It creates nothing, deletes nothing, changes
-- no odds, and can never touch a Held, reserve-protected or Auto-Feed-off variant, because
-- selection runs over `isAutoEligible` and nothing else.

FeedPolicy.SELECT_WEIGHTED = "WEIGHTED"
FeedPolicy.SELECT_BEST = "BEST"

-- The whole upgrade, in one function. Without the Sorter an automatic feed picks
-- count-weighted from the eligible stacks so the table stays varied; with it, the feed always
-- takes the best. Drop Next is manual and never consults this.
function FeedPolicy.selectionMode(prizeSorterOwned: boolean): string
	return prizeSorterOwned and FeedPolicy.SELECT_BEST or FeedPolicy.SELECT_WEIGHTED
end

-- ---------------------------------------------------------------- validation

local function validate()
	assert(FeedPolicy.KEEP_ALL < 0, "FeedPolicy: the KEEP_ALL sentinel must not collide with a real count")
	assert(FeedPolicy.available(100, FeedPolicy.KEEP_ALL) == 0, "FeedPolicy: KEEP_ALL must reserve everything")
	assert(FeedPolicy.available(10, 0) == 10, "FeedPolicy: a zero reserve must free the whole stack")
	assert(FeedPolicy.available(10, 10) == 0, "FeedPolicy: a reserve equal to the count must free nothing")
	assert(FeedPolicy.available(3, 10) == 0, "FeedPolicy: available must never go negative")

	-- A mutated variant must NOT be automatically feedable the moment it is discovered.
	local mutated = FeedPolicy.defaultFor(true)
	assert(select(1, FeedPolicy.isAutoEligible(1, mutated)) == false,
		"FeedPolicy: a freshly discovered mutated variant must not be auto-eligible")

	-- ...and an ordinary one must be, or the hopper would idle out of the box.
	local normal = FeedPolicy.defaultFor(false)
	assert(select(1, FeedPolicy.isAutoEligible(1, normal)) == true,
		"FeedPolicy: an ordinary variant must be auto-eligible by default")

	-- A Hold blocks every consumer, automatic or manual.
	local held = FeedPolicy.defaultFor(false)
	held.hold = true
	assert(select(1, FeedPolicy.isAutoEligible(100, held)) == false, "FeedPolicy: Hold must block automatic feeding")
	assert(select(1, FeedPolicy.isManualEligible(100, held)) == false, "FeedPolicy: Hold must block Drop Next")

	-- The Sorter is a CAPABILITY, not a cadence: not owning it always selects weighted,
	-- owning it always selects best. There is no third state and no hidden counter.
	assert(FeedPolicy.SELECT_WEIGHTED ~= FeedPolicy.SELECT_BEST,
		"FeedPolicy: the two selection modes must be distinguishable")
	assert(FeedPolicy.selectionMode(false) == FeedPolicy.SELECT_WEIGHTED,
		"FeedPolicy: without the Prize Sorter the feed must stay count-weighted")
	assert(FeedPolicy.selectionMode(true) == FeedPolicy.SELECT_BEST,
		"FeedPolicy: with the Prize Sorter every automatic feed must take the best ball")

	-- ONE PAID UPGRADE, BY DECISION (2026-09-01). SORTER combines as a CAPABILITY, so a
	-- second rank would take the player's Tickets and change nothing whatsoever -- the exact
	-- charges-for-nothing failure Stage 2.1 already found once in Roll Speed. If a ladder is
	-- ever wanted here it needs a real stat and a real second selection rule, not another
	-- rank bolted onto a boolean.
	local sorter = UpgradeConfig.get("PRIZE_SORTER")
	assert(sorter, "FeedPolicy: PRIZE_SORTER is missing from UpgradeConfig")
	assert(sorter.maxRank == 1,
		("FeedPolicy: PRIZE_SORTER has %d ranks. Best Drop is ONE paid upgrade; a further rank "
			.. "would charge for nothing because its family combines as a capability.")
			:format(sorter.maxRank))
	local family = UpgradeConfig.FAMILIES[sorter.family]
	assert(family and family.combine == "CAPABILITY",
		("FeedPolicy: PRIZE_SORTER family %s must combine as CAPABILITY, not %s")
			:format(tostring(sorter.family), tostring(family and family.combine)))
end

validate()

return FeedPolicy
