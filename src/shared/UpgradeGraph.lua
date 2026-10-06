--!strict
-- PRESENTATION ONLY: where each upgrade node sits on the board and which nodes are joined.
--
-- Split from UpgradeConfig on purpose. Moving a node on screen must never be able to change
-- a price or a prerequisite, and re-tuning a price must never require touching layout. The
-- server never reads this file, and graph positions are never persisted.
--
-- Coordinates are in abstract "hex cells", not pixels: the board converts them at render
-- time so the same layout works at any zoom or aspect ratio. +x is right, +y is down.
--
-- COLOUR COMES FROM FAMILY, not from a per-node field. Luck I and Luck II are the same
-- branch because they are the same family, and there is no second place to forget to update.
-- Edges take the colour of the CHILD they lead to, so a branch reads as one continuous path.
--
-- Edges do not carry their own requirement level either; they read it back out of
-- UpgradeConfig, so a connector's lit state is driven by the same number the server
-- validates against.

local UpgradeConfig = require(script.Parent:WaitForChild("UpgradeConfig"))

local UpgradeGraph = {}

-- One colour per FAMILY. LUCK is deliberately the most saturated green on the board: it is
-- the spine, and every Luck tier shares it.
UpgradeGraph.BRANCH = {
	ROOT = Color3.fromRGB(236, 186, 64),
	LUCK = Color3.fromRGB(62, 222, 118),
	AUTO = Color3.fromRGB(244, 108, 182),
	FEED = Color3.fromRGB(74, 166, 252),
	VALUE = Color3.fromRGB(182, 118, 252),
	MUTATION = Color3.fromRGB(96, 220, 244),
	AUTOSPEED = Color3.fromRGB(252, 146, 208),
	SORTER = Color3.fromRGB(250, 146, 74),
	LOCKED = Color3.fromRGB(86, 94, 122),
}

-- The darker outer rim drawn behind each node's coloured face. Derived rather than listed,
-- so a new branch colour cannot forget its rim.
function UpgradeGraph.rimFor(colour: Color3): Color3
	return Color3.new(colour.R * 0.42, colour.G * 0.42, colour.B * 0.42)
end

function UpgradeGraph.colourOf(id: string): Color3
	local upgrade = UpgradeConfig.get(id)
	local family = upgrade and upgrade.family or "LOCKED"
	return UpgradeGraph.BRANCH[family] or UpgradeGraph.BRANCH.LOCKED
end

-- `size` is a multiplier on the base node size, kept NEAR-UNIFORM so every label has room.
-- Luck keeps a slight edge as the spine and that is the only difference.
--
-- LAYOUT: the Luck spine runs up the centre (Luck I -> Luck II -> Multi-Roll), Value goes
-- left, Auto/Feed goes right and down, and the Prize Sorter hangs off the right of the spine.
-- Verified free of overlaps by the validator below, not by eye.
UpgradeGraph.NODES = {
	{ id = "STARTER_MACHINE", x = 0.00, y = 0.00, size = 1.00 },

	{ id = "BALL_VALUE", x = -1.60, y = -0.90, size = 1.00 },
	{ id = "BALL_VALUE_II", x = -3.00, y = -1.80, size = 1.00 },

	{ id = "LUCK", x = 0.00, y = -1.85, size = 1.10 },
	{ id = "LUCK_II", x = 0.00, y = -3.25, size = 1.00 },
	{ id = "MULTI_ROLL", x = -1.05, y = -4.00, size = 1.00 },
	{ id = "MUTATIONS", x = -1.50, y = -2.65, size = 1.00 },

	{ id = "AUTO_ROLL", x = 1.60, y = -0.90, size = 1.00 },
	{ id = "AUTO_SPEED", x = 2.85, y = -1.60, size = 1.00 },
	{ id = "FEED_SPEED", x = 2.95, y = 0.10, size = 1.00 },
	{ id = "MORE_BALLS", x = 3.95, y = 1.15, size = 1.00 },

	{ id = "PRIZE_SORTER", x = 1.50, y = -2.65, size = 1.00 },
}

-- Drawn connectors. These MIRROR the prerequisites in UpgradeConfig; the validator refuses
-- to load if the two ever disagree, so the picture cannot lie about what unlocks what.
UpgradeGraph.EDGES = {
	{ from = "STARTER_MACHINE", to = "LUCK" },
	{ from = "STARTER_MACHINE", to = "AUTO_ROLL" },
	{ from = "STARTER_MACHINE", to = "BALL_VALUE" },

	{ from = "LUCK", to = "LUCK_II" },
	{ from = "BALL_VALUE", to = "BALL_VALUE_II" },

	{ from = "AUTO_ROLL", to = "FEED_SPEED" },
	{ from = "AUTO_ROLL", to = "AUTO_SPEED" },
	{ from = "FEED_SPEED", to = "MORE_BALLS" },

	{ from = "LUCK", to = "MUTATIONS" },
	{ from = "BALL_VALUE", to = "MUTATIONS" },

	{ from = "LUCK", to = "PRIZE_SORTER" },
	{ from = "AUTO_ROLL", to = "PRIZE_SORTER" },

	{ from = "AUTO_ROLL", to = "MULTI_ROLL" },
	{ from = "LUCK", to = "MULTI_ROLL" },
}

local byId: { [string]: any } = {}
for _, node in ipairs(UpgradeGraph.NODES) do
	byId[node.id] = node
end

function UpgradeGraph.node(id: string)
	return byId[id]
end

-- An edge is drawn in the colour of the child it leads to, so a family reads as one path.
function UpgradeGraph.edgeColour(edge): Color3
	return UpgradeGraph.colourOf(edge.to)
end

-- The level this drawn edge represents, read straight out of UpgradeConfig.
function UpgradeGraph.edgeLevel(edge): number
	local upgrade = UpgradeConfig.get(edge.to)
	if upgrade then
		for _, requirement in ipairs(upgrade.requires) do
			if requirement.id == edge.from then
				return UpgradeConfig.requiredLevel(requirement)
			end
		end
	end
	return UpgradeConfig.DEFAULT_REQUIRED_LEVEL
end

-- Is this connector lit? True once the parent has reached the level the edge demands.
function UpgradeGraph.edgeSatisfied(edge, ranks: { [string]: number }): boolean
	return (ranks[edge.from] or 0) >= UpgradeGraph.edgeLevel(edge)
end

function UpgradeGraph.bounds(): (number, number, number, number)
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for _, node in ipairs(UpgradeGraph.NODES) do
		local half = (node.size or 1) * 0.5
		minX, maxX = math.min(minX, node.x - half), math.max(maxX, node.x + half)
		minY, maxY = math.min(minY, node.y - half), math.max(maxY, node.y + half)
	end
	return minX, maxX, minY, maxY
end

function UpgradeGraph.centre(): (number, number)
	local minX, maxX, minY, maxY = UpgradeGraph.bounds()
	return (minX + maxX) / 2, (minY + maxY) / 2
end

local function validate()
	-- every defined upgrade must be placed exactly once
	local placed: { [string]: boolean } = {}
	for _, node in ipairs(UpgradeGraph.NODES) do
		local upgrade = UpgradeConfig.get(node.id)
		assert(upgrade, "UpgradeGraph: node for unknown upgrade " .. tostring(node.id))
		assert(not placed[node.id], "UpgradeGraph: duplicate node " .. tostring(node.id))
		assert(UpgradeGraph.BRANCH[upgrade.family],
			("UpgradeGraph: family %s of %s has no branch colour"):format(upgrade.family, node.id))
		placed[node.id] = true
	end
	for _, upgrade in ipairs(UpgradeConfig.all()) do
		assert(placed[upgrade.id], "UpgradeGraph: upgrade " .. upgrade.id .. " has no node")
	end

	-- NO OVERLAPPING NODES. Cheaper to assert than to rediscover by screenshot.
	for i = 1, #UpgradeGraph.NODES do
		for j = i + 1, #UpgradeGraph.NODES do
			local a, b = UpgradeGraph.NODES[i], UpgradeGraph.NODES[j]
			local dx, dy = a.x - b.x, a.y - b.y
			local distance = math.sqrt(dx * dx + dy * dy)
			local needed = ((a.size or 1) + (b.size or 1)) * 0.5 + 0.18
			assert(distance >= needed,
				("UpgradeGraph: %s and %s are %.2f cells apart, need %.2f")
					:format(a.id, b.id, distance, needed))
		end
	end

	-- the drawn edges must be exactly the declared prerequisites, in both directions
	local drawn: { [string]: boolean } = {}
	for _, edge in ipairs(UpgradeGraph.EDGES) do
		assert(placed[edge.from] and placed[edge.to],
			"UpgradeGraph: edge references a missing node")
		local key = edge.from .. ">" .. edge.to
		assert(not drawn[key], "UpgradeGraph: duplicate edge " .. key)
		drawn[key] = true
	end
	for _, upgrade in ipairs(UpgradeConfig.all()) do
		for _, requirement in ipairs(upgrade.requires) do
			assert(drawn[requirement.id .. ">" .. upgrade.id],
				("UpgradeGraph: %s requires %s but no edge is drawn between them")
					:format(upgrade.id, requirement.id))
		end
	end
	for key in pairs(drawn) do
		local from, to = key:match("^(.-)>(.+)$")
		local upgrade = UpgradeConfig.get(to)
		local found = false
		for _, requirement in ipairs(upgrade.requires) do
			if requirement.id == from then
				found = true
			end
		end
		assert(found, ("UpgradeGraph: edge %s -> %s is drawn but is not a real prerequisite")
			:format(from, to))
	end

	-- EVERY FUNCTIONAL NODE MUST BE REACHABLE from the root by satisfiable prerequisites.
	-- An unreachable purchasable node is dead content the player can never buy.
	local reachable: { [string]: boolean } = {}
	local changed = true
	while changed do
		changed = false
		for _, upgrade in ipairs(UpgradeConfig.all()) do
			if not reachable[upgrade.id] then
				local ok = true
				for _, requirement in ipairs(upgrade.requires) do
					if not reachable[requirement.id] then
						ok = false
					end
				end
				if ok then
					reachable[upgrade.id] = true
					changed = true
				end
			end
		end
	end
	for _, upgrade in ipairs(UpgradeConfig.all()) do
		assert(reachable[upgrade.id], "UpgradeGraph: " .. upgrade.id .. " is unreachable")
	end
end

validate()

return UpgradeGraph
