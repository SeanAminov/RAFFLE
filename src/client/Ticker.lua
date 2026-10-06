--!strict
-- ONE RunService connection for the whole client.
--
-- Per-frame work is needed for smooth tumbling and spinning, but a connection per ticket
-- or per spinner would accumulate. Modules register a callback here instead; the
-- connection itself only exists while at least one callback is registered.
--
-- ---------------------------------------------------------------------------------------
-- VIDE IS DRIVEN FROM HERE TOO.
--
-- Vide opens its own RunService.Heartbeat on require, to advance springs and timeouts. That
-- would be a SECOND per-frame connection, which is the exact thing this module exists to
-- prevent. Vide provides `vide.step(dt)` for this: the first call disconnects its internal
-- connection and hands frame ownership over.
--
-- Two things fall out of that, both wanted:
--   * there is still exactly one Heartbeat connection on the client
--   * Vide's springs inherit the hitch clamp below, so a frame spike cannot snap an
--     animation to its end state -- which Vide's own loop would have allowed

local RunService = game:GetService("RunService")

local Ticker = {}

local callbacks: { [string]: (number) -> () } = {}
local count = 0
local connection: RBXScriptConnection? = nil

-- Registered under a reserved name so it can never be unregistered by ordinary code and the
-- connection can never be torn down while Vide still needs frames.
Ticker.VIDE_KEY = "__vide"

local function step(dt: number)
	-- Clamp: a hitch should not teleport animations to their end state.
	local clamped = math.min(dt, 1 / 15)
	for _, fn in pairs(callbacks) do
		fn(clamped)
	end
end

function Ticker.register(name: string, fn: (number) -> ())
	if callbacks[name] == nil then
		count += 1
	end
	callbacks[name] = fn

	if not connection then
		connection = RunService.Heartbeat:Connect(step)
	end
end

function Ticker.unregister(name: string)
	if name == Ticker.VIDE_KEY then
		-- Refused rather than ignored. Silently dropping Vide's frames would leave every
		-- spring and timeout frozen mid-animation with no error to trace it back to.
		error("Ticker: the Vide driver cannot be unregistered", 2)
	end
	if callbacks[name] ~= nil then
		callbacks[name] = nil
		count -= 1
	end
	if count <= 0 and connection then
		connection:Disconnect()
		connection = nil
	end
end

-- Takes ownership of Vide's per-frame work. Call once, early, before any Vide spring or
-- timeout is created. Idempotent: calling it twice does not register a second driver.
function Ticker.driveVide(vide)
	if callbacks[Ticker.VIDE_KEY] then
		return
	end
	Ticker.register(Ticker.VIDE_KEY, function(dt)
		-- The FIRST call disconnects Vide's internal Heartbeat; every later one just steps it.
		vide.step(dt)
	end)
end

function Ticker.activeCount(): number
	return count
end

return Ticker
