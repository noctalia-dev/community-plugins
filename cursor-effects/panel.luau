--!nonstrict
-- Cursor Effects: switch Umbriel cursor themes and cursor shader effects.
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
local THEME_LABELS = { ["PRTS-Final"] = "PRTS Animated", ["PRTS-Final-Static"] = "PRTS Static" }
local HELPER = noctalia.pluginDir() .. "/bin/cursor_effects.py"

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
	local effects = {}
	if exists(SHADER_DIR) then
		local ok, entries = pcall(noctalia.listDir, SHADER_DIR)
		for _, dir in ipairs((ok and entries) or {}) do
			local text = readFile(SHADER_DIR .. "/" .. dir .. "/effect.toml")
			if text ~= "" and text:find('kind%s*=%s*"cursor"') then
				for preset in text:gmatch('%[effects%.preset%."([^"]+)"%]') do
					effects[#effects + 1] = preset
				end
			end
		end
	end
	table.sort(effects)
	return effects
end

local function current()
	local text = readFile(CONFIG)
	local theme = (text:match("%[input%.cursor%]([^%[]*)") or ""):match('theme%s*=%s*"([^"]*)"') or ""
	local effect = (text:match("%[effects%]([^%[]*)") or ""):match('cursor%s*=%s*"([^"]*)"') or "off"
	return theme, effect
end

local themes, effects = {}, {}

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

local status = ""

local function apply(kind, value)
	noctalia.runAsync({ "python3", HELPER, kind, value }, function(result)
		if result.exitCode ~= 0 then
			local message = result.stderr ~= "" and result.stderr or "helper failed"
			status = message:gsub("%s+$", ""):sub(1, 160)
		else
			status = ""
		end
		render()
	end)
end

function render()
	local activeTheme, activeEffect = current()
	local all = { "off" }
	for _, effect in ipairs(effects) do
		all[#all + 1] = effect
	end
	local rows = {
		ui.label({ text = noctalia.tr("panel.theme"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
		grid(themes, 4, function(theme)
			return ui.button({
				key = "theme-" .. theme,
				text = short(THEME_LABELS[theme] or theme),
				variant = "ghost",
				contentAlign = "start",
				selected = theme == activeTheme,
				onClick = function()
					apply("theme", theme)
				end,
			})
		end),
		ui.label({ text = noctalia.tr("panel.effect"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
		grid(all, 4, function(effect)
			return ui.button({
				key = "effect-" .. effect,
				text = effect == "off" and noctalia.tr("panel.off") or short(effect),
				variant = "ghost",
				contentAlign = "start",
				selected = effect == activeEffect,
				onClick = function()
					apply("effect", effect)
				end,
			})
		end),
	}

	panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		status ~= "" and ui.label({ text = status, fontSize = 12, color = "error" }) or ui.label({ text = "", fontSize = 1 }),
		ui.scroll({ flexGrow = 1, gap = 4 }, rows),
	}))
end

function onOpen(_context)
	themes = scanThemes()
	effects = scanEffects()
	render()
end

function onCloseClicked()
	panel.close()
end
