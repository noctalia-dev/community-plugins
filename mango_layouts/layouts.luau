local M = {}

local glyphs = {
	tile = "layout-sidebar",
	scroller = "carousel-horizontal",
	monocle = "square",
	grid = "layout-grid",
	fair = "layout-board-split",
	deck = "layers-difference",
	dwindle = "layout-2",
	center_tile = "layout-distribute-vertical",
	vertical_tile = "layout-rows",
	right_tile = "layout-sidebar-right",
	vertical_scroller = "carousel-vertical",
	vertical_grid = "grid-dots",
	vertical_deck = "chart-funnel",
	vertical_fair = "layout-board",
	floating = "window",
}

function M.normalize(data)
	if type(data) ~= "table" or type(data.layouts) ~= "table" or #data.layouts == 0 then
		return nil
	end
	local layouts = {}
	local seen = {}
	local count = 0
	for index, entry in pairs(data.layouts) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #data.layouts then
			return nil
		end
		if type(entry) ~= "table" or type(entry.name) ~= "string" or not entry.name:match("%S")
			or type(entry.symbol) ~= "string" or not entry.symbol:match("%S") then
			return nil
		end
		count = count + 1
	end
	if count ~= #data.layouts then return nil end
	for _, entry in ipairs(data.layouts) do
		if not seen[entry.name] then
			seen[entry.name] = true
			table.insert(layouts, { name = entry.name, symbol = entry.symbol })
		end
	end
	return layouts
end

function M.query(target, done)
	local function finish(result)
		if not result or result.exitCode ~= 0 then
			done(nil)
			return
		end
		local ok, data = pcall(noctalia.json.decode, result.stdout or "")
		done(if ok and type(data) == "table" then data else nil)
	end
	local started = noctalia.runAsync({ "mmsg", "get", target }, finish, 3000)
	if not started then done(nil) end
end

function M.discover(done)
	M.query("layouts", function(data)
		done(M.normalize(data))
	end)
end

function M.active(data)
	if type(data) ~= "table" or type(data.monitors) ~= "table" then return "" end
	for _, monitor in ipairs(data.monitors) do
		if type(monitor) == "table" and monitor.active == true and type(monitor.layout_symbol) == "string" then
			return monitor.layout_symbol
		end
	end
	return ""
end

function M.find(layouts, symbol)
	for _, entry in ipairs(layouts) do
		if entry.symbol == symbol then return entry end
	end
	return nil
end

function M.glyph(entry)
	return glyphs[entry.name] or "layout"
end

function M.label(entry)
	if glyphs[entry.name] then return noctalia.tr("name_" .. entry.name) end
	return (entry.name:gsub("_", " "):gsub("^%l", string.upper))
end

function M.visible(entry)
	if not glyphs[entry.name] or entry.name == "floating" then return true end
	local value = noctalia.getConfig("show_" .. entry.name)
	return value == nil or value == true or value == "true"
end

return M