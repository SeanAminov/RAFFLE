--!strict
-- THE RIGHT-HAND NAVIGATION STACK, as data.
--
-- Adding a screen -- Quests, Shop, Zones, Forge, Leaderboards -- is a ROW HERE plus a panel
-- module. It must never require editing the screen controller, which is what happened when
-- Upgrades and Settings were each wired by hand.
--
-- ORDER IS EXPLICIT, not array position, so inserting a tile in the middle does not silently
-- renumber everything below it.
--
-- A LOCKED tile is honest: it is visible, it opens, and what it opens says plainly that the
-- system does not exist yet. It carries no badge, no fake progress and no purchase path. The
-- alternative -- hiding it until it ships -- makes the game look smaller than it is and gives
-- a player no idea what is coming.

local UITheme = require(script.Parent:WaitForChild("UITheme"))

local NavRegistry = {}

NavRegistry.ITEMS = {
	{
		id = "UPGRADES",
		label = "Upgrades",
		accent = UITheme.COLOR.green,
		order = 1,
		-- THE NAME OF A PREDICATE, not a boolean. The controller keeps one function per badge
		-- name and asks for it by name, so a new tile opts in by naming a badge here rather
		-- than by growing another branch in the controller.
		badge = "affordable",
	},
	{
		id = "COLLECTION",
		label = "Collection",
		accent = UITheme.COLOR.purple,
		order = 2,
		badge = "newDiscovery",
	},
	{
		id = "ACHIEVEMENTS",
		label = "Achievements",
		accent = UITheme.COLOR.gold,
		order = 3,
		-- Lights up when something is sitting there uncollected. Unlocking is automatic;
		-- claiming is not, so the badge is the only thing that tells you to come and get it.
		badge = "claimable",
	},
	{
		id = "REBIRTH",
		label = "Rebirth",
		accent = UITheme.COLOR.pink,
		order = 4,
		-- Lights when the current Ticket balance meets the server-supplied requirement.
		badge = "rebirthReady",
	},
	{
		id = "SETTINGS",
		label = "Settings",
		accent = UITheme.COLOR.blue,
		order = 5,
		-- The gear stays smaller than the gameplay tiles: it is a utility, not a destination.
		compactHeight = true,
	},
}

local byId: { [string]: any } = {}
for _, item in ipairs(NavRegistry.ITEMS) do
	byId[item.id] = item
end

function NavRegistry.get(id: string)
	return byId[id]
end

-- In display order. Sorted here rather than at every call site.
function NavRegistry.ordered()
	local list = table.clone(NavRegistry.ITEMS)
	table.sort(list, function(a, b) return a.order < b.order end)
	return list
end

-- ---------------------------------------------------------------- validation

local function validate()
	local seenId, seenOrder = {}, {}
	for index, item in ipairs(NavRegistry.ITEMS) do
		local where = ("NavRegistry.ITEMS[%d] (%s)"):format(index, tostring(item.id))
		assert(type(item.id) == "string" and #item.id > 0, where .. ": id is required")
		assert(not seenId[item.id], where .. ": duplicate id")
		seenId[item.id] = true
		assert(type(item.label) == "string" and #item.label > 0, where .. ": label is required")
		assert(typeof(item.accent) == "Color3", where .. ": accent must be a Color3")
		assert(type(item.order) == "number", where .. ": order is required")
		assert(not seenOrder[item.order], where .. ": duplicate order " .. tostring(item.order))
		seenOrder[item.order] = true

		-- A LOCKED TILE MUST EXPLAIN ITSELF. A locked screen that opens to nothing is worse
		-- than no tile at all.
		if item.locked then
			assert(type(item.lockedMessage) == "string" and #item.lockedMessage > 0,
				where .. ": a locked tile needs a lockedMessage")
		end
	end
end

validate()

return NavRegistry
