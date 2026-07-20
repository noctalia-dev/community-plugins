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
  shortcut.setLabel(noctalia.tr("shortcut.label"))
  shortcut.setIcon("battery-charging", "battery")
  shortcut.setActive(on)
  shortcut.setEnabled(enabled)
end

local on = readState()
render(on == true, on ~= nil)
if on == nil then
  shortcut.setLabel(noctalia.tr("shortcut.na"))
end

function onClick()
  local path = attrPath()
  if not path then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.device_not_found"))
    return
  end

  local current = readState()
  if current == nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.read_failed"))
    return
  end

  local flipped = not current
  local ok, err = noctalia.writeFile(path, if flipped then "1" else "0")
  if ok then
    render(flipped, true)
    noctalia.notify(
      noctalia.tr("title"),
      noctalia.tr(if flipped then "notify.enabled" else "notify.disabled")
    )
    return
  end

  render(current, true)
  runSetup(err)
end

-- POSIX single-quote escaping: wraps s in '...', turning any embedded ' into
-- '\'' so the result is safe to splice into a shell command string. Needed
-- because pluginDir and $USER are attacker/environment-influenced strings
-- spliced into a command that runs through sh -lc.
local function shQuote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
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
      noctalia.tr("title"),
      noctalia.tr("error.write_failed", { error = writeErr or "permission denied" })
    )
    return
  end

  local setupScript = pluginDir .. "/scripts/setup-permissions.sh"
  local user = noctalia.string.trim(noctalia.getenv("USER") or "")
  local cmd = "sudo "
    .. shQuote(setupScript)
    .. " "
    .. shQuote(user)
    .. " && echo && echo 'Setup complete. Log out and back in, then click the tile again.' && read -r -p 'Press Enter to close...'"

  if noctalia.runInTerminal(cmd) then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("notify.setup_needed"))
  else
    noctalia.notifyError(
      noctalia.tr("title"),
      noctalia.tr("error.write_failed_manual", { error = writeErr or "permission denied" })
    )
  end
end
