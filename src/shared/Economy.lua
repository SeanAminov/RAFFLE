--!strict
-- The currency SYSTEM: what the currency is called, how it is formatted, and the limits
-- that bound the loop (storage safety ceilings, onboarding, rate limits).
--
-- PAYOUT VALUES ARE NOT HERE. Everything with a price or a reward in it lives in Rewards,
-- which is the single file to open when retuning the economy. Splitting "what a thing is
-- worth" across two modules is exactly the competing-config problem this stage was meant
-- to remove.
--
-- The old prototype `score` is gone from the player-facing surface; what used to be a
-- score readout is now a Ticket balance, and the raw per-ball point total is an internal
-- "bank" that only exists between a ball spawning and draining.
--
-- The settlement formula itself is documented in Rewards, next to the numbers it uses.

local Economy = {}

-- ---------------------------------------------------------------- currency

Economy.CURRENCY_NAME = "Tickets"

-- ---------------------------------------------------------------- onboarding

-- RNG must not decide whether onboarding can afford Auto Roll. After the first genuine
-- reveal the player is topped UP to this amount if they are short. It is labelled as a
-- starter bonus in the UI and is not disguised as a rare outcome.
Economy.STARTER_TOPUP_TO = 100

-- Balls credited to storage at session start so the machine is alive before the first roll.
-- THREE, not one: measured, a cold start left income ramping for ~15 s while the queue and
-- the table filled, which put a 20 s gap between buying Auto Roll and affording Luck I.
-- Stage 2.1 raised this to FOUR alongside the cheaper early costs: the first decision is
-- meant to arrive inside ten seconds, and a cold table cannot pay for it in that time.
Economy.PRELOADED_BALLS = 4

-- ---------------------------------------------------------------- storage
--
-- THERE IS NO OWNERSHIP CAP. A rolled ball is credited to the player's virtual inventory and
-- stays there until the hopper chooses it. A full machine never rejects, discards or delays a
-- legitimate roll, and manual Roll can no longer fail because the table is busy.
--
-- The old 25-record hard cap and the 8-record Auto Roll target are both GONE. They existed to
-- stop a physical release queue growing without bound; storage is aggregated counts now, so
-- there is nothing to bound. What still binds is PinballTuning.MAX_ACTIVE_BALLS -- only balls
-- physically moving on the table exist as Instances.

-- The ceiling on a single variant's stack. Not a gameplay limit: at roughly 67 rolls a minute
-- this is about 28 million years of continuous play, so it is unreachable by design.
--
-- It exists because Luau numbers are doubles and integer arithmetic is only EXACT below
-- 2^53 (~9.007e15). Clamping an order of magnitude under that means a count can never
-- silently stop incrementing, which is what would happen if a stack were allowed to drift
-- into the range where n + 1 == n.
Economy.MAX_STACK = 1e15

-- Live reservations per player: a ball taken out of storage but not yet settled. Bounded by
-- the active-ball cap in practice (a reservation is spawned immediately), so this is a
-- backstop against a leak rather than a gameplay limit. Deliberately NOT an unbounded
-- release queue -- there is no such structure anywhere any more.
Economy.MAX_RESERVATIONS = 16

-- ---------------------------------------------------------------- roll cadence
--
-- RESOLVED 2026-09-01: rolling and feeding are now separate upgrades.
--
-- Auto Roll's interval used to be derived as `feedInterval * 0.75`, which meant Feed Speed
-- quietly did two jobs -- "the hopper releases sooner" AND "you roll more often". With the
-- queue gone the two systems are genuinely independent, so one upgrade selling both was just
-- muddy: a player buying Feed Speed could not tell which half they were paying for.
--
-- AUTO_SPEED now owns the roll cadence and FEED_SPEED owns the hopper. The AUTOSPEED family
-- base is 0.90s, which is EXACTLY what 1.20 * 0.75 produced at rank 0 -- so day-one pacing is
-- unchanged and every measurement taken under the old coupling still describes rank 0.

-- ---------------------------------------------------------------- rate limits

Economy.ROLL_COOLDOWN = 0.25

-- A full inventory snapshot is the most expensive packet the server sends a player, so the
-- request that triggers it is rate limited like any other. Opening and closing Collection
-- repeatedly is legitimate; doing it forty times a second is not.
Economy.INVENTORY_REQUEST_COOLDOWN = 0.5

-- Policy edits are cheap but land on persisted state, so they are throttled to a rate a
-- human clicking checkboxes can reach and a script cannot exploit.
Economy.POLICY_COOLDOWN = 0.05

-- THE CEILING ON ONE BULK EDIT. A bulk action is ONE packet carrying a list of variant keys,
-- not one packet per key -- the alternative would have been a client burst that POLICY_COOLDOWN
-- above eats after the first, so "hold everything" would silently hold exactly one thing.
--
-- 256 is comfortably above the whole catalog now (24) and above the 240 the schema is sized
-- for, so "select all" is never truncated in practice; it exists so a forged packet carrying a
-- million keys does bounded work rather than stalling the server.
Economy.MAX_POLICY_BATCH = 256
-- A claim is a ticket grant, so it is throttled like a purchase. The idempotent `claimed`
-- flag is what actually makes double-paying impossible; this only keeps a spamming client
-- from making the server do the work.
Economy.CLAIM_COOLDOWN = 0.25
Economy.PURCHASE_COOLDOWN = 0.15
Economy.AUTOROLL_TOGGLE_COOLDOWN = 0.25
-- A Rebirth pays permanent currency and clears the live wallet. Idempotency is what prevents
-- duplicate payment; this bounds how often a hostile client can ask the server to re-check.
Economy.REBIRTH_COOLDOWN = 0.5

function Economy.formatTickets(amount: number): string
	if amount < 1000 then
		return tostring(math.floor(amount))
	end
	local units = { "K", "M", "B", "T" }
	local value = amount
	for _, unit in ipairs(units) do
		value /= 1000
		if value < 1000 then
			return ("%.2f%s"):format(value, unit)
		end
	end
	return ("%.2fQ"):format(value / 1000)
end

-- Renders a denominator the way a player reads it: 1,000,000 not 1e+06.
function Economy.formatOneIn(oneIn: number): string
	local rounded = math.floor(oneIn + 0.5)
	local text = tostring(rounded)
	local out = ""
	local count = 0
	for i = #text, 1, -1 do
		out = text:sub(i, i) .. out
		count += 1
		if count % 3 == 0 and i > 1 then
			out = "," .. out
		end
	end
	return out
end

return Economy
