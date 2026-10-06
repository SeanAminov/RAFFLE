--!strict
-- THE SERVER EVENT BUS. One place where "something happened" fans out to everything that
-- cares, so a producer never learns the name of a consumer.
--
-- ---------------------------------------------------------------------------------------
-- WHY THIS EXISTS WHEN EVERY PRODUCER ALREADY HAD A HOOK
--
-- RollService.onBallRolled, ScoreService.onBumperHit, FeedService.onBallActivated. Each is
-- ONE SLOT: assigning it replaces whatever was there. That was fine while Bootstrap was the
-- only listener and it stops being fine the moment Achievements wants the same roll that the
-- profile's dirty flag wants -- the second assignment silently wins and the first consumer
-- just stops working.
--
-- The obvious repair, a second hook field per consumer, makes every producer know its
-- consumers by name. That is the thing worth avoiding.
--
-- THE HOOKS STAY. They are now the BRIDGE: Bootstrap points each one at EventBus.emit and
-- the fan-out happens here. Producers are untouched and still know nothing about listeners.
--
-- ---------------------------------------------------------------------------------------
-- SYNCHRONOUS, ORDERED, AND NON-YIELDING
--
-- A listener runs INSIDE the emitter's call, in subscription order, and observes state
-- exactly as the emitter left it. That is a requirement, not an implementation detail: an
-- achievement counting rolls must see the stack the roll just credited, not a stack that a
-- later roll has already moved past.
--
-- Nothing here yields, so two emits can never interleave. A listener that yields breaks that
-- guarantee for every listener after it, which is why listeners must not yield -- if one needs
-- to, it spawns its own task and returns.
--
-- ---------------------------------------------------------------------------------------
-- ONE BAD LISTENER MUST NOT COST A BALL
--
-- Every listener is pcall'd. An achievement that errors while a ball is being rolled must not
-- take the roll down with it -- the ball is already credited by then, and an error propagating
-- out of emit would abort the caller mid-sequence and lose it.
--
-- Failures are COUNTED always and WARNED once per listener per event. A listener that throws
-- on every bumper hit would otherwise produce thousands of identical lines and bury whatever
-- else was in the log.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))

local EventBus = {}

-- name -> array of listeners. COPY ON WRITE: `on` and the unsubscribe it returns both build a
-- NEW array rather than mutating the live one, so a dispatch already walking a list can never
-- have it change underneath it. Subscribing during a dispatch is therefore safe, and so is
-- unsubscribing -- the in-flight dispatch finishes on the list it started with.
--
-- The alternative, copying the list on every emit, would allocate on the hottest path in the
-- game (bumper hits). This allocates only when the listener set changes, which happens at
-- startup and essentially never again.
local subscribers: { [string]: { (any) -> () } } = {}

-- (name, listenerIndex) -> true, so a listener that throws every frame warns once.
local warned: { [string]: boolean } = {}

EventBus.stats = {
	emitted = 0,
	delivered = 0,
	failures = 0,
	subscribes = 0,
	unsubscribes = 0,
}

-- ---------------------------------------------------------------- subscribe

-- Returns an unsubscribe function. Calling it twice is harmless and returns false the second
-- time.
function EventBus.on(name: string, listener: (any) -> ()): () -> boolean
	if not GameEvents.isValid(name) then
		-- A hard error, deliberately. An unknown name is always a typo in our own source, and
		-- the failure mode it produces otherwise -- a channel that exists but never fires --
		-- is invisible until someone notices a feature quietly not working.
		error(("EventBus.on: %q is not a known event"):format(tostring(name)), 2)
	end
	if type(listener) ~= "function" then
		error("EventBus.on: listener must be a function", 2)
	end

	local current = subscribers[name]
	local updated = current and table.clone(current) or {}
	table.insert(updated, listener)
	subscribers[name] = updated
	EventBus.stats.subscribes += 1

	local removed = false
	return function(): boolean
		if removed then
			return false
		end
		local live = subscribers[name]
		if not live then
			return false
		end
		for index, fn in ipairs(live) do
			if fn == listener then
				local without = table.clone(live)
				table.remove(without, index)
				subscribers[name] = without
				removed = true
				EventBus.stats.unsubscribes += 1
				return true
			end
		end
		return false
	end
end

-- ---------------------------------------------------------------- emit

-- Returns how many listeners were delivered to, which is what the startup validator uses to
-- prove the wiring is real rather than assuming it.
function EventBus.emit(name: string, payload: any): number
	if not GameEvents.isValid(name) then
		error(("EventBus.emit: %q is not a known event"):format(tostring(name)), 2)
	end

	EventBus.stats.emitted += 1

	local list = subscribers[name]
	if not list then
		return 0
	end

	local delivered = 0
	for index = 1, #list do
		local ok, err = pcall(list[index], payload)
		if ok then
			delivered += 1
		else
			EventBus.stats.failures += 1
			local key = name .. "#" .. tostring(index)
			if not warned[key] then
				warned[key] = true
				warn(("[RAFFLE] event listener %s failed (further failures suppressed): %s")
					:format(key, tostring(err)))
			end
		end
	end

	EventBus.stats.delivered += delivered
	return delivered
end

-- ---------------------------------------------------------------- introspection

function EventBus.listenerCount(name: string): number
	local list = subscribers[name]
	return list and #list or 0
end

-- Every event with at least one listener. Used by the startup report so a silently unwired
-- consumer is visible rather than merely absent.
function EventBus.wiring(): { [string]: number }
	local out: { [string]: number } = {}
	for _, name in ipairs(GameEvents.ALL) do
		out[name] = EventBus.listenerCount(name)
	end
	return out
end

-- Tests only. Production never removes every listener at once.
function EventBus.reset()
	subscribers = {}
	warned = {}
	EventBus.stats.emitted = 0
	EventBus.stats.delivered = 0
	EventBus.stats.failures = 0
	EventBus.stats.subscribes = 0
	EventBus.stats.unsubscribes = 0
end

return EventBus
