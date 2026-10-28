--!nonstrict
-- Widget helpers (the same file ships with the Keychron and Xbox plugins):
-- config access, battery glyphs, bar coloring, low/full notifications and a
-- tiny key=value state file in the plugin data dir.

local common = {}

-- Config values arrive untyped; widgets read their settings with these so the
-- keys stay literal in the entry file (noctalia plugins lint checks them).
function common.int(value, fallback)
	return tonumber(value) or fallback
end

function common.bool(value, fallback)
	if value == nil then
		return fallback
	end
	return value == true
end

-- Battery glyph with a fill level, for the "battery glyph" and icon-only modes.
function common.batteryGlyph(level, charging)
	if charging then
		return "battery-charging"
	elseif level == nil then
		return "battery-off"
	elseif level >= 88 then
		return "battery-4"
	elseif level >= 63 then
		return "battery-3"
	elseif level >= 38 then
		return "battery-2"
	elseif level >= 13 then
		return "battery-1"
	end
	return "battery"
end

-- Picks glyph and text for the bar according to the display settings
-- (cfg.iconOnly, cfg.batteryGlyph).
function common.present(cfg, deviceGlyph, level, charging, text)
	local glyph
	if cfg.iconOnly or cfg.batteryGlyph then
		glyph = common.batteryGlyph(level, charging)
	else
		glyph = charging and "battery-charging" or deviceGlyph
	end
	barWidget.setGlyph(glyph)
	barWidget.setText(cfg.iconOnly and "" or text)
end

-- Sets text and glyph color to a theme role; "" hands it back to the bar.
function common.setRole(role)
	barWidget.setColor(role)
	barWidget.setGlyphColor(role)
end

-- "just now" / "5 min ago" / "2 h ago" for a unix timestamp.
function common.formatAge(timestamp)
	local seconds = math.max(0, os.time() - timestamp)
	if seconds < 60 then
		return noctalia.tr("age.just_now")
	elseif seconds < 3600 then
		return noctalia.tr("age.minutes", { n = seconds // 60 })
	end
	return noctalia.tr("age.hours", { n = seconds // 3600 })
end

-- Fires one notification when a device drops to the low threshold and one
-- when it is fully charged. Each re-arms only after the battery left that
-- state (charger plugged in / unplugged), so a level hovering around the
-- threshold does not spam.
-- Uses cfg.lowThreshold, cfg.notifyLow and cfg.notifyFull.
local alerts = {}
function common.checkAlerts(cfg, id, name, level, charging)
	if level == nil then
		return
	end
	local state = alerts[id]
	if state == nil then
		-- First reading after start: arm without notifying about the past.
		state = { lowSent = false, fullSent = level >= 100 }
		alerts[id] = state
	end

	if charging or level > cfg.lowThreshold then
		state.lowSent = false
	elseif not state.lowSent then
		state.lowSent = true
		if cfg.notifyLow then
			noctalia.notify(noctalia.tr("notify.low_title", { name = name }), noctalia.tr("notify.low_body", { level = level }))
		end
	end

	if not charging then
		state.fullSent = false
	elseif level >= 100 and not state.fullSent then
		state.fullSent = true
		if cfg.notifyFull then
			noctalia.notify(noctalia.tr("notify.full_title", { name = name }))
		end
	end
end

function common.forgetAlerts(id)
	alerts[id] = nil
end

-- Flat key=value state file, so a restart of the shell keeps the last reading.
local function statePath(name)
	local dir = noctalia.pluginDataDir()
	return dir and `{dir}/{name}.state` or nil
end

function common.loadState(name)
	local path = statePath(name)
	local content = path and noctalia.readFile(path)
	if not content then
		return nil
	end
	local state = {}
	for key, value in content:gmatch("([%w_]+)=([^\n]*)") do
		state[key] = value
	end
	return state
end

function common.saveState(name, state)
	local path = statePath(name)
	if not path then
		return
	end
	local lines = {}
	for key, value in pairs(state) do
		table.insert(lines, `{key}={value}`)
	end
	local ok, err = noctalia.writeFile(path, table.concat(lines, "\n") .. "\n")
	if not ok then
		noctalia.log(`could not save {name} state: {err}`)
	end
end

return common
