--!nonstrict
-- The keys of the hub, added to Hyprland while Noctalia runs, never written to its config
-- (DESIGN.md, section 10.7). A key that something else already binds is left alone and
-- reported as taken. Hyprland drops added bindings when it reloads, so sync() runs again
-- from the service's update tick. One sync runs at a time; a change while one runs syncs
-- again after it.

local Binds = {}

local MODIFIERS = { SHIFT = 1, CAPS = 2, CTRL = 4, CONTROL = 4, ALT = 8, MOD2 = 16, MOD3 = 32, SUPER = 64, MOD5 = 128 }

local ours = {} -- key as written -> command this plugin bound to it
local wanted = {} -- key as written -> command
local status = {} -- key as written -> "bound" | "taken" | "invalid"
local syncing = false
local again = false
local onStatus = nil

local function quoted(value)
  return string.format("%q", tostring(value))
end

-- "SUPER + SHIFT + K" -> modmask 65, key "K", and the older form "SUPER SHIFT,K". A letter or
-- digit alone would take that key from typing, so it needs a modifier.
function Binds.parse(text)
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
  if mask == 0 and #key == 1 then
    return nil
  end
  return mask, key, table.concat(parts, " ") .. "," .. key
end

function Binds.available()
  return noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil and noctalia.commandExists("hyprctl")
end

local function unbind(key)
  local _, _, legacy = Binds.parse(key)
  noctalia.runAsync({ "hyprctl", "eval", `hl.unbind({quoted(key)})` }, function(result)
    if noctalia.string.trim(result.stdout or "") ~= "ok" then
      noctalia.runAsync({ "hyprctl", "keyword", "unbind", legacy or key })
    end
  end)
end

local function bind(key, command, done)
  local _, _, legacy = Binds.parse(key)
  local exec = "noctalia msg " .. command
  noctalia.runAsync({ "hyprctl", "eval", `hl.bind({quoted(key)}, hl.dsp.exec_cmd({quoted(exec)}))` }, function(result)
    if noctalia.string.trim(result.stdout or "") ~= "ok" then
      noctalia.runAsync({ "hyprctl", "keyword", "bind", `{legacy},exec,{exec}` }, done)
    else
      done()
    end
  end)
end

local function finish()
  syncing = false
  if onStatus then
    onStatus(status)
  end
  if again then
    again = false
    Binds.sync()
  end
end

-- Brings Hyprland to the wanted keys: drops the ones no longer wanted, then adds the free ones.
function Binds.sync()
  if not Binds.available() then
    return
  end
  if syncing then
    again = true
    return
  end
  syncing = true
  for key, command in pairs(ours) do
    if wanted[key] ~= command then
      unbind(key)
      ours[key] = nil
    end
  end
  noctalia.runAsync({ "hyprctl", "-j", "binds" }, function(result)
    local present = {}
    local binds = result.exitCode == 0 and noctalia.json.decode(result.stdout or "") or {}
    for _, item in ipairs(type(binds) == "table" and binds or {}) do
      present[tostring(item.modmask) .. " " .. tostring(item.key):lower()] = true
    end
    status = {}
    local missing = {}
    for key, command in pairs(wanted) do
      local mask, name = Binds.parse(key)
      if mask == nil then
        status[key] = "invalid"
      elseif present[tostring(mask) .. " " .. name:lower()] then
        status[key] = ours[key] == command and "bound" or "taken"
      else
        -- Not bound: either never added, or dropped by a Hyprland reload.
        table.insert(missing, key)
      end
    end
    local left = #missing
    if left == 0 then
      finish()
      return
    end
    for _, key in ipairs(missing) do
      local command = wanted[key]
      ours[key] = command
      status[key] = "bound"
      bind(key, command, function()
        left -= 1
        if left == 0 then
          finish()
        end
      end)
    end
  end)
end

-- Sets the wanted keys, { key = command }, and syncs.
function Binds.set(keys)
  wanted = keys
  Binds.sync()
end

-- Calls <callback>(status) after each sync.
function Binds.watch(callback)
  onStatus = callback
end

-- Takes every key out again, when the plugin stops.
function Binds.release()
  for key in pairs(ours) do
    unbind(key)
  end
  ours = {}
end

return Binds
