--!nonstrict
-- Shared state-key names and command helper used by panel.luau, service.luau
-- and desktop-widget.luau, so the three surfaces can't drift out of sync.

local M = {}

M.STATUS_KEY = "nothing_ear_status"
M.COMMAND_KEY = "nothing_ear_command"
M.DEVICES_KEY = "nothing_ear_devices"
-- Flips true/false as the desktop widget instance is added/removed (see
-- desktop-widget.luau's onExit), so service.luau's polling gate covers it
-- without a separate "enable polling" setting.
M.DESKTOP_ACTIVE_KEY = "nothing_ear_desktop_active"

M.ANC_MODES = {
	{ mode = "anc", glyph = "shield-check", labelKey = "panel.mode.anc" },
	{ mode = "transparency", glyph = "ear", labelKey = "panel.mode.transparency" },
	{ mode = "off", glyph = "volume-off", labelKey = "panel.mode.off" },
}

-- Wire index -> preset, mapped against the Nothing X app on a Nothing Ear (2)
-- (see PROTOCOL.md). Index 4 is unused; 5 is the user's custom EQ curve.
M.EQ_PRESETS = {
	{ index = 0, name = "balanced" },
	{ index = 3, name = "more_bass" },
	{ index = 2, name = "more_treble" },
	{ index = 1, name = "voice" },
	{ index = 5, name = "custom" },
}

function M.isEqPreset(index)
	for _, preset in ipairs(M.EQ_PRESETS) do
		if preset.index == index then
			return true
		end
	end
	return false
end

-- ui.toggle's onChange hands back the new value as the string "true"/"false",
-- not a Lua boolean, so a plain `value == true` in the command handler is
-- always false regardless of which way the toggle was clicked. Route every
-- bool-shaped command value through this instead of comparing directly.
function M.toBool(value)
	if value == true or value == "true" then
		return true
	end
	return false
end

local commandSeq = 0

function M.sendCommand(action, value, strength)
	commandSeq += 1
	noctalia.state.set(M.COMMAND_KEY, {
		action = action,
		value = value,
		strength = strength,
		nonce = tostring(noctalia.nowMs()) .. "-" .. tostring(commandSeq),
	})
end

return M
