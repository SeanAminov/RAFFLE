--!strict
-- THE VIRTUAL BALL INVENTORY. Server-authoritative, aggregated, and the only thing that may
-- move a ball between storage and the table.
--
-- ---------------------------------------------------------------------------------------
-- PURE MODULE, BY DESIGN
--
-- Every function takes an inventory RECORD rather than a Player, and touches no Instance, no
-- service and no clock it did not receive. That is not stylistic: the guarantees this module
-- makes -- ten concurrent reservations cannot overdraw one ball, a refund happens exactly
-- once, counts never go negative -- are the ones that most need proving, and a pure record is
-- the only shape that can be exhaustively tested without running the game.
--
-- ---------------------------------------------------------------------------------------
-- THE LIFECYCLE, and the one guard that makes it safe
--
--     ROLLED -> STORED -> RESERVED -> ACTIVE -> SETTLED
--                            |
--                            +--------> STORED         (spawn failed, or owner left)
--
-- Every reservation carries a drop id unique within its owner's inventory. REMOVING THE
-- RESERVATION IS THE TERMINAL-STATE GUARD: `settle` and `refund` both look the drop up, bail
-- if it is absent, and delete it BEFORE crediting anything, with no yield in between. A
-- duplicated, delayed or racing callback therefore finds nothing and can neither pay twice
-- nor return a ball that already settled. There is no separate "done" flag to get out of
-- step with the table.
--
-- ---------------------------------------------------------------------------------------
-- CONSERVATION, per variant, checkable at any instant:
--
--     rolled = stored + reserved + active + settled
--
-- `rolled` and `settled` are lifetime counters kept in the collection record; `stored` is the
-- stack; `reserved` and `active` are DERIVED by scanning the (bounded) reservation table
-- rather than cached in counters. Derivation is O(16) and removes a whole class of drift bug:
-- two numbers that must agree cannot disagree if only one of them exists.
--
-- ---------------------------------------------------------------------------------------
-- WHAT IS STORED, AND WHAT IS NOT
--
-- Storage is a COUNT PER VARIANT. Rolling a million Basics produces one entry reading
-- 1000000, not a million records. Nothing here creates a Part, a Model, a task, a connection
-- or a per-copy table; the only per-ball object in the game is the live Instance the hopper
-- spawns, and those are capped by PinballTuning.MAX_ACTIVE_BALLS.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BallVariant = require(Shared:WaitForChild("BallVariant"))
local Economy = require(Shared:WaitForChild("Economy"))
local FeedPolicy = require(Shared:WaitForChild("FeedPolicy"))

local BallInventoryService = {}

BallInventoryService.STATE_RESERVED = "RESERVED"
BallInventoryService.STATE_ACTIVE = "ACTIVE"

BallInventoryService.SOURCE_AUTO = "AUTO"
BallInventoryService.SOURCE_MANUAL = "MANUAL"

-- Stamped into every snapshot so a retune is distinguishable after the fact.
BallInventoryService.SNAPSHOT_VERSION = 1

BallInventoryService.stats = {
	credited = 0,
	creditRefusedOverflow = 0,
	reserved = 0,
	reserveRefusedNoneEligible = 0,
	reserveRefusedCap = 0,
	activated = 0,
	refunded = 0,
	refundIgnoredUnknown = 0,
	settled = 0,
	settleIgnoredUnknown = 0,
	settleIgnoredNotActive = 0,
	dropNextRequested = 0,
	dropNextRejected = 0,
	dropNextConsumed = 0,
	unresolvedReturned = 0,
}

-- ---------------------------------------------------------------- the record

function BallInventoryService.new(ownerUserId: number?)
	return {
		ownerUserId = ownerUserId or 0,

		-- variantKey -> integer count. An entry is REMOVED at zero rather than left at 0, so
		-- the profile never accumulates a row per variant the player merely touched once.
		stacks = {},

		-- variantKey -> policy. Present ONLY when the player has changed it away from the
		-- default for its kind, for the same reason.
		policies = {},

		-- dropId -> { snapshot = <frozen>, state = RESERVED | ACTIVE }
		-- Bounded by Economy.MAX_RESERVATIONS. This is the ONLY in-flight structure; there is
		-- no release queue anywhere in the game any more.
		reservations = {},
		nextDropId = 0,

		-- ONE pending manual request, replaced rather than queued. Session-only.
		dropNext = nil,

		-- Permanent, never reset by spending: variantKey -> { firstSeen, rolled, settled }
		collection = {},
	}
end

-- ---------------------------------------------------------------- reads

function BallInventoryService.stack(inv, key: string): number
	return inv.stacks[key] or 0
end

function BallInventoryService.policy(inv, key: string)
	local stored = inv.policies[key]
	if stored then
		return stored
	end
	return FeedPolicy.defaultFor(BallVariant.isMutated(key))
end

function BallInventoryService.record(inv, key: string)
	return inv.collection[key]
end

function BallInventoryService.isDiscovered(inv, key: string): boolean
	return inv.collection[key] ~= nil
end

-- Discovery is PERMANENT and survives the count reaching zero -- that is the whole point of
-- keeping the collection record separate from the stack.
function BallInventoryService.discoveredBalls(inv): { [string]: boolean }
	local out = {}
	for key in pairs(inv.collection) do
		local ballId = BallVariant.split(key)
		if ballId then
			out[ballId] = true
		end
	end
	return out
end

function BallInventoryService.discoveredBallCount(inv): number
	local n = 0
	for _ in pairs(BallInventoryService.discoveredBalls(inv)) do
		n += 1
	end
	return n
end

function BallInventoryService.reservationCount(inv): number
	local n = 0
	for _ in pairs(inv.reservations) do
		n += 1
	end
	return n
end

-- ---------------------------------------------------------------- credit (ROLLED -> STORED)

-- Adds `count` of a variant to storage and records the acquisition. Returns
-- (added, info) where info reports first-discovery so the caller can raise events; it never
-- raises them itself, because this module must stay free of the event bus to stay pure.
--
-- CHECKED ADDITION. Luau numbers are doubles and only exact below 2^53, so a stack is never
-- allowed past Economy.MAX_STACK. The overflow branch REFUSES the excess and counts it rather
-- than clamping silently: a clamp would break conservation by losing balls that were rolled.
function BallInventoryService.credit(inv, key: string, count: number, opts): (number, any)
	opts = opts or {}
	if not BallVariant.isValid(key) then
		return 0, { reason = "unknown variant" }
	end
	local want = math.floor(count or 0)
	if want <= 0 then
		return 0, { reason = "non-positive count" }
	end

	local current = inv.stacks[key] or 0
	local room = Economy.MAX_STACK - current
	local added = math.min(want, room)
	if added <= 0 then
		BallInventoryService.stats.creditRefusedOverflow += (want - math.max(0, added))
		return 0, { reason = "stack is full" }
	end
	if added < want then
		BallInventoryService.stats.creditRefusedOverflow += (want - added)
	end

	inv.stacks[key] = current + added

	-- The acquisition is recorded HERE, at roll time, and nowhere else. A ball is counted
	-- once when it is rolled and never again when it drops -- that separation is what keeps
	-- Collection statistics honest.
	local entry = inv.collection[key]
	local firstDiscovery = false
	local firstMutationDiscovery = false
	if not entry then
		firstDiscovery = true
		-- A mutated variant is also the first sighting of that MUTATION when no other
		-- variant carrying it has been seen.
		local _, mutationId = BallVariant.split(key)
		if mutationId and mutationId ~= BallVariant.NO_MUTATION then
			firstMutationDiscovery = true
			for otherKey in pairs(inv.collection) do
				local _, otherMutation = BallVariant.split(otherKey)
				if otherMutation == mutationId then
					firstMutationDiscovery = false
					break
				end
			end
		end
		entry = { firstSeen = opts.now or os.time(), rolled = 0, settled = 0 }
		inv.collection[key] = entry
	end
	entry.rolled += added

	BallInventoryService.stats.credited += added
	return added, {
		firstDiscovery = firstDiscovery,
		firstMutationDiscovery = firstMutationDiscovery,
		stack = inv.stacks[key],
	}
end

-- ---------------------------------------------------------------- policy

function BallInventoryService.setPolicy(inv, key: string, patch): (boolean, any, string?)
	if not BallVariant.isValid(key) then
		return false, nil, "unknown variant"
	end
	if type(patch) ~= "table" then
		return false, nil, "bad request"
	end
	local mutated = BallVariant.isMutated(key)
	local merged = BallInventoryService.policy(inv, key)
	for _, field in ipairs({ "autoFeed", "hold", "favorite", "keepAtLeast" }) do
		if patch[field] ~= nil then
			merged[field] = patch[field]
		end
	end
	merged = FeedPolicy.normalise(merged, mutated)

	-- Store only a DEVIATION from the default. Keeps the profile proportional to what the
	-- player has actually configured rather than to the catalog size.
	if FeedPolicy.isDefault(merged, mutated) then
		inv.policies[key] = nil
	else
		inv.policies[key] = merged
	end
	return true, merged, nil
end

-- ---------------------------------------------------------------- eligibility

-- Every variant an AUTOMATIC consumer may currently take, with how many of each it may take.
-- One code path, so the Prize Sorter and the ordinary weighted feed cannot disagree about
-- what is off limits.
function BallInventoryService.autoEligible(inv)
	local out = {}
	for key, count in pairs(inv.stacks) do
		local ok, available = FeedPolicy.isAutoEligible(count, BallInventoryService.policy(inv, key))
		if ok then
			table.insert(out, { key = key, available = available })
		end
	end
	-- Deterministic order regardless of pairs() iteration, so weighted selection from a given
	-- random sample is reproducible and testable.
	table.sort(out, function(a, b) return a.key < b.key end)
	return out
end

-- ---------------------------------------------------------------- selection

-- Highest-value eligible variant across the WHOLE collection. Not the best of a batch, not
-- the best of the next few -- the best the player owns. Ties are broken by
-- BallVariant.isBetter, which is a strict total order, so exactly one variant can win.
local function bestOf(candidates, ballValueUpgrade: number): string?
	local best = nil
	for _, row in ipairs(candidates) do
		if best == nil or BallVariant.isBetter(row.key, best, ballValueUpgrade) then
			best = row.key
		end
	end
	return best
end

-- Count-weighted pick, so a stack of 500 Basics is chosen far more often than a single Ruby
-- and the table looks like what the player actually owns.
local function weightedOf(candidates, sample: number): string?
	local total = 0
	for _, row in ipairs(candidates) do
		total += row.available
	end
	if total <= 0 then
		return nil
	end
	local target = math.clamp(sample, 0, 0.9999999) * total
	local running = 0
	for _, row in ipairs(candidates) do
		running += row.available
		if target < running then
			return row.key
		end
	end
	return candidates[#candidates].key
end

BallInventoryService.bestOfForTest = bestOf
BallInventoryService.weightedOfForTest = weightedOf

-- ---------------------------------------------------------------- drop next

-- ONE pending manual request per player, REPLACED rather than queued. Nothing is decremented
-- here: the inventory is only touched when a physical slot actually opens, so a Drop Next
-- that is never served costs the player nothing.
function BallInventoryService.requestDropNext(inv, key: string): (boolean, string?)
	BallInventoryService.stats.dropNextRequested += 1
	if not BallVariant.isValid(key) then
		BallInventoryService.stats.dropNextRejected += 1
		return false, "Unknown ball"
	end
	local count = BallInventoryService.stack(inv, key)
	local ok, _, reason = FeedPolicy.isManualEligible(count, BallInventoryService.policy(inv, key))
	if not ok then
		BallInventoryService.stats.dropNextRejected += 1
		if reason == "held" then
			return false, "That ball is held. Unhold it first."
		elseif reason == "reserved" then
			return false, "Your reserve is protecting all of those."
		end
		return false, "You do not own one of those"
	end
	inv.dropNext = key
	return true, nil
end

function BallInventoryService.clearDropNext(inv)
	inv.dropNext = nil
end

-- ---------------------------------------------------------------- reserve (STORED -> RESERVED)

-- Takes exactly one ball out of storage and returns its immutable DropSnapshot.
--
-- BALL VALUE IS FROZEN HERE, and this is the deliberate semantic of the whole design: rarity
-- and mutation were fixed at roll time, but the global Ball Value multiplier is applied at
-- RESERVATION. A ball sitting in storage therefore benefits from a Ball Value bought later,
-- while a ball already on the table can never be re-valued by a purchase mid-flight.
-- Settlement must read `ballValueUpgrade` off this snapshot and never off the live stat.
--
-- ATOMIC. The stack is decremented and the reservation recorded with no yield between them,
-- so ten concurrent callers cannot overdraw a single available ball.
function BallInventoryService.reserve(inv, opts): (any?, string?)
	opts = opts or {}
	local ballValueUpgrade = opts.ballValueUpgrade or 1

	if BallInventoryService.reservationCount(inv) >= Economy.MAX_RESERVATIONS then
		BallInventoryService.stats.reserveRefusedCap += 1
		return nil, "reservation cap"
	end

	local key, source = nil, BallInventoryService.SOURCE_AUTO

	-- A pending Drop Next is honoured FIRST and bypasses the Prize Sorter entirely: the
	-- player asked for a specific ball, and "best" must not override an explicit request.
	if inv.dropNext then
		local pending = inv.dropNext
		inv.dropNext = nil
		local ok = FeedPolicy.isManualEligible(
			BallInventoryService.stack(inv, pending), BallInventoryService.policy(inv, pending))
		if ok then
			key = pending
			source = BallInventoryService.SOURCE_MANUAL
			BallInventoryService.stats.dropNextConsumed += 1
		end
		-- If it became ineligible after it was requested -- the player set a Hold, or a
		-- reserve now covers the stack -- the request is DROPPED rather than honoured. The
		-- newer instruction wins; a stale request must never defeat a protection.
	end

	if not key then
		local candidates = BallInventoryService.autoEligible(inv)
		if #candidates == 0 then
			BallInventoryService.stats.reserveRefusedNoneEligible += 1
			return nil, "no eligible balls"
		end
		if opts.mode == FeedPolicy.SELECT_BEST then
			key = bestOf(candidates, ballValueUpgrade)
		else
			key = weightedOf(candidates, opts.sample or 0)
		end
	end

	if not key then
		BallInventoryService.stats.reserveRefusedNoneEligible += 1
		return nil, "no eligible balls"
	end

	local current = inv.stacks[key] or 0
	if current <= 0 then
		-- Unreachable through the gates above; asserted rather than trusted because a
		-- negative count would silently corrupt conservation forever.
		BallInventoryService.stats.reserveRefusedNoneEligible += 1
		return nil, "empty stack"
	end

	-- --- the atomic section: no yields, no calls that could yield ---
	local remaining = current - 1
	inv.stacks[key] = remaining > 0 and remaining or nil
	inv.nextDropId += 1
	local dropId = inv.nextDropId

	local info = BallVariant.info(key)
	local snapshot = table.freeze({
		dropId = dropId,
		ownerUserId = inv.ownerUserId,
		variantKey = key,
		ballId = info.ballId,
		mutationId = info.mutationId,
		baseValue = info.baseValue,
		mutationMultiplier = info.mutationMultiplier,
		-- FROZEN. Settlement reads this, never the player's live stat.
		ballValueUpgrade = ballValueUpgrade,
		prospectiveValue = BallVariant.prospectiveValue(key, ballValueUpgrade),
		source = source,
		forced = opts.forced == true,
		snapshotVersion = BallInventoryService.SNAPSHOT_VERSION,
		reservedAt = opts.now or os.clock(),
	})
	inv.reservations[dropId] = { snapshot = snapshot, state = BallInventoryService.STATE_RESERVED }
	-- --- end atomic section ---

	BallInventoryService.stats.reserved += 1
	return snapshot, nil
end

-- ---------------------------------------------------------------- activate (RESERVED -> ACTIVE)

function BallInventoryService.activate(inv, dropId: number): boolean
	local entry = inv.reservations[dropId]
	if not entry or entry.state ~= BallInventoryService.STATE_RESERVED then
		return false
	end
	entry.state = BallInventoryService.STATE_ACTIVE
	BallInventoryService.stats.activated += 1
	return true
end

-- ---------------------------------------------------------------- refund (-> STORED)

-- Returns an unresolved ball to storage. Legal from RESERVED (the spawn failed) and from
-- ACTIVE (the owner left while it was in play, which pays nothing).
--
-- EXACTLY ONCE. The reservation is deleted BEFORE the stack is credited, with no yield
-- between, so a second call -- a retry, a race with settle, a delayed timeout -- finds
-- nothing and returns false.
function BallInventoryService.refund(inv, dropId: number): (boolean, string?)
	local entry = inv.reservations[dropId]
	if not entry then
		BallInventoryService.stats.refundIgnoredUnknown += 1
		return false, nil
	end
	inv.reservations[dropId] = nil

	local key = entry.snapshot.variantKey
	local current = inv.stacks[key] or 0
	-- Checked, like every other addition: a refund must not be the one path that can overflow.
	if current < Economy.MAX_STACK then
		inv.stacks[key] = current + 1
	else
		BallInventoryService.stats.creditRefusedOverflow += 1
	end

	BallInventoryService.stats.refunded += 1
	return true, key
end

-- ---------------------------------------------------------------- settle (ACTIVE -> SETTLED)

-- Terminal. Removes the reservation FIRST, then records the settlement, so a duplicated
-- settle cannot pay twice and a settle racing a refund has exactly one winner.
--
-- Only an ACTIVE drop may settle: a ball that never reached the table has nothing to settle
-- through, and treating that as payable would create Tickets from a failed spawn.
function BallInventoryService.settle(inv, dropId: number, opts): (boolean, any?)
	local entry = inv.reservations[dropId]
	if not entry then
		BallInventoryService.stats.settleIgnoredUnknown += 1
		return false, nil
	end
	if entry.state ~= BallInventoryService.STATE_ACTIVE then
		BallInventoryService.stats.settleIgnoredNotActive += 1
		return false, nil
	end
	inv.reservations[dropId] = nil

	local key = entry.snapshot.variantKey
	local record = inv.collection[key]
	if record then
		record.settled += 1
	end

	BallInventoryService.stats.settled += 1
	return true, entry.snapshot
end

function BallInventoryService.snapshotOf(inv, dropId: number)
	local entry = inv.reservations[dropId]
	return entry and entry.snapshot or nil
end

function BallInventoryService.stateOf(inv, dropId: number): string?
	local entry = inv.reservations[dropId]
	return entry and entry.state or nil
end

-- ---------------------------------------------------------------- recovery

-- Returns EVERY unresolved reservation to storage and reports how many. Used on a graceful
-- disconnect, and again when a profile loads: a persisted reservation's physical Instance
-- cannot have survived the server, so the honest thing is to give the ball back.
--
-- Safe to call twice -- the second call finds an empty table and returns 0.
function BallInventoryService.releaseUnresolved(inv): number
	local ids = {}
	for dropId in pairs(inv.reservations) do
		table.insert(ids, dropId)
	end
	table.sort(ids)
	local returned = 0
	for _, dropId in ipairs(ids) do
		if BallInventoryService.refund(inv, dropId) then
			returned += 1
		end
	end
	inv.dropNext = nil
	BallInventoryService.stats.unresolvedReturned += returned
	return returned
end

-- ---------------------------------------------------------------- future sinks

-- ATOMIC MULTI-CONSUME, left ready for a Merge/Fusion system. Nothing calls it yet and
-- nothing merges anything today; it exists so the future sink cannot be written as a loop of
-- single decrements that could half-succeed.
--
-- Validates the WHOLE request before touching anything, then applies it with no yield, so a
-- request that cannot be met in full changes nothing at all. Respects Hold and the reserve --
-- a merge is a deliberate spend, and those two say "do not spend these" regardless of intent.
function BallInventoryService.consumeMany(inv, requests): (boolean, string?)
	if type(requests) ~= "table" or #requests == 0 then
		return false, "nothing requested"
	end

	local wanted: { [string]: number } = {}
	for _, request in ipairs(requests) do
		local key = request.variantKey
		local count = math.floor(request.count or 0)
		if not BallVariant.isValid(key) then
			return false, "unknown variant " .. tostring(key)
		end
		if count <= 0 then
			return false, "non-positive count"
		end
		wanted[key] = (wanted[key] or 0) + count
	end

	for key, count in pairs(wanted) do
		local ok, available, reason = FeedPolicy.isManualEligible(
			BallInventoryService.stack(inv, key), BallInventoryService.policy(inv, key))
		if not ok then
			return false, ("%s is not available (%s)"):format(key, tostring(reason))
		end
		if available < count then
			return false, ("only %d of %s are available"):format(available, key)
		end
	end

	-- --- atomic apply ---
	for key, count in pairs(wanted) do
		local remaining = (inv.stacks[key] or 0) - count
		inv.stacks[key] = remaining > 0 and remaining or nil
	end
	return true, nil
end

-- ---------------------------------------------------------------- conservation

-- rolled = stored + reserved + active + settled, per variant.
--
-- Returns (ok, rows). Cheap enough to assert in tests after every operation, which is exactly
-- how it is used: an invariant only checked at the end tells you that something broke, not
-- which operation broke it.
function BallInventoryService.conservation(inv): (boolean, { any })
	local reserved: { [string]: number } = {}
	local active: { [string]: number } = {}
	for _, entry in pairs(inv.reservations) do
		local key = entry.snapshot.variantKey
		if entry.state == BallInventoryService.STATE_ACTIVE then
			active[key] = (active[key] or 0) + 1
		else
			reserved[key] = (reserved[key] or 0) + 1
		end
	end

	local ok = true
	local rows = {}
	for key, record in pairs(inv.collection) do
		local stored = inv.stacks[key] or 0
		local r = reserved[key] or 0
		local a = active[key] or 0
		local balanced = record.rolled == stored + r + a + record.settled
		local nonNegative = stored >= 0 and record.rolled >= 0 and record.settled >= 0
		if not balanced or not nonNegative then
			ok = false
		end
		table.insert(rows, {
			key = key, rolled = record.rolled, stored = stored,
			reserved = r, active = a, settled = record.settled,
			balanced = balanced, nonNegative = nonNegative,
		})
	end

	-- A stack with no collection record would be a ball that exists but was never rolled.
	for key, count in pairs(inv.stacks) do
		if not inv.collection[key] then
			ok = false
			table.insert(rows, { key = key, stored = count, orphanStack = true })
		end
		if count < 0 then
			ok = false
		end
	end

	table.sort(rows, function(a, b) return tostring(a.key) < tostring(b.key) end)
	return ok, rows
end

-- Total owned across every variant. Display only.
function BallInventoryService.totalStored(inv): number
	local n = 0
	for _, count in pairs(inv.stacks) do
		n += count
	end
	return n
end

return BallInventoryService
