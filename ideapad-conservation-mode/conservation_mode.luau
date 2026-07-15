--!nonstrict
-- Control-center [[shortcut]] entry: toggles Lenovo IdeaPad/Legion battery
-- Conservation Mode (caps charging around ~60% to preserve battery health)
-- via the ideapad_acpi driver's conservation_mode sysfs attribute.
--
-- Writing that attribute needs root by default. The first time a write
-- fails, onClick() opens a terminal running a bundled one-time setup script
-- (scripts/setup-permissions.sh) via sudo, instead of just failing -- see
-- that script for what it changes. Every write after that is a plain,
-- unprivileged noctalia.writeFile().

local DRIVER_DIR = "/sys/bus/platform/drivers/ideapad_acpi"
local ATTR_NAME = "conservation_mode"

-- The ACPI instance name (e.g. "VPC2004:00") isn't hardcoded: we discover it
-- by scanning the driver's bound devices, so this keeps working if it ever
-- differs. Cached in plugin state under a generic key since other future
-- entries (fan mode, camera power, ...) live under the same device dir.
local function findDevicePath()
  local cached = noctalia.state.get("ideapad_device_path")
  if cached then
    return cached
  end

  local entries = noctalia.listDir(DRIVER_DIR)
  if not entries then
    return nil
  end

  for _, name in ipairs(entries) do
    if name ~= "uevent" and name ~= "bind" and name ~= "unbind" and name ~= "module" then
      local path = DRIVER_DIR .. "/" .. name
      if noctalia.fileExists(path .. "/" .. ATTR_NAME) then
        noctalia.state.set("ideapad_device_path", path)
        return path
      end
    end
  end

  return nil
end

local function attrPath()
  local devicePath = findDevicePath()
  if not devicePath then
    return nil
  end
  return devicePath .. "/" .. ATTR_NAME
end

-- true/false for a known state, nil when the attribute couldn't be read.
local function readState()
  local path = attrPath()
  if not path then
    return nil
  end
  local contents = noctalia.readFile(path)
  if not contents then
    return nil
  end
  return noctalia.string.trim(contents) == "1"
end

local function render(on, enabled)
  shortcut.setLabel(if on then "Conservation On" else "Conservation Off")
  shortcut.setIcon("battery-charging", "battery")
  shortcut.setActive(on)
  shortcut.setEnabled(enabled)
end

local on = readState()
render(on == true, on ~= nil)
if on == nil then
  shortcut.setLabel("Conservation N/A")
end

function onClick()
  local path = attrPath()
  if not path then
    noctalia.notifyError("Conservation Mode", "Could not find the ideapad_acpi conservation_mode sysfs file on this machine.")
    return
  end

  local current = readState()
  if current == nil then
    noctalia.notifyError("Conservation Mode", "Could not read the current conservation_mode state.")
    return
  end

  local flipped = not current
  local ok, err = noctalia.writeFile(path, if flipped then "1" else "0")
  if ok then
    render(flipped, true)
    noctalia.notify(
      "Conservation Mode",
      if flipped then "Enabled - charging capped for battery health." else "Disabled - charging to 100%."
    )
    return
  end

  render(current, true)
  runSetup(err)
end

-- Not set up yet (or permissions regressed): run the bundled setup script in
-- a terminal via sudo. Deliberately not pkexec -- minimal Wayland setups
-- (niri, sway, ...) commonly have no polkit GUI agent registered, so pkexec
-- would fail silently with no prompt at all. A terminal + sudo has no such
-- dependency.
function runSetup(writeErr)
  local pluginDir = noctalia.pluginDir()
  if not pluginDir then
    noctalia.notifyError(
      "Conservation Mode",
      "Failed to write conservation_mode (" .. (writeErr or "permission denied") .. ") and could not locate the plugin directory to run setup."
    )
    return
  end

  local setupScript = pluginDir .. "/scripts/setup-permissions.sh"
  local user = noctalia.string.trim(noctalia.getenv("USER") or "")
  local cmd = "sudo "
    .. setupScript
    .. " "
    .. user
    .. " && echo && echo 'Setup complete. Log out and back in, then click the tile again.' && read -r -p 'Press Enter to close...'"

  if noctalia.runInTerminal(cmd) then
    noctalia.notify("Conservation Mode", "One-time setup needed - check the terminal window that just opened.")
  else
    noctalia.notifyError(
      "Conservation Mode",
      "Failed to write conservation_mode (" .. (writeErr or "permission denied") .. "). Run scripts/setup-permissions.sh with sudo manually, then log out and back in."
    )
  end
end
