--!nonstrict
-- Key bindings from settings, such as "SUPER + Space". Each is added to Hyprland while
-- Noctalia runs, never written to its config. A key that is already bound is left alone, and
-- Hyprland drops added bindings when it reloads, so check() runs again from the service's
-- update tick (DESIGN.md, section 10.7).

local Keybind = {}
Keybind.__index = Keybind

local MODIFIERS = { SHIFT = 1, CAPS = 2, CTRL = 4, CONTROL = 4, ALT = 8, MOD2 = 16, MOD3 = 32, SUPER = 64, MOD5 = 128 }

local function onHyprland()
  return noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil and noctalia.commandExists("hyprctl")
end

local function quoted(value)
  return string.format("%q", tostring(value))
end

-- "SUPER + SHIFT + Space" -> modmask 65, key "Space", and the older form "SUPER SHIFT,Space".
local function parseKey(text)
  local parts = {}
  for part in text:gmatch("[^+]+") do
    table.insert(parts, noctalia.string.trim(part))
  end
  local key = table.remove(parts)
  if key == nil or key == "" then
    return nil
  end
  local mask = 0
  for _, modifier in ipairs(parts) do
    local value = MODIFIERS[modifier:upper()]
    if value == nil then
      return nil
    end
    mask += value
  end
  -- A letter or digit alone would take that key from typing.
  if mask == 0 and #key == 1 then
    return nil
  end
  return mask, key, table.concat(parts, " ") .. "," .. key
end

local function unbind(key)
  local _, _, legacy = parseKey(key)
  noctalia.runAsync({ "hyprctl", "eval", `hl.unbind({quoted(key)})` }, function(result)
    if noctalia.string.trim(result.stdout or "") ~= "ok" then
      noctalia.runAsync({ "hyprctl", "keyword", "unbind", legacy or key })
    end
  end)
end

-- The binding of setting <setting> to shell command <command>.
function Keybind.new(setting, command)
  return setmetatable({ setting = setting, command = command, bound = nil, warned = nil, checking = false, again = false }, Keybind)
end

-- Binds the setting's key, once, unless the key is taken.
function Keybind:check()
  if not onHyprland() then
    return
  end
  -- One check at a time; a change while one runs checks again after it.
  if self.checking then
    self.again = true
    return
  end
  local wanted = noctalia.string.trim(noctalia.getConfig(self.setting) or "")
  if self.bound and self.bound ~= wanted then
    unbind(self.bound)
    self.bound = nil
  end
  if wanted == "" then
    return
  end
  local mask, key, legacy = parseKey(wanted)
  if mask == nil then
    if self.warned ~= wanted then
      self.warned = wanted
      noctalia.notifyError(noctalia.tr("keybind.invalid_title"), noctalia.tr("keybind.invalid", { key = wanted }))
    end
    return
  end
  self.checking = true
  noctalia.runAsync({ "hyprctl", "-j", "binds" }, function(result)
    self.checking = false
    if self.again or noctalia.string.trim(noctalia.getConfig(self.setting) or "") ~= wanted then
      self.again = false
      self:check()
      return
    end
    local binds = result.exitCode == 0 and noctalia.json.decode(result.stdout or "") or {}
    for _, bind in ipairs(type(binds) == "table" and binds or {}) do
      if bind.modmask == mask and tostring(bind.key):lower() == key:lower() then
        if self.bound ~= wanted and self.warned ~= wanted then
          self.warned = wanted
          noctalia.notifyError(noctalia.tr("keybind.taken_title"), noctalia.tr("keybind.taken", { key = wanted }))
        end
        return
      end
    end
    -- Not bound: either never added, or dropped by a Hyprland reload. The check stays busy
    -- until Hyprland has it, so the key is never bound twice.
    self.bound = wanted
    self.checking = true
    local function done()
      self.checking = false
      if self.again then
        self.again = false
        self:check()
      end
    end
    noctalia.runAsync({ "hyprctl", "eval", `hl.bind({quoted(wanted)}, hl.dsp.exec_cmd({quoted(self.command)}))` },
      function(lua)
        if noctalia.string.trim(lua.stdout or "") ~= "ok" then
          noctalia.runAsync({ "hyprctl", "keyword", "bind", `{legacy},exec,{self.command}` }, done)
        else
          done()
        end
      end)
  end)
end

-- Takes the binding out again, when the plugin stops.
function Keybind:release()
  if self.bound then
    unbind(self.bound)
    self.bound = nil
  end
end

return Keybind
