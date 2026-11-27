--!nonstrict
-- Cursor Effects: switch Umbriel cursor themes, size, and shader effects.
-- All config editing happens in bin/cursor_effects.py; this file only renders.
local HOME = noctalia.expandPath("~")
local function config_home()
	local value = noctalia.getenv("XDG_CONFIG_HOME")
	if value == nil or value == "" then
		return HOME .. "/.config"
	end
	return value
end
local CONFIG_HOME = config_home()
local CONFIG = CONFIG_HOME .. "/umbriel/config.toml"
local SHADER_DIR = CONFIG_HOME .. "/umbriel/shaders/community/cursor"
local ICON_DIRS = { HOME .. "/.local/share/icons", HOME .. "/.icons", "/usr/share/icons" }
local THEME_LABELS = {
	["PRTS-Final"] = "PRTS Animated",
	["PRTS-Final-Static"] = "PRTS Static",
	["Bibata-Modern-Classic"] = "Bibata",
	["Adwaita"] = "Adwaita",
}
local HELPER = noctalia.pluginDir() .. "/bin/cursor_effects.py"

local DEFAULT_THEME = "Bibata-Modern-Classic"
local DEFAULT_SIZE = 24
local DEFAULT_RADIUS = 96
local MIN_SIZE, MAX_SIZE = 16, 72
local MIN_RADIUS, MAX_RADIUS = 32, 256

local function exists(path)
	return noctalia.fileExists(path)
end

local function readFile(path)
	local ok, value = pcall(noctalia.readFile, path)
	if ok and type(value) == "string" then
		return value
	end
	return ""
end

local function clamp(value, minimum, maximum)
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

local function scanThemes()
	local seen, themes = {}, {}
	for _, dir in ipairs(ICON_DIRS) do
		if exists(dir) then
			local ok, entries = pcall(noctalia.listDir, dir)
			for _, name in ipairs((ok and entries) or {}) do
				local base = dir .. "/" .. name
				if not seen[name] and (exists(base .. "/cursors") or exists(base .. "/cursors_scalable")) then
					seen[name] = true
					themes[#themes + 1] = name
				end
			end
		end
	end
	table.sort(themes)
	return themes
end

local function scanEffects()
	local effects, radii, seen = {}, {}, {}
	if exists(SHADER_DIR) then
		local ok, entries = pcall(noctalia.listDir, SHADER_DIR)
		for _, dir in ipairs((ok and entries) or {}) do
			local text = readFile(SHADER_DIR .. "/" .. dir .. "/effect.toml")
			local position = 1
			while true do
				local start, finish, raw = text:find("%[effects%.preset%.([^%]]+)%]", position)
				if not start then
					break
				end
				position = finish + 1
				local array_table = start > 1 and text:sub(start - 1, start - 1) == "["
				local name = raw:match('^%s*"(.-)"%s*$')
					or raw:match("^%s*'(.-)'%s*$")
					or raw:match("^%s*([%w_%-]+)%s*$")
				local next_header = text:find("\n%s*%[", finish + 1)
				local body = text:sub(finish + 1, next_header and next_header - 1 or #text)
				if not array_table and name and not seen[name] and body:find('kind%s*=%s*["\']cursor["\']') then
					seen[name] = true
					effects[#effects + 1] = name
					local radius = tonumber(body:match("radius%s*=%s*(%d+)"))
					radii[name] = clamp(radius or DEFAULT_RADIUS, MIN_RADIUS, MAX_RADIUS)
				end
			end
		end
	end
	table.sort(effects)
	return effects, radii
end

local function readState()
	local text = readFile(CONFIG)
	local cursor = text:match("%[input%.cursor%]([^%[]*)") or ""
	local theme = cursor:match('theme%s*=%s*"([^"]*)"') or DEFAULT_THEME
	if theme == "" then
		theme = DEFAULT_THEME
	end
	local size = clamp(tonumber(cursor:match("size%s*=%s*(%d+)")) or DEFAULT_SIZE, MIN_SIZE, MAX_SIZE)
	local effect = (text:match("%[effects%]([^%[]*)") or ""):match('cursor%s*=%s*"([^"]*)"') or ""
	if effect == "" or effect == "off" then
		effect = "off"
	end
	return { theme = theme, size = size, effect = effect }
end

local themes, effects, radii = {}, {}, {}
local state = { theme = DEFAULT_THEME, size = DEFAULT_SIZE, effect = "off", radius = DEFAULT_RADIUS }
local status, status_error = "", false
local applying, pending = false, false

local function refresh()
	effects, radii = scanEffects()
	local next_state = readState()
	if next_state.effect ~= "off" then
		next_state.radius = radii[next_state.effect] or DEFAULT_RADIUS
	else
		next_state.radius = clamp(state.radius or DEFAULT_RADIUS, MIN_RADIUS, MAX_RADIUS)
	end
	state = next_state
end

local function grid(items, columns, make)
	local cols = {}
	for i = 1, columns do
		cols[i] = {}
	end
	for i, item in ipairs(items) do
		table.insert(cols[(i - 1) % columns + 1], make(item))
	end
	local children = {}
	for i = 1, columns do
		children[i] = ui.column({ flexGrow = 1, gap = 4 }, cols[i])
	end
	return ui.row({ gap = 10, align = "start" }, children)
end

local function short(text)
	if #text > 15 then
		return text:sub(1, 14) .. "…"
	end
	return text
end

local function statusLabel()
	if status == "" then
		return ui.label({ text = "", fontSize = 1 })
	end
	return ui.label({
		text = status,
		fontSize = 12,
		color = status_error and "error" or "primary",
		maxLines = 3,
	})
end

local function apply()
	if applying then
		pending = true
		return
	end
	applying = true
	status = noctalia.tr("panel.applying")
	status_error = false
	render()

	local theme = state.theme ~= "" and state.theme or DEFAULT_THEME
	local size = math.floor(clamp(state.size, MIN_SIZE, MAX_SIZE) + 0.5)
	local effect = state.effect ~= "" and state.effect or "off"
	local radius = math.floor(clamp(state.radius or DEFAULT_RADIUS, MIN_RADIUS, MAX_RADIUS) + 0.5)

	noctalia.runAsync({ "python3", HELPER, "set", theme, tostring(size), effect, tostring(radius) }, function(result)
		applying = false
		if result.exitCode ~= 0 then
			local message = result.stderr ~= "" and result.stderr or noctalia.tr("panel.helper_failed")
			status = message:gsub("%s+$", ""):sub(1, 240)
			status_error = true
		else
			status = noctalia.tr("panel.applied")
			status_error = false
			if effect ~= "off" then
				radii[effect] = radius
			end
		end
		render()
		if pending then
			pending = false
			apply()
		end
	end)
end

function render()
	local active = state
	local all = { "off" }
	for _, effect in ipairs(effects) do
		all[#all + 1] = effect
	end

	local controls = ui.row({ gap = 16, align = "start" }, {
		ui.column({ flexGrow = 1, gap = 4 }, {
			ui.row({ align = "center", justify = "space_between", gap = 8 }, {
				ui.label({ text = noctalia.tr("panel.size"), fontSize = 12, color = "on_surface_variant" }),
				ui.label({ text = tostring(math.floor(active.size + 0.5)) .. " px", fontSize = 12, color = "primary" }),
			}),
			ui.slider({
				key = "cursor-size",
				min = MIN_SIZE,
				max = MAX_SIZE,
				step = 1,
				value = active.size,
				flexGrow = 1,
				onChange = function(value)
					state.size = clamp(tonumber(value) or state.size, MIN_SIZE, MAX_SIZE)
					render()
				end,
				onDragEnd = function(value)
					state.size = clamp(tonumber(value) or state.size, MIN_SIZE, MAX_SIZE)
					apply()
				end,
			}),
		}),
		ui.column({ flexGrow = 1, gap = 4 }, {
			ui.row({ align = "center", justify = "space_between", gap = 8 }, {
				ui.label({ text = noctalia.tr("panel.radius"), fontSize = 12, color = "on_surface_variant" }),
				ui.label({
					text = active.effect == "off" and noctalia.tr("panel.off") or tostring(math.floor(active.radius + 0.5)),
					fontSize = 12,
					color = "primary",
				}),
			}),
			ui.slider({
				key = "cursor-radius",
				min = MIN_RADIUS,
				max = MAX_RADIUS,
				step = 8,
				value = active.radius,
				enabled = active.effect ~= "off",
				flexGrow = 1,
				onChange = function(value)
					state.radius = clamp(tonumber(value) or state.radius, MIN_RADIUS, MAX_RADIUS)
					render()
				end,
				onDragEnd = function(value)
					state.radius = clamp(tonumber(value) or state.radius, MIN_RADIUS, MAX_RADIUS)
					if state.effect ~= "off" then
						apply()
					end
				end,
			}),
		}),
	})

	local rows = {
		controls,
		ui.separator({ thickness = 1, color = "outline_variant/0.25" }),
		ui.label({ text = noctalia.tr("panel.theme"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
		#themes > 0 and grid(themes, 4, function(theme)
			return ui.button({
				key = "theme-" .. theme,
				text = short(THEME_LABELS[theme] or theme),
				variant = "ghost",
				contentAlign = "start",
				selected = theme == active.theme,
				onClick = function()
					if state.theme == theme then
						return
					end
					state.theme = theme
					apply()
				end,
			})
		end) or ui.label({ text = noctalia.tr("panel.no_themes"), fontSize = 12, color = "on_surface_variant" }),
		ui.label({ text = noctalia.tr("panel.effect"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
		grid(all, 4, function(effect)
			return ui.button({
				key = "effect-" .. effect,
				text = effect == "off" and noctalia.tr("panel.off") or short(effect),
				variant = "ghost",
				contentAlign = "start",
				selected = effect == active.effect,
				onClick = function()
					if state.effect == effect then
						return
					end
					state.effect = effect
					if effect ~= "off" then
						state.radius = radii[effect] or state.radius or DEFAULT_RADIUS
					end
					apply()
				end,
			})
		end),
	}

	panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
			ui.row({ gap = 4, align = "center" }, {
				ui.button({
					glyph = "refresh",
					variant = "ghost",
					onClick = function()
						themes = scanThemes()
						refresh()
						render()
					end,
				}),
				ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
			}),
		}),
		statusLabel(),
		ui.scroll({ flexGrow = 1, gap = 4 }, rows),
	}))
end

function onOpen(_context)
	themes = scanThemes()
	refresh()
	status = ""
	status_error = false
	render()
end

function onCloseClicked()
	panel.close()
end
