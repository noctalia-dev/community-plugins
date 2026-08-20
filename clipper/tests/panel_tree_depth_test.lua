local renderedTree
local stateValues = {}
local config = {
	database_mode = "global",
	history_cards = 17,
	panel_margin_percent = 0,
	show_panel_background = false,
	show_close_button = true,
	pinned_color = "primary",
	card_color = "surface_variant",
	notes_color = "#FFD54F",
}

local snapshot = {
	revision = 1,
	status = "ready",
	error = "",
	items = {},
	pinned = {},
	notes = {},
	watchers_running = false,
	total = 17,
}

for index = 1, 17 do
	snapshot.items[index] = {
		id = tostring(index),
		kind = index == 1 and "image" or "text",
		preview = "Clipboard item " .. tostring(index),
		image_path = index == 1 and "/virtual/image.png" or "",
	}
end
for index = 1, 3 do
	snapshot.pinned[index] = {
		id = "pin-" .. tostring(index),
		kind = "text",
		preview = "Pinned item " .. tostring(index),
	}
	snapshot.notes[index] = {
		id = "note-" .. tostring(index),
		title = "Note " .. tostring(index),
		content = "Body",
		color = "#FFD54F",
		x = 24 + index * 20,
		y = 24 + index * 20,
		z = index,
	}
end

noctalia = {
	getConfig = function(key) return config[key] end,
	outputs = function() return { { width = 3440, height = 1440, focused = true } } end,
	tr = function(key, values)
		if type(values) == "table" and values.count ~= nil then
			return key .. ":" .. tostring(values.count)
		end
		return key
	end,
	string = {
		trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
	},
	state = {
		get = function(key)
			if key == "clipper_snapshot" then return snapshot end
			return stateValues[key]
		end,
		set = function(key, value) stateValues[key] = value end,
		watch = function(_key, _callback) end,
	},
	runAsync = function(_command) return true end,
}

panel = {
	render = function(tree) renderedTree = tree end,
	close = function() end,
	setWantsSecondTicks = function(_enabled) end,
}

ui = setmetatable({}, {
	__index = function(_table, kind)
		return function(props, children)
			return { type = kind, props = props or {}, children = children or {} }
		end
	end,
})

-- The plugin is Luau, while repository tests run with stock Lua. Translate
-- the three compound assignments used by the panel before loading it.
getfenv = function() return _G end
local file = assert(io.open("panel.luau", "r"))
local source = file:read("*a")
file:close()
source = source:gsub("requestCounter %+= 1", "requestCounter = requestCounter + 1")
source = source:gsub("count %+= 1", "count = count + 1")
source = source:gsub("historyPage %+= 1", "historyPage = historyPage + 1")
assert(load(source, "@panel.luau", "t", _G))()
assert(type(renderedTree) == "table", "panel did not render a UI tree")
onOpen()
assert(stateValues.clipper_request == nil, "panel open issued a redundant explicit refresh")

onNoteDrop("note-1", "canvas", 123.5, 456.25)
local moveRequest = stateValues.clipper_request
assert(type(moveRequest) == "table", "note drop did not issue a service request")
assert(moveRequest.operation == "move_note", "note drop issued the wrong operation")
assert(moveRequest.id == "note-1", "note drop lost the note id")
assert(moveRequest.x == 123.5 and moveRequest.y == 456.25, "note drop lost the canvas coordinates")

local function measure(node, depth, path)
	local maxDepth = depth
	local nodeCount = 1
	local deepestPath = path
	for _, child in ipairs(node.children or {}) do
		local childName = child.props.key or child.type
		local childDepth, childCount, childPath = measure(child, depth + 1, path .. " > " .. childName)
		if childDepth > maxDepth then
			maxDepth = childDepth
			deepestPath = childPath
		end
		nodeCount = nodeCount + childCount
	end
	return maxDepth, nodeCount, deepestPath
end

local maxDepth, nodeCount, deepestPath = measure(renderedTree, 0, renderedTree.props.key or renderedTree.type)
print(string.format("clipper panel tree: depth=%d nodes=%d", maxDepth, nodeCount))
print("deepest path: " .. deepestPath)
assert(maxDepth <= 8, "panel UI tree exceeds the safe upstream parser depth")
