--!strict
-- WHERE A PROFILE LIVES, and the one rule that must never bend: Studio cannot touch
-- production data.
--
-- ProfileSchema decides what a profile IS. This module decides where it is stored and how a
-- read or a write is actually performed. ProfileService decides WHEN. Keeping the three apart
-- is what lets the whole pipeline be tested against the Mock backend without a DataStore.
--
-- ---------------------------------------------------------------------------------------
-- STUDIO ISOLATION IS STRUCTURAL, NOT A CONVENTION
--
-- `setMode` REFUSES to select Production whenever RunService:IsStudio() is true, and the
-- resolver refuses a second time when a store handle is actually opened. There is no flag,
-- no override parameter and no "force" argument anywhere in this file -- a Studio session
-- cannot reach the production store by any code path, including a mistaken one.
--
-- Default in Studio is MOCK: an in-memory backend with the same envelope semantics, the same
-- lease checks and the same failure surface, so a test exercises the real code rather than a
-- simplified stand-in.
--
-- ---------------------------------------------------------------------------------------
-- THE ENVELOPE
--
-- A key does not hold a bare profile. It holds:
--
--     { profile = <profile>, lease = { sessionId, jobId, heartbeat }, savedAt = <unix> }
--
-- The lease is what makes ONE WRITER PER PROFILE enforceable. Two servers holding the same
-- player -- a rapid rejoin, a teleport -- would otherwise interleave saves and the later
-- write would win arbitrarily. That is the single most common way an incremental game loses
-- player data, and it is why the lease is checked inside UpdateAsync rather than beside it:
-- UpdateAsync is the only operation Roblox makes atomic against concurrent writers.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local ProfileStore = {}

ProfileStore.MODE_MOCK = "Mock"
ProfileStore.MODE_DEV = "DevDataStore"
ProfileStore.MODE_PRODUCTION = "Production"

ProfileStore.PRODUCTION_STORE = "RAFFLE_PLAYER_PROFILES_V1"
ProfileStore.DEV_STORE = "RAFFLE_DEV_PROFILES_V1"

-- A lease older than this is considered abandoned -- the server holding it died without
-- releasing. Long enough that a live server refreshing on its heartbeat never trips it.
ProfileStore.LEASE_STALE_SECONDS = 180

ProfileStore.MAX_ATTEMPTS = 4
ProfileStore.RETRY_BASE_SECONDS = 0.5

ProfileStore.stats = {
	loads = 0, loadFailures = 0, loadQuarantined = 0,
	saves = 0, saveFailures = 0, saveRetries = 0,
	leaseDenied = 0, leaseStolen = 0, leaseReleased = 0,
}

-- ---------------------------------------------------------------- mode

local mode = ProfileStore.MODE_MOCK
local mockData: { [string]: any } = {}

-- THE guard. Named and exported so a test can assert on it directly rather than inferring it.
function ProfileStore.productionAllowed(): boolean
	return not RunService:IsStudio()
end

function ProfileStore.setMode(newMode: string): (boolean, string?)
	if newMode ~= ProfileStore.MODE_MOCK
		and newMode ~= ProfileStore.MODE_DEV
		and newMode ~= ProfileStore.MODE_PRODUCTION then
		return false, "unknown mode " .. tostring(newMode)
	end
	if newMode == ProfileStore.MODE_PRODUCTION and not ProfileStore.productionAllowed() then
		-- Deliberately a REFUSAL, not a silent downgrade to Dev: a caller that asked for
		-- production in Studio has a bug, and quietly giving it something else would hide it.
		return false, "production storage is unreachable from Studio"
	end
	mode = newMode
	return true, nil
end

function ProfileStore.mode(): string
	return mode
end

function ProfileStore.storeName(): string?
	if mode == ProfileStore.MODE_MOCK then
		return nil
	end
	if mode == ProfileStore.MODE_PRODUCTION then
		return ProfileStore.PRODUCTION_STORE
	end
	return ProfileStore.DEV_STORE
end

function ProfileStore.keyFor(userId: number): string
	return ("player_%d"):format(math.floor(userId))
end

-- SECOND GUARD, at the point a real handle is opened. The first guard is in setMode; this one
-- catches anything that reached here another way.
local function resolveStore()
	if mode == ProfileStore.MODE_MOCK then
		return nil
	end
	if mode == ProfileStore.MODE_PRODUCTION and not ProfileStore.productionAllowed() then
		error("ProfileStore: refusing to open the production store from Studio", 0)
	end
	return DataStoreService:GetDataStore(ProfileStore.storeName())
end

-- ---------------------------------------------------------------- mock backend
--
-- Same envelope, same lease rules, same return shape. It exists so the pipeline above it can
-- be exercised in full without a DataStore, not to be a simplified fake.

local function mockUpdate(key: string, transform)
	local current = mockData[key]
	local updated = transform(current)
	if updated == nil then
		return nil, false
	end
	mockData[key] = updated
	return updated, true
end

function ProfileStore.clearMock()
	mockData = {}
end

function ProfileStore.mockSnapshot()
	return mockData
end

-- ---------------------------------------------------------------- retries

-- Bounded, with exponential backoff. A failure is REPORTED, never swallowed: the caller must
-- be able to tell "no data" from "could not read", because those two demand opposite
-- responses and conflating them is how a live profile gets overwritten with a blank one.
local function withRetries(label: string, operation)
	local attempt = 0
	local lastError = nil
	while attempt < ProfileStore.MAX_ATTEMPTS do
		attempt += 1
		local ok, result, extra = pcall(operation)
		if ok then
			return true, result, extra
		end
		lastError = result
		if attempt < ProfileStore.MAX_ATTEMPTS then
			ProfileStore.stats.saveRetries += 1
			task.wait(ProfileStore.RETRY_BASE_SECONDS * (2 ^ (attempt - 1)))
		end
	end
	warn(("[RAFFLE] ProfileStore: %s failed after %d attempts: %s")
		:format(label, ProfileStore.MAX_ATTEMPTS, tostring(lastError)))
	return false, nil, tostring(lastError)
end

-- ---------------------------------------------------------------- lease

local function leaseIsFree(lease: any, sessionId: string, now: number): boolean
	if type(lease) ~= "table" or type(lease.sessionId) ~= "string" then
		return true
	end
	if lease.sessionId == sessionId then
		return true -- our own lease, refreshed
	end
	local heartbeat = type(lease.heartbeat) == "number" and lease.heartbeat or 0
	return (now - heartbeat) > ProfileStore.LEASE_STALE_SECONDS
end

ProfileStore.leaseIsFreeForTest = leaseIsFree

-- ---------------------------------------------------------------- load

-- Returns (status, profileOrNil, err) where status is one of:
--   "loaded"      an existing profile, migrated and normalised
--   "new"         the key held nothing; a blank profile is safe to create
--   "locked"      another live session holds the lease
--   "quarantine"  data exists but cannot be migrated -- DO NOT overwrite it
--   "failed"      the read itself failed -- DO NOT create a blank profile
--
-- FAIL CLOSED. "failed" and "quarantine" are deliberately distinct from "new". A blank
-- writable profile handed out after a read error is how a player's save gets destroyed.
function ProfileStore.load(userId: number, sessionId: string, ProfileSchema, now: number)
	ProfileStore.stats.loads += 1
	local key = ProfileStore.keyFor(userId)

	local function transform(current)
		local lease = current and current.lease
		if not leaseIsFree(lease, sessionId, now) then
			return nil -- abort the UpdateAsync; nothing is written
		end
		if current and current.lease and current.lease.sessionId ~= sessionId then
			ProfileStore.stats.leaseStolen += 1
		end
		local envelope = current or {}
		envelope.lease = { sessionId = sessionId, jobId = tostring(game.JobId), heartbeat = now }
		return envelope
	end

	local ok, envelope, err
	if mode == ProfileStore.MODE_MOCK then
		ok, envelope = pcall(function()
			local updated = mockUpdate(key, transform)
			return updated
		end)
		if not ok then
			err = envelope
			envelope = nil
		end
	else
		local store = resolveStore()
		ok, envelope, err = withRetries("load", function()
			return store:UpdateAsync(key, transform)
		end)
	end

	if not ok then
		ProfileStore.stats.loadFailures += 1
		return "failed", nil, tostring(err)
	end
	if envelope == nil then
		ProfileStore.stats.leaseDenied += 1
		return "locked", nil, "another session holds this profile"
	end
	if envelope.profile == nil then
		return "new", ProfileSchema.blank(now), nil
	end

	local migrated, migrateOk, migrateErr = ProfileSchema.migrate(envelope.profile, now)
	if not migrateOk then
		ProfileStore.stats.loadQuarantined += 1
		return "quarantine", nil, migrateErr
	end
	return "loaded", migrated, nil
end

-- ---------------------------------------------------------------- save

-- ONE serialized write path. The lease is re-checked INSIDE the transform, so a save from a
-- session that lost its lease is refused atomically rather than after the fact.
function ProfileStore.save(userId: number, sessionId: string, profile: any, now: number, release: boolean?)
	ProfileStore.stats.saves += 1
	local key = ProfileStore.keyFor(userId)

	local function transform(current)
		local lease = current and current.lease
		if type(lease) == "table" and type(lease.sessionId) == "string"
			and lease.sessionId ~= sessionId
			and (now - (lease.heartbeat or 0)) <= ProfileStore.LEASE_STALE_SECONDS then
			-- Someone else took it while we were playing. Refuse rather than clobber.
			return nil
		end
		local envelope = current or {}
		envelope.profile = profile
		envelope.savedAt = now
		if release then
			envelope.lease = nil
		else
			envelope.lease = { sessionId = sessionId, jobId = tostring(game.JobId), heartbeat = now }
		end
		return envelope
	end

	local ok, envelope, err
	if mode == ProfileStore.MODE_MOCK then
		ok, envelope = pcall(function()
			return (mockUpdate(key, transform))
		end)
		if not ok then
			err = envelope
			envelope = nil
		end
	else
		local store = resolveStore()
		ok, envelope, err = withRetries("save", function()
			return store:UpdateAsync(key, transform)
		end)
	end

	if not ok then
		ProfileStore.stats.saveFailures += 1
		return false, tostring(err)
	end
	if envelope == nil then
		ProfileStore.stats.leaseDenied += 1
		return false, "lease lost"
	end
	if release then
		ProfileStore.stats.leaseReleased += 1
	end
	return true, nil
end

-- ---------------------------------------------------------------- validation

local function validate()
	-- The isolation guarantee, asserted at load rather than trusted.
	if RunService:IsStudio() then
		local ok, err = ProfileStore.setMode(ProfileStore.MODE_PRODUCTION)
		assert(not ok, "ProfileStore: Studio was allowed to select production storage")
		assert(err ~= nil, "ProfileStore: refusal carried no reason")
		assert(ProfileStore.mode() ~= ProfileStore.MODE_PRODUCTION,
			"ProfileStore: mode changed to production despite the refusal")
		assert(ProfileStore.storeName() ~= ProfileStore.PRODUCTION_STORE,
			"ProfileStore: the production store name is reachable from Studio")
	end

	assert(ProfileStore.keyFor(123) == "player_123", "ProfileStore: unexpected key format")
	assert(ProfileStore.PRODUCTION_STORE ~= ProfileStore.DEV_STORE,
		"ProfileStore: the dev and production stores must not share a name")

	-- Lease semantics, checked directly.
	local now = 1000
	assert(leaseIsFree(nil, "s1", now), "ProfileStore: an absent lease must be free")
	assert(leaseIsFree({ sessionId = "s1", heartbeat = now }, "s1", now),
		"ProfileStore: a session must be able to refresh its own lease")
	assert(not leaseIsFree({ sessionId = "s2", heartbeat = now }, "s1", now),
		"ProfileStore: a live lease held by another session must block")
	assert(leaseIsFree({ sessionId = "s2", heartbeat = now - ProfileStore.LEASE_STALE_SECONDS - 1 }, "s1", now),
		"ProfileStore: a stale lease must be reclaimable")
end

validate()

return ProfileStore
