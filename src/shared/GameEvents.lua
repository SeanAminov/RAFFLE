--!strict
-- THE CANONICAL LIST OF GAMEPLAY EVENTS, and the shape of what each one carries.
--
-- This is to the event bus what Net.lua is to the remote surface: one file you can read to
-- know the whole vocabulary. A consumer that wants to know "what can I listen to" reads this
-- and nothing else.
--
-- ---------------------------------------------------------------------------------------
-- WHY THE NAMES LIVE IN SHARED CODE WHEN THE BUS IS SERVER-ONLY
--
-- Nothing here crosses the network today. The names are shared anyway because achievement and
-- quest definitions ARE shared -- they name the event that advances them -- and a definition
-- that names an event the bus does not have must be caught by a validator rather than by a
-- player whose achievement silently never moves.
--
-- ---------------------------------------------------------------------------------------
-- ONE TABLE ARGUMENT, NOT VARARGS
--
-- Every payload is a single table and every payload has `player`. Positional arguments were
-- the obvious choice and the wrong one: adding a field to an event later would have meant
-- editing the signature of every listener, and a listener that read the wrong position would
-- fail silently rather than loudly.
--
-- PAYLOADS ARE READ-ONLY BY CONVENTION. They frequently carry references to live server
-- records -- a DropSnapshot, a roll record -- and a listener that mutates one is corrupting
-- the emitter's state. Listeners read; they do not write.

local GameEvents = {}

-- ---------------------------------------------------------------- the vocabulary

-- (player, record, credit)
-- record: the immutable roll record (variantKey, ballId, mutationId, odds, rollId).
-- credit: what BallInventoryService.credit returned -- firstDiscovery, firstMutationDiscovery,
--         and the resulting stack size.
-- Raised AFTER the ball is safely in storage, so a listener can never observe an uncredited
-- roll.
GameEvents.BALL_ROLLED = "BallRolled"

-- (player, variantKey, record)
-- The FIRST time this player has ever rolled this variant. Derived from BALL_ROLLED rather
-- than emitted independently, so "discovered" can never disagree with "rolled".
GameEvents.BALL_DISCOVERED = "BallDiscovered"

-- (player, mutationId, variantKey, record)
-- The first sighting of a MUTATION, on any ball. Strictly rarer than BALL_DISCOVERED: a
-- player who has seen a Charged Basic and then rolls a Charged Rare gets BALL_DISCOVERED but
-- not this.
GameEvents.MUTATION_DISCOVERED = "MutationDiscovered"

-- (player, snapshot)
-- STORED -> RESERVED. The snapshot is immutable and carries the frozen Ball Value.
GameEvents.BALL_RESERVED = "BallReserved"

-- (player, snapshot, ball)
-- RESERVED -> ACTIVE. The ball now physically exists on the table.
GameEvents.BALL_ACTIVATED = "BallActivated"

-- (player, targetId, points, ball)
-- One scoring contact. Already gated by the per-ball per-target cooldown, so this is a count
-- of real hits and cannot be inflated by a ball resting against a bumper.
GameEvents.BUMPER_HIT = "BumperHit"

-- (player, snapshot, payout, pad)
-- ACTIVE -> SETTLED, with the tickets actually granted. `payout` is what the player received,
-- not what was theoretically owed.
GameEvents.BALL_SETTLED = "BallSettled"

-- (player, upgradeId, rank, cost)
-- `rank` is the rank AFTER the purchase. Raised only for a purchase that was actually paid
-- for, never for a refused one.
GameEvents.UPGRADE_PURCHASED = "UpgradePurchased"

-- (player, count, tokensGranted)
-- Raised after Tickets have been reset and permanent Rebirth progression has been granted.
-- Future feature gates and Token-shop systems can listen without coupling themselves to the
-- remote handler or duplicating the Rebirth transaction.
GameEvents.REBIRTH_COMPLETED = "RebirthCompleted"

-- (player, achievementId, definition)
-- The moment the requirement is met. Unlocking is NOT claiming: the reward is not paid here.
GameEvents.ACHIEVEMENT_UNLOCKED = "AchievementUnlocked"

-- (player, achievementId, reward)
-- The reward was paid, exactly once, ever.
GameEvents.ACHIEVEMENT_CLAIMED = "AchievementClaimed"

-- ---------------------------------------------------------------- the registry

-- Every name above, in emission order for readability. A name not in this list cannot be
-- subscribed to or emitted -- which is what turns a typo into an immediate error instead of a
-- channel that silently never fires.
GameEvents.ALL = table.freeze({
	GameEvents.BALL_ROLLED,
	GameEvents.BALL_DISCOVERED,
	GameEvents.MUTATION_DISCOVERED,
	GameEvents.BALL_RESERVED,
	GameEvents.BALL_ACTIVATED,
	GameEvents.BUMPER_HIT,
	GameEvents.BALL_SETTLED,
	GameEvents.UPGRADE_PURCHASED,
	GameEvents.REBIRTH_COMPLETED,
	GameEvents.ACHIEVEMENT_UNLOCKED,
	GameEvents.ACHIEVEMENT_CLAIMED,
})

local VALID: { [string]: boolean } = {}
for _, name in ipairs(GameEvents.ALL) do
	VALID[name] = true
end
table.freeze(VALID)

function GameEvents.isValid(name: any): boolean
	return type(name) == "string" and VALID[name] == true
end

-- ---------------------------------------------------------------- validator

-- Proves the vocabulary is internally consistent. Cheap enough to run at startup.
function GameEvents.validate(): (boolean, { string })
	local problems = {}

	-- Every exported NAME constant must appear in ALL. This is the check that catches adding
	-- a constant and forgetting the registry line, which would otherwise produce an event
	-- nobody can subscribe to.
	for key, value in pairs(GameEvents) do
		if type(value) == "string" and key == string.upper(key) then
			if not VALID[value] then
				table.insert(problems, ("%s = %q is not in GameEvents.ALL"):format(key, value))
			end
		end
	end

	-- ...and no duplicates in ALL, which would double-deliver every emit on that name.
	local seen: { [string]: boolean } = {}
	for _, name in ipairs(GameEvents.ALL) do
		if seen[name] then
			table.insert(problems, ("%q appears twice in GameEvents.ALL"):format(name))
		end
		seen[name] = true
	end

	return #problems == 0, problems
end

return GameEvents
