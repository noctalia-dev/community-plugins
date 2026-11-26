--!nonstrict
-- TUXEDO Control Center does not broadcast profile changes, so this service
-- polls its small D-Bus API and shares one snapshot with the panel and bar.

local STATE = "tuxedo_control_center.profiles"
local COMMAND = "tuxedo_control_center.command"
local BUS = "com.tuxedocomputers.tccd"
local PATH = "/com/tuxedocomputers/tccd"
local INTERFACE = "com.tuxedocomputers.tccd"

local inFlight = false
local lastCommand = nil

local snapshot = {
  available = false,
  loading = true,
  profiles = {},
  activeId = nil,
  error = nil,
}

-- The stock TCC profiles use legacy ids. Hiding them makes this panel a
-- focused selector for user-created profiles, while the ordinary PPD selector
-- continues to own the usual three broad power policies.
local function isDefaultProfile(profile)
  if type(profile) ~= "table" or type(profile.id) ~= "string" then
    return false
  end
  return profile.id:match("^__legacy_") ~= nil or profile.id == "__default_custom_profile__"
end

local function profileLabel(profile)
  return tostring(profile.name or profile.displayName or profile.id or "Unnamed profile")
end

local function publish(next)
  snapshot = next
  noctalia.state.set(STATE, snapshot)
end

local function decodeBusctlString(output)
  local ok, envelope = pcall(noctalia.json.decode, output or "")
  if not ok or type(envelope) ~= "table" or type(envelope.data) ~= "table" then
    return nil
  end
  return envelope.data[1]
end

local function decodeResult(output)
  local payload = decodeBusctlString(output)
  if type(payload) ~= "string" then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, payload)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function refresh()
  if inFlight then
    return
  end
  inFlight = true

  noctalia.runAsync({ "busctl", "--system", "--json=short", "call", BUS, PATH, INTERFACE, "GetProfilesJSON" }, function(result)
    if result.exitCode ~= 0 then
      inFlight = false
      publish({ available = false, loading = false, profiles = {}, activeId = nil,
        error = "Could not read TUXEDO Control Center profiles." })
      return
    end

    local profiles = decodeResult(result.stdout)
    if type(profiles) ~= "table" then
      inFlight = false
      publish({ available = false, loading = false, profiles = {}, activeId = nil,
        error = "TUXEDO Control Center returned invalid profile data." })
      return
    end

    noctalia.runAsync({ "busctl", "--system", "--json=short", "call", BUS, PATH, INTERFACE, "GetActiveProfileJSON" }, function(activeResult)
      inFlight = false
      local active = decodeResult(activeResult.stdout)
      local activeId = type(active) == "table" and active.id or snapshot.activeId
      local showDefaults = noctalia.getConfig("show_default_profiles") ~= false
      local visible = {}
      for _, profile in ipairs(profiles) do
        if type(profile) == "table" and type(profile.id) == "string" and (showDefaults or not isDefaultProfile(profile)) then
          visible[#visible + 1] = profile
        end
      end
      table.sort(visible, function(a, b) return profileLabel(a):lower() < profileLabel(b):lower() end)
      -- tccd can take several seconds to apply a profile. Keep the last known
      -- selection during a rare transient failure instead of replacing a usable
      -- selector with an error state.
      local activeRead = activeResult.exitCode == 0 and type(active) == "table" and type(active.id) == "string"
      local error = nil
      if not activeRead and snapshot.activeId == nil then
        error = "Could not read the active TUXEDO profile yet."
      end
      publish({ available = true, loading = false, profiles = visible, activeId = activeId, error = error })
    end, 10000)
  end, 10000)
end

local function setProfile(id)
  if type(id) ~= "string" or id == "" then
    return
  end
  publish({ available = snapshot.available, loading = true, profiles = snapshot.profiles, activeId = snapshot.activeId, error = nil })
  noctalia.runAsync({ "busctl", "--system", "--", "call", BUS, PATH, INTERFACE, "SetTempProfileById", "s", id }, function(result)
    if result.exitCode ~= 0 then
      publish({ available = snapshot.available, loading = false, profiles = snapshot.profiles, activeId = snapshot.activeId,
        error = "TUXEDO Control Center did not accept that profile." })
    end
    refresh()
  end, 10000)
end

noctalia.state.watch(COMMAND, function(command)
  if type(command) ~= "table" or command.nonce == lastCommand then
    return
  end
  lastCommand = command.nonce
  if command.action == "set" then
    setProfile(command.id)
  elseif command.action == "refresh" then
    refresh()
  end
end)

function update()
  refresh()
end

noctalia.setUpdateInterval(2000)
refresh()
