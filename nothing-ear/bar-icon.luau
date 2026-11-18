--!nonstrict
-- Bar icon color. Noctalia colors font glyphs with the bar's "Widget Icon
-- Color" setting but never tints images, so the widget recolors its own SVGs:
-- it works out the icon color the bar would give a glyph in this slot, writes
-- a tinted copy of the dark icon to the plugin's data folder and shows that.
-- Anything missing (no palette access, unknown role, write error) falls back
-- to the plain dark/light icons.

local M = {}

local OWN_TYPE = "zyrex/nothing-ear:nothing-ear"
-- In the dark icon set: the line color, and the "knockout" color behind the
-- noise-mode badge (cutout ring, transparency glyph). Red and white accents
-- stay as drawn.
local LINE = "#E6E1E5"
local KNOCKOUT = "#1D1B20"
local SUBDIR = "bar-icons"

-- Read once per config change: getSetting warns on paths that don't exist,
-- so only whole tables are read and the fields are looked up here.
local barConfig = nil
local widgetConfig = nil

local function readSetting(path)
	if type(noctalia.getSetting) ~= "function" then
		return nil
	end
	local ok, value = pcall(noctalia.getSetting, path)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

function M.reloadSettings()
	barConfig = readSetting("bar")
	widgetConfig = readSetting("widget")
end

local function isOurs(name)
	if name == OWN_TYPE then
		return true
	end
	local entry = widgetConfig and widgetConfig[name]
	return type(entry) == "table" and entry.type == OWN_TYPE
end

local function laneHas(lane, bar)
	if type(lane) ~= "table" then
		return nil
	end
	for _, token in ipairs(lane) do
		if type(token) == "string" then
			local groupId = token:match("^group:(.+)$")
			if groupId then
				for _, group in ipairs(type(bar.capsule_group) == "table" and bar.capsule_group or {}) do
					if type(group) == "table" and group.id == groupId and group.enabled ~= false then
						for _, member in ipairs(type(group.members) == "table" and group.members or {}) do
							if isOurs(member) then
								return member, group
							end
						end
					end
				end
			elseif isOurs(token) then
				return token, nil
			end
		end
	end
	return nil
end

-- First enabled bar (in bar.order) holding this widget: its widget name,
-- bar table and capsule group, if any. Per-monitor overrides only count for
-- an exact connector match.
local function findSlot(outputName)
	if barConfig == nil then
		return nil
	end
	local order = type(barConfig.order) == "table" and barConfig.order or {}
	for _, barName in ipairs(order) do
		local bar = barConfig[barName]
		if type(bar) == "table" and bar.enabled ~= false then
			for _, laneName in ipairs({ "start", "center", "end" }) do
				local name, group = laneHas(bar[laneName], bar)
				if name then
					local monitor = nil
					if outputName and type(bar.monitor) == "table" then
						for _, override in pairs(bar.monitor) do
							if type(override) == "table" and override.match == outputName then
								monitor = override
								break
							end
						end
					end
					local widget = widgetConfig and widgetConfig[name]
					return {
						widget = type(widget) == "table" and widget or {},
						bar = bar,
						monitor = monitor or {},
						group = group,
					}
				end
			end
		end
	end
	return nil
end

local function firstString(...)
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if type(value) == "string" and value:match("%S") then
			return value
		end
	end
	return nil
end

-- Color role or hex (#RGB, #RGBA, #RRGGBB, #RRGGBBAA) -> "#RRGGBB" or nil.
-- Alpha is dropped.
function M.toHex(spec)
	if type(spec) ~= "string" then
		return nil
	end
	spec = spec:match("^%s*(.-)%s*$")
	local digits = spec:match("^#(%x+)$")
	if digits then
		if #digits == 3 or #digits == 4 then
			local r, g, b = digits:sub(1, 1), digits:sub(2, 2), digits:sub(3, 3)
			return ("#" .. r .. r .. g .. g .. b .. b):upper()
		elseif #digits == 6 or #digits == 8 then
			return ("#" .. digits:sub(1, 6)):upper()
		end
		return nil
	end
	if type(noctalia.getColor) ~= "function" then
		return nil
	end
	local ok, hex = pcall(noctalia.getColor, spec)
	if ok and type(hex) == "string" and hex:match("^#%x%x%x%x%x%x") then
		return hex:sub(1, 7):upper()
	end
	return nil
end

-- The color specs the bar would use for a glyph in this slot, following
-- Noctalia's order: icon_color (widget, group, bar) -> color (widget, group,
-- bar) -> capsule foreground -> on_surface. The background is what shows
-- behind the icon: the capsule fill, or the bar's surface.
function M.specs(outputName)
	local slot = findSlot(outputName)
	if slot == nil then
		return "on_surface", "surface"
	end
	local w, b, m, g = slot.widget, slot.bar, slot.monitor, slot.group
	local capsule
	if g then
		capsule = true
	elseif w.capsule ~= nil then
		capsule = w.capsule == true
	else
		capsule = (m.capsule ~= nil and m.capsule or b.capsule) == true
	end
	local groupColor = g and g.foreground or nil
	local capsuleFg = capsule and firstString(w.capsule_foreground, m.capsule_foreground, b.capsule_foreground) or nil
	local icon = firstString(
		w.icon_color, groupColor, m.icon_color, b.icon_color,
		w.color, groupColor, m.color, b.color,
		capsuleFg, "on_surface"
	)
	local background = "surface"
	if capsule then
		background = firstString(g and g.fill, w.capsule_fill, m.capsule_fill, b.capsule_fill, "surface_container")
	end
	return icon, background
end

-- Resolved "#RRGGBB" line and knockout colors, or nil to use the plain icons.
function M.colors(outputName)
	local iconSpec, backgroundSpec = M.specs(outputName)
	local line = M.toHex(iconSpec)
	if line == nil then
		return nil
	end
	return line, M.toHex(backgroundSpec) or M.toHex("surface") or KNOCKOUT
end

local lastKey = nil

local function clearOld(dir, keep)
	local names = noctalia.listDir(dir)
	if type(names) ~= "table" then
		return
	end
	for _, name in ipairs(names) do
		if name:match("%.svg$") and not name:find(keep, 1, true) then
			noctalia.removeFile(dir .. "/" .. name)
		end
	end
end

-- Path of icons/bar-<name>.svg tinted line/knockout, or nil on any failure.
function M.tinted(name, line, knockout)
	if type(noctalia.pluginDataDir) ~= "function" then
		return nil
	end
	local base = noctalia.pluginDataDir()
	if type(base) ~= "string" then
		return nil
	end
	local dir = base .. "/" .. SUBDIR
	local key = line:sub(2) .. "-" .. knockout:sub(2)
	local path = dir .. "/bar-" .. name .. "-" .. key .. ".svg"
	if key ~= lastKey then
		if not noctalia.mkdirAll(dir) then
			return nil
		end
		clearOld(dir, "-" .. key .. ".svg")
		lastKey = key
	end
	if noctalia.fileExists(path) then
		return path
	end
	local source = noctalia.readFile(noctalia.pluginDir() .. "/icons/bar-" .. name .. ".svg")
	if type(source) ~= "string" then
		return nil
	end
	-- One pass, so a line color equal to the knockout isn't swapped twice.
	local swap = { [LINE] = line, [KNOCKOUT] = knockout }
	local svg = source:gsub("#%x%x%x%x%x%x", function(hex)
		return swap[hex:upper()]
	end)
	if not noctalia.writeFile(path, svg) then
		return nil
	end
	return path
end

return M
