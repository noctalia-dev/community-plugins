--!nonstrict
-- Which outputs a fullscreen window covers, from the compositor's own
-- answer. The runtime asks and decodes; these only parse. A set maps an
-- output name to true.

local M = {}

local function present(v): boolean
	return type(v) == "string" and v ~= ""
end

function M.compositor(getenv: (string) -> any, commandExists: (string) -> boolean): string?
	if present(getenv("HYPRLAND_INSTANCE_SIGNATURE")) and commandExists("hyprctl") then
		return "hyprland"
	end
	if present(getenv("SWAYSOCK")) and commandExists("swaymsg") then
		return "sway"
	end
	return nil
end

function M.argv(kind: string)
	if kind == "hyprland" then
		return { "hyprctl", "--batch", "j/monitors;j/clients" }
	end
	return { "swaymsg", "-r", "-t", "get_tree" }
end

-- hyprctl --batch prints each pretty-printed document, separated by blank
-- lines. JSON strings escape their newlines, so a blank line only ever
-- separates documents.
function M.splitBatch(text: string)
	local docs, lines = {}, {}
	local function flush()
		if #lines > 0 then
			table.insert(docs, table.concat(lines, "\n"))
			lines = {}
		end
	end
	for line in string.gmatch((string.gsub(text or "", "\r", "")) .. "\n", "([^\n]*)\n") do
		if string.find(line, "^%s*$") then
			flush()
		else
			table.insert(lines, line)
		end
	end
	flush()
	return docs
end

local function workspaceId(ws): number?
	if type(ws) == "table" and type(ws.id) == "number" then
		return ws.id
	end
	return nil
end

-- `fullscreen` is a bitmask: 1 maximized, 2 fullscreen. Only fullscreen
-- hides the bar.
local function isFullscreen(mask): boolean
	return type(mask) == "number" and math.floor(mask / 2) % 2 == 1
end

-- A monitor is covered by a shown fullscreen client on its active workspace
-- or on the special workspace it currently shows (id 0 = none).
function M.hyprland(monitors, clients)
	local covered = {}
	if type(monitors) ~= "table" or type(clients) ~= "table" then
		return covered
	end
	local byId = {}
	for _, m in ipairs(monitors) do
		if type(m) == "table" and type(m.name) == "string" then
			local shown = {}
			local active, special = workspaceId(m.activeWorkspace), workspaceId(m.specialWorkspace)
			if active then
				shown[active] = true
			end
			if special and special ~= 0 then
				shown[special] = true
			end
			byId[m.id] = { name = m.name, shown = shown }
		end
	end
	for _, c in ipairs(clients) do
		if type(c) == "table" and c.mapped ~= false and not c.hidden and isFullscreen(c.fullscreen) then
			local mon, ws = byId[c.monitor], workspaceId(c.workspace)
			if mon and ws and mon.shown[ws] then
				covered[mon.name] = true
			end
		end
	end
	return covered
end

-- Sway keeps its scratchpad on an output of its own.
local SWAY_HIDDEN = "__i3"

function M.sway(tree)
	local covered, real, global = {}, {}, false
	local function walk(node, output)
		if type(node) ~= "table" then
			return
		end
		if node.type == "output" and type(node.name) == "string" then
			if node.name == SWAY_HIDDEN then
				return
			end
			output = node.name
			table.insert(real, output)
		end
		if node.visible == true then
			if node.fullscreen_mode == 1 and output then
				covered[output] = true
			elseif node.fullscreen_mode == 2 then
				global = true
			end
		end
		for _, key in ipairs({ "nodes", "floating_nodes" }) do
			if type(node[key]) == "table" then
				for _, child in ipairs(node[key]) do
					walk(child, output)
				end
			end
		end
	end
	walk(tree, nil)
	if global then
		for _, name in ipairs(real) do
			covered[name] = true
		end
	end
	return covered
end

function M.any(set): boolean
	return type(set) == "table" and next(set) ~= nil
end

function M.names(set): string
	local list = {}
	if type(set) == "table" then
		for name in pairs(set) do
			table.insert(list, name)
		end
	end
	table.sort(list)
	return table.concat(list, ",")
end

return M
