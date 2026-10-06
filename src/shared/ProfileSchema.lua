--!strict
-- THE CANONICAL SAVED PROFILE: its shape, its version, and the migrations between versions.
--
-- Shared rather than server-only so the shape is reviewable in one place and testable without
-- a DataStore. NOTHING here talks to DataStoreService -- this module only decides what a
-- profile IS. ProfileStore decides where it lives; ProfileService decides when it is written.
--
-- ---------------------------------------------------------------------------------------
-- WHAT IS PERSISTED, AND WHY EACH ONE
--
--   tickets       the currency
--   ranks         stable upgrade ids -> rank
--   settings      client presentation choices (see the note below)
--   inventory     aggregated stacks, per-variant policies, bounded reservations
--   collection    permanent discovery and lifetime counts per variant
--   achievements  progress, unlock and claim state
--   stats         lifetime counters progression is judged against
--   rebirth       permanent Rebirth count and unspent Token balance
--
-- WHAT IS DELIBERATELY NOT PERSISTED: physical Instances, camera or UI state, any event
-- history, and above all NOT one object per owned ball. Storage is counts.
--
-- ---------------------------------------------------------------------------------------
-- SIZE
--
-- The profile scales with CATALOG VARIANTS, not with balls owned. Twenty-four variants today;
-- `estimateBytes` measures the real serialised worst case and the validator asserts a large
-- margin under Roblox's 4 MB per-key limit, so growth cannot quietly approach it.
--
-- ---------------------------------------------------------------------------------------
-- VERSIONING
--
-- `schemaVersion` is WRITTEN on every save and CHECKED on every load. A version is never
-- inferred from the shape of the data -- that is how a half-migrated profile gets mistaken
-- for a current one. Migrations are pure functions keyed by the version they migrate FROM,
-- applied in order, and each must be IDEMPOTENT in the sense that running the whole chain on
-- an already-current profile is a no-op.
--
-- A profile that cannot be migrated is QUARANTINED, never overwritten. A player keeps a
-- broken profile they can be helped with rather than silently losing it.

local BallVariant = require(script.Parent:WaitForChild("BallVariant"))
local FeedPolicy = require(script.Parent:WaitForChild("FeedPolicy"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local UpgradeConfig = require(script.Parent:WaitForChild("UpgradeConfig"))

local ProfileSchema = {}

ProfileSchema.VERSION = 2

-- Roblox's documented per-key limit is 4 MB. The margin is deliberately enormous: a profile
-- that ever approaches this is a design error, not a tuning problem, and should fail loudly
-- in a test rather than quietly at a player's save.
ProfileSchema.MAX_BYTES = 4 * 1024 * 1024
ProfileSchema.WARN_BYTES = 256 * 1024

-- Unresolved reservations are persisted so a ball that was in flight when the server died is
-- returned rather than lost. Bounded because the list is a safety net, not a queue.
ProfileSchema.MAX_SAVED_RESERVATIONS = 32

-- ---------------------------------------------------------------- blank profile

function ProfileSchema.blank(now: number?)
	local stamp = now or 0
	return {
		schemaVersion = ProfileSchema.VERSION,
		createdAt = stamp,
		updatedAt = stamp,

		tickets = 0,
		ranks = {},
		settings = Settings.normalise(nil),

		inventory = {
			stacks = {},
			policies = {},
			reservations = {},
		},

		-- variantKey -> { firstSeen, rolled, settled }
		collection = {},

		achievements = {
			progress = {},
			unlocked = {},
			claimed = {},
		},

		rebirth = {
			count = 0,
			tokens = 0,
		},

		stats = {
			rolls = 0,
			bumperHits = 0,
			settled = 0,
			ticketsEarned = 0,
			sessions = 0,
		},
	}
end

-- ---------------------------------------------------------------- normalisation
--
-- Coerces ANY input -- a hand-edited profile, a truncated read, a hostile payload -- into a
-- legal profile. It never errors and never throws away a value it can read: unknown keys are
-- dropped, unreadable ones fall back to the default.
--
-- This runs on every load AFTER migration, so a migration bug cannot produce an illegal
-- profile either.

local function num(value: any, fallback: number, min: number?, max: number?): number
	if type(value) ~= "number" or value ~= value then -- NaN fails the self-comparison
		return fallback
	end
	local out = math.floor(value)
	if min then out = math.max(out, min) end
	if max then out = math.min(out, max) end
	return out
end

function ProfileSchema.normalise(raw: any, now: number?)
	local out = ProfileSchema.blank(now)
	if type(raw) ~= "table" then
		return out
	end

	out.schemaVersion = num(raw.schemaVersion, ProfileSchema.VERSION, 0)
	out.createdAt = num(raw.createdAt, out.createdAt, 0)
	out.updatedAt = num(raw.updatedAt, out.updatedAt, 0)
	out.tickets = num(raw.tickets, 0, 0)

	-- RANKS: only ids that still exist, clamped to the node's real cap. A rank for a removed
	-- upgrade is dropped rather than kept, and a rank above the cap (a downgrade of maxRank,
	-- as happened when Feed Speed lost its third rank) is clamped rather than refused.
	if type(raw.ranks) == "table" then
		for id, rank in pairs(raw.ranks) do
			local upgrade = type(id) == "string" and UpgradeConfig.get(id)
			if upgrade then
				out.ranks[id] = num(rank, 0, 0, upgrade.maxRank)
			end
		end
	end

	out.settings = Settings.normalise(raw.settings)

	-- INVENTORY
	local inventory = type(raw.inventory) == "table" and raw.inventory or {}
	if type(inventory.stacks) == "table" then
		for key, count in pairs(inventory.stacks) do
			if BallVariant.isValid(key) then
				local n = num(count, 0, 0)
				if n > 0 then
					out.inventory.stacks[key] = n
				end
			end
		end
	end
	if type(inventory.policies) == "table" then
		for key, policy in pairs(inventory.policies) do
			if BallVariant.isValid(key) then
				local normalised = FeedPolicy.normalise(policy, BallVariant.isMutated(key))
				-- Only a DEVIATION from the default is stored, so a policy that happens to
				-- equal the default does not occupy a row forever.
				if not FeedPolicy.isDefault(normalised, BallVariant.isMutated(key)) then
					out.inventory.policies[key] = normalised
				end
			end
		end
	end
	if type(inventory.reservations) == "table" then
		for _, entry in ipairs(inventory.reservations) do
			if #out.inventory.reservations >= ProfileSchema.MAX_SAVED_RESERVATIONS then
				break
			end
			if type(entry) == "table" and BallVariant.isValid(entry.variantKey) then
				table.insert(out.inventory.reservations, {
					variantKey = entry.variantKey,
					count = num(entry.count, 1, 1, ProfileSchema.MAX_SAVED_RESERVATIONS),
				})
			end
		end
	end

	-- COLLECTION. Discovery is permanent, so a row is kept even when the count is zero.
	if type(raw.collection) == "table" then
		for key, record in pairs(raw.collection) do
			if BallVariant.isValid(key) and type(record) == "table" then
				out.collection[key] = {
					firstSeen = num(record.firstSeen, 0, 0),
					rolled = num(record.rolled, 0, 0),
					settled = num(record.settled, 0, 0),
				}
			end
		end
	end

	-- ACHIEVEMENTS. Ids are not validated against a catalog here: this module must not
	-- require the achievement definitions, and an id for a removed achievement is harmless
	-- (it is simply never displayed). Claim state is the part that must survive exactly.
	local achievements = type(raw.achievements) == "table" and raw.achievements or {}
	if type(achievements.progress) == "table" then
		for id, value in pairs(achievements.progress) do
			if type(id) == "string" then
				out.achievements.progress[id] = num(value, 0, 0)
			end
		end
	end
	for _, field in ipairs({ "unlocked", "claimed" }) do
		if type(achievements[field]) == "table" then
			for id, value in pairs(achievements[field]) do
				if type(id) == "string" and value == true then
					out.achievements[field][id] = true
				end
			end
		end
	end

	local rebirth = type(raw.rebirth) == "table" and raw.rebirth or {}
	out.rebirth.count = num(rebirth.count, 0, 0)
	out.rebirth.tokens = num(rebirth.tokens, 0, 0)

	local stats = type(raw.stats) == "table" and raw.stats or {}
	for field, fallback in pairs(out.stats) do
		out.stats[field] = num(stats[field], fallback, 0)
	end

	return out
end

-- ---------------------------------------------------------------- migrations
--
-- Keyed by the version they migrate FROM. `migrate` walks the chain in order until the
-- profile reaches ProfileSchema.VERSION, so adding a version is adding one row.
--
-- Version 2 adds permanent Rebirth progression. A shallow clone is sufficient: the migration
-- adds one new top-level block and does not mutate any nested legacy table. The normaliser
-- that follows constructs the canonical deep shape.
ProfileSchema.MIGRATIONS = {
	[1] = function(raw)
		local migrated = table.clone(raw)
		migrated.rebirth = { count = 0, tokens = 0 }
		return migrated
	end,
} :: { [number]: (any) -> any }

-- Returns (profile, ok, err). A profile that cannot be migrated is returned UNCHANGED with
-- ok=false so the caller can quarantine it. It is never silently replaced with a blank.
function ProfileSchema.migrate(raw: any, now: number?): (any, boolean, string?)
	if type(raw) ~= "table" then
		return raw, false, "profile is not a table"
	end

	local version = type(raw.schemaVersion) == "number" and math.floor(raw.schemaVersion) or nil
	if not version then
		return raw, false, "profile has no schemaVersion"
	end
	if version > ProfileSchema.VERSION then
		-- A profile written by a NEWER build. Loading it would silently drop whatever the
		-- newer version added, so it is refused rather than downgraded.
		return raw, false,
			("profile is version %d, this build understands %d"):format(version, ProfileSchema.VERSION)
	end

	local working = raw
	local guard = 0
	while version < ProfileSchema.VERSION do
		local step = ProfileSchema.MIGRATIONS[version]
		if not step then
			return raw, false, ("no migration from version %d"):format(version)
		end
		local ok, result = pcall(step, working)
		if not ok then
			return raw, false, ("migration from version %d failed: %s"):format(version, tostring(result))
		end
		working = result
		version += 1
		working.schemaVersion = version

		guard += 1
		if guard > 64 then
			return raw, false, "migration chain did not terminate"
		end
	end

	return ProfileSchema.normalise(working, now), true, nil
end

-- ---------------------------------------------------------------- session <-> profile

-- Serialises the live session record. Reservations are stored as VARIANT COUNTS rather than
-- drop ids: the ids belong to a server that is about to stop existing, and all the next load
-- needs to know is how many of what to give back.
function ProfileSchema.fromSession(state: any, now: number?): any
	local profile = ProfileSchema.blank(now)
	if type(state) ~= "table" then
		return profile
	end

	profile.tickets = math.max(0, math.floor(state.tickets or 0))
	for id, rank in pairs(state.ranks or {}) do
		profile.ranks[id] = rank
	end
	if state.settings then
		profile.settings = Settings.normalise(state.settings)
	end
	profile.rebirth.count = math.max(0, math.floor(state.rebirths or 0))
	profile.rebirth.tokens = math.max(0, math.floor(state.tokens or 0))

	local inventory = state.inventory
	if inventory then
		for key, count in pairs(inventory.stacks or {}) do
			profile.inventory.stacks[key] = count
		end
		for key, policy in pairs(inventory.policies or {}) do
			profile.inventory.policies[key] = {
				autoFeed = policy.autoFeed,
				hold = policy.hold,
				favorite = policy.favorite,
				keepAtLeast = policy.keepAtLeast,
			}
		end
		-- Collapse in-flight reservations to counts per variant.
		local pending: { [string]: number } = {}
		for _, entry in pairs(inventory.reservations or {}) do
			local key = entry.snapshot and entry.snapshot.variantKey
			if key then
				pending[key] = (pending[key] or 0) + 1
			end
		end
		for key, count in pairs(pending) do
			table.insert(profile.inventory.reservations, { variantKey = key, count = count })
		end
		table.sort(profile.inventory.reservations, function(a, b) return a.variantKey < b.variantKey end)

		for key, record in pairs(inventory.collection or {}) do
			profile.collection[key] = {
				firstSeen = record.firstSeen,
				rolled = record.rolled,
				settled = record.settled,
			}
		end
	end

	if state.achievements then
		for id, value in pairs(state.achievements.progress or {}) do
			profile.achievements.progress[id] = value
		end
		for id in pairs(state.achievements.unlocked or {}) do
			profile.achievements.unlocked[id] = true
		end
		for id in pairs(state.achievements.claimed or {}) do
			profile.achievements.claimed[id] = true
		end
	end

	profile.stats.rolls = math.floor(state.rolls or 0)
	profile.stats.bumperHits = math.floor(state.bumperHits or 0)
	profile.stats.settled = math.floor(state.lifetimeSettled or 0)
	profile.stats.ticketsEarned = math.floor(state.lifetimeTickets or 0)
	profile.stats.sessions = math.floor(state.sessions or 0)

	return ProfileSchema.normalise(profile, now)
end

-- ---------------------------------------------------------------- size

-- Serialised byte count, measured rather than estimated. JSONEncode is what DataStore
-- actually stores, so this is the number the limit applies to.
function ProfileSchema.estimateBytes(profile: any): number
	local HttpService = game:GetService("HttpService")
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(profile)
	end)
	if not ok then
		return -1
	end
	return #encoded
end

-- A worst-case profile: every catalog variant discovered, every one carrying a non-default
-- policy, a full reservation list and maxed ranks. Used by the validator and by the size
-- report so growth is measured against the real ceiling rather than a typical case.
function ProfileSchema.worstCase(extraVariants: number?): any
	local profile = ProfileSchema.blank(1893456000)
	profile.rebirth.count = 999999999
	profile.rebirth.tokens = 999999999
	for _, upgrade in ipairs(UpgradeConfig.all()) do
		profile.ranks[upgrade.id] = upgrade.maxRank
	end
	for _, key in ipairs(BallVariant.all()) do
		profile.inventory.stacks[key] = 999999999999
		profile.inventory.policies[key] = {
			autoFeed = false, hold = true, favorite = true, keepAtLeast = 999999,
		}
		profile.collection[key] = { firstSeen = 1893456000, rolled = 999999999999, settled = 999999999 }
	end
	-- Room for catalogue growth: synthetic keys the same shape as real ones.
	for index = 1, (extraVariants or 0) do
		local key = ("FUTUREBALL%03d|FUTUREMUTATION"):format(index)
		profile.inventory.stacks[key] = 999999999999
		profile.inventory.policies[key] = {
			autoFeed = false, hold = true, favorite = true, keepAtLeast = 999999,
		}
		profile.collection[key] = { firstSeen = 1893456000, rolled = 999999999999, settled = 999999999 }
	end
	for index = 1, ProfileSchema.MAX_SAVED_RESERVATIONS do
		table.insert(profile.inventory.reservations,
			{ variantKey = BallVariant.all()[1], count = index })
	end
	return profile
end

-- ---------------------------------------------------------------- validation

local function validate()
	local blank = ProfileSchema.blank(0)
	assert(blank.schemaVersion == ProfileSchema.VERSION, "ProfileSchema: blank has the wrong version")

	-- NORMALISATION MUST BE TOTAL. Hostile and malformed input must produce a legal profile
	-- rather than an error, because this runs on data the server did not write.
	for _, hostile in ipairs({ nil, 42, "text", true, {}, { ranks = "no" }, { tickets = -5 },
		{ inventory = { stacks = { ["NOT_A_VARIANT"] = 10 } } },
		{ collection = { ["BASIC|NONE"] = "no" } },
		{ achievements = { claimed = { FIRST_ROLL = "yes" } } } }) do
		local ok, result = pcall(ProfileSchema.normalise, hostile, 0)
		assert(ok, "ProfileSchema: normalise errored on malformed input")
		assert(type(result) == "table" and result.schemaVersion == ProfileSchema.VERSION,
			"ProfileSchema: normalise did not produce a legal profile")
		assert(result.tickets >= 0, "ProfileSchema: normalise produced negative tickets")
	end

	-- An invalid variant key must never survive into a profile.
	local dirty = ProfileSchema.normalise({
		inventory = { stacks = { ["NOT_A_VARIANT"] = 10, ["BASIC|NONE"] = 5 } },
	}, 0)
	assert(dirty.inventory.stacks["NOT_A_VARIANT"] == nil,
		"ProfileSchema: an unknown variant key survived normalisation")
	assert(dirty.inventory.stacks["BASIC|NONE"] == 5,
		"ProfileSchema: a valid variant key was dropped")

	-- A rank above its node's cap is CLAMPED, not refused: Feed Speed really did lose a rank.
	local clamped = ProfileSchema.normalise({ ranks = { FEED_SPEED = 99, NOT_AN_UPGRADE = 3 } }, 0)
	assert(clamped.ranks.FEED_SPEED == UpgradeConfig.get("FEED_SPEED").maxRank,
		"ProfileSchema: an over-cap rank was not clamped")
	assert(clamped.ranks.NOT_AN_UPGRADE == nil,
		"ProfileSchema: a rank for an unknown upgrade survived")
	local rebirthSafe = ProfileSchema.normalise({
		rebirth = { count = -4, tokens = "forged" },
	}, 0)
	assert(rebirthSafe.rebirth.count == 0 and rebirthSafe.rebirth.tokens == 0,
		"ProfileSchema: malformed Rebirth progression survived normalisation")

	-- MIGRATION: running the chain on a current profile must be a no-op, and must be safe to
	-- run twice. Loading the same migration twice is explicitly required to be harmless.
	local current = ProfileSchema.blank(0)
	current.tickets = 1234
	local once, ok1 = ProfileSchema.migrate(current, 0)
	assert(ok1, "ProfileSchema: migrating a current profile failed")
	local twice, ok2 = ProfileSchema.migrate(once, 0)
	assert(ok2, "ProfileSchema: migrating twice failed")
	assert(once.tickets == 1234 and twice.tickets == 1234,
		"ProfileSchema: migration is not idempotent")

	-- The real v1 shape had no Rebirth block. It must gain legal zeroes without losing any
	-- existing progression, and running the now-current output through migrate again is safe.
	local legacy = ProfileSchema.blank(0)
	legacy.schemaVersion = 1
	legacy.rebirth = nil
	legacy.tickets = 777
	legacy.ranks.LUCK = 2
	local migrated, okLegacy = ProfileSchema.migrate(legacy, 0)
	assert(okLegacy and migrated.schemaVersion == 2,
		"ProfileSchema: the v1 -> v2 migration failed")
	assert(migrated.tickets == 777 and migrated.ranks.LUCK == 2,
		"ProfileSchema: the Rebirth migration lost existing progression")
	assert(migrated.rebirth.count == 0 and migrated.rebirth.tokens == 0,
		"ProfileSchema: the Rebirth migration did not install zeroed progression")

	-- A profile from a FUTURE version must be refused, not downgraded.
	local future = ProfileSchema.blank(0)
	future.schemaVersion = ProfileSchema.VERSION + 1
	local _, okFuture, errFuture = ProfileSchema.migrate(future, 0)
	assert(not okFuture and errFuture, "ProfileSchema: a future-version profile was accepted")

	-- ...and one with no version at all, which is what a corrupt read looks like.
	local _, okNone = ProfileSchema.migrate({ tickets = 5 }, 0)
	assert(not okNone, "ProfileSchema: a profile with no schemaVersion was accepted")

	-- Every declared migration must be keyed by a version BELOW the current one, or the walk
	-- would never reach it.
	for from in pairs(ProfileSchema.MIGRATIONS) do
		assert(type(from) == "number" and from >= 1 and from < ProfileSchema.VERSION,
			("ProfileSchema: migration keyed from version %s is unreachable"):format(tostring(from)))
	end
end

validate()

return ProfileSchema
