--!nonstrict
-- Labels and lists shared by the widget and the panel.

local M = {}

-- The host knows the language of the user: noctalia.tr resolves the dotted
-- key over the translation file of the current locale. The table loaded
-- here is only the fallback for a key the host does not know.
M.t = {}

function M.loadTranslations()
  local dir = noctalia.pluginDir()
  if dir == nil then
    return M.t
  end
  -- English is the base translation of the public plugin, so it is the
  -- fallback of the fallback; Spanish is loaded when English is missing.
  for _, lang in ipairs({ "en", "es" }) do
    local raw = noctalia.readFile(dir .. "/translations/" .. lang .. ".json")
    if raw ~= nil then
      local ok, data = pcall(noctalia.json.decode, raw)
      if ok and type(data) == "table" then
        M.t = data
        return M.t
      end
    end
  end
  return M.t
end

local PANEL_ID = "faminec/cmf-buds:panel"

-- Every tab of the panel is the same panel: the tab is a section of it,
-- not a different window.
function M.panel_id()
  return PANEL_ID
end

-- The entry points (widget, panel, service) live in separate VMs: the shared
-- state is passed through noctalia.state.
function M.last_tab()
  local value = noctalia.state.get("last_tab")
  if type(value) == "string" and (value == "sound" or value == "controls" or value == "actions" or value == "system") then
    return value
  end
  return "sound"
end

function M.set_last_tab(tab)
  if tab == "sound" or tab == "controls" or tab == "actions" or tab == "system" then
    noctalia.state.set("last_tab", tab)
  end
end

-- The plugin translations are nested (as the store requires) and the calls
-- use dotted paths ("button.refresh"), so the path is resolved inside the
-- table.
local function _resolve(tbl, path)
  local current = tbl
  for part in string.gmatch(path, "[^%.]+") do
    if type(current) ~= "table" then
      return nil
    end
    current = current[part]
    if current == nil then
      return nil
    end
  end
  return current
end

function M.tr(key, args)
  -- The host resolves the key in the language of the user; the local table
  -- is only used when the host does not know the key.
  local ok, value = pcall(noctalia.tr, key)
  local out = nil
  if ok and type(value) == "string" and value ~= "" then
    out = value
  end
  if out == nil or out == key then
    out = _resolve(M.t, key)
  end
  if out == nil then
    out = key
  end
  if args ~= nil then
    out = (string.gsub(tostring(out), "{(%w+)}", function(name)
      local value = args[name]
      if value == nil then
        return "{" .. name .. "}"
      end
      return tostring(value)
    end))
  end
  return tostring(out)
end

-- A key that may not exist: the fallback is shown instead of the raw key.
-- The dynamic keys (the gesture or the modifier of a rule the user wrote
-- by hand) can name something the translations do not know: showing
-- "shortcut.gesture.foo" to the user would be worse than showing "foo".
function M.trOr(key, fallback)
  local text = M.tr(key)
  if text == key then
    return tostring(fallback or "")
  end
  return text
end

-- The daemon sends stable error codes (not sentences): the text is resolved
-- here with the "error.code.<code>" keys, so the daemon never has to know
-- the language of the user. The technical detail (the output of an external
-- command, for example) travels apart and is appended in parentheses.
function M.error_text(code, detail)
  local key = "error.generic"
  if type(code) == "string" and code ~= "" then
    key = "error.code." .. code
  end
  local text = M.tr(key)
  if text == key then
    -- An unknown code: the generic message is better than showing the raw
    -- code to the user.
    text = M.tr("error.generic")
  end
  text = tostring(text)
  if type(detail) == "string" and detail ~= "" then
    text = text .. " (" .. detail .. ")"
  end
  return text
end

-- Poll interval of the daemon, in seconds. The range is the same as the
-- one of the manifest (20-300 s) and the same as the one the daemon
-- enforces: an out-of-range value is clamped, never ignored.
M.POLL_MIN = 20
M.POLL_MAX = 300
M.POLL_DEFAULT = 20

function M.poll_seconds()
  local value = tonumber(noctalia.getConfig("poll_seconds"))
  if value == nil then
    return M.POLL_DEFAULT
  end
  value = math.floor(value)
  if value < M.POLL_MIN then
    return M.POLL_MIN
  end
  if value > M.POLL_MAX then
    return M.POLL_MAX
  end
  return value
end

function M.anc_label(mode, level)
  if mode == "off" then
    return M.tr("anc.off")
  elseif mode == "transparency" then
    return M.tr("anc.transparency")
  elseif mode == "anc" then
    local lvl = M.tr("anc." .. (level or "high"))
    return M.tr("anc.cancel") .. " · " .. lvl
  end
  return "—"
end

function M.eq_label(preset)
  local key = "eq.preset." .. tostring(preset or "balanced")
  local out = M.tr(key)
  if out == nil or out == key then
    return tostring(preset or "—")
  end
  return out
end

function M.battery_detail(st)
  if st == nil then
    return "—"
  end
  local b = st.battery or {}
  local function part(label, value)
    if value == nil then
      return label .. " —"
    end
    return label .. " " .. tostring(value) .. "%"
  end
  return part("L", b.left) .. " · " .. part("R", b.right) .. " · " .. part("C", b.case)
end

function M.volume_text(st)
  local v = st and st.volume or {}
  if v.percent == nil then
    return "—"
  end
  if v.muted then
    return M.tr("volume.mute")
  end
  return tostring(v.percent) .. "%"
end

local ACTION_ALLOWED = {
  left = {
    double = { "play_pause", "skip_back", "skip_forward", "voice_assistant", "no_action" },
    triple = { "skip_back", "skip_forward", "voice_assistant", "no_action" },
    hold = { "noise_control", "voice_assistant", "no_action" },
    double_hold = { "volume_up", "volume_down", "voice_assistant", "no_action" },
  },
  right = {
    double = { "play_pause", "skip_back", "skip_forward", "voice_assistant", "no_action" },
    triple = { "skip_back", "skip_forward", "voice_assistant", "no_action" },
    hold = { "noise_control", "voice_assistant", "no_action" },
    double_hold = { "volume_up", "volume_down", "voice_assistant", "no_action" },
  },
  case = {
    single = { "play_pause", "skip_back", "skip_forward", "voice_assistant", "game_mode", "no_action" },
    double = { "play_pause", "skip_back", "skip_forward", "voice_assistant", "game_mode", "no_action" },
    triple = { "play_pause", "skip_back", "skip_forward", "voice_assistant", "game_mode", "no_action" },
    hold = { "noise_control", "voice_assistant", "game_mode", "no_action" },
    rotate = { "volume_control", "no_action" },
  },
}

local GROUPS = {
  left = { "double", "triple", "hold", "double_hold" },
  right = { "double", "triple", "hold", "double_hold" },
  case = { "single", "double", "triple", "hold", "rotate" },
}

function M.gesture_types(group)
  return GROUPS[group] or GROUPS.left
end

function M.action_keys(group, gesture)
  local g = ACTION_ALLOWED[group] or ACTION_ALLOWED.left
  return g[gesture] or g.double or { "no_action" }
end

function M.action_labels(keys)
  local out = {}
  for _, key in ipairs(keys) do
    table.insert(out, M.tr("action." .. key))
  end
  return out
end

function M.gesture_label(key)
  return M.tr("gesture." .. tostring(key or ""))
end

function M.fit_label(result)
  if result == 0 then
    return M.tr("fit.good")
  elseif result == 1 then
    return M.tr("fit.bad")
  end
  return M.tr("fit.error")
end

return M
