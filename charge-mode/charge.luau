--!nonstrict
-- Control-center [[shortcut]]: cycles the battery charge type exposed by the
-- mainline `charge_types` power-supply attribute (kernel 6.15+):
-- Long_Life (conservation) -> Standard -> Fast (rapid charge).
--
-- The attribute is root-only. On the first click that fails to write, the
-- plugin runs setup.sh once; it installs a udev rule that chowns the attribute
-- to this user. Every later click writes directly, without a prompt.

local SUPPLY_DIR = "/sys/class/power_supply"
local ATTR = "charge_types"

local NEXT = { Long_Life = "Standard", Standard = "Fast", Fast = "Long_Life" }

local LABEL = {
  Long_Life = "label.long_life",
  Standard = "label.standard",
  Fast = "label.fast",
}

local ICON = {
  Long_Life = "shield-heart",
  Standard = "battery",
  Fast = "bolt",
}

local function attrPath()
  local entries = noctalia.listDir(SUPPLY_DIR)
  if not entries then
    return nil
  end
  for _, name in ipairs(entries) do
    local path = SUPPLY_DIR .. "/" .. name .. "/" .. ATTR
    if noctalia.fileExists(path) then
      return path
    end
  end
  return nil
end

-- "Fast Standard [Long_Life]" -> "Long_Life"
local function readActive(path)
  local contents = noctalia.readFile(path)
  if not contents then
    return nil
  end
  return string.match(contents, "%[([^%]]+)%]")
end

local function label(active)
  return noctalia.tr(LABEL[active] or "label.standard")
end

local function render(active)
  if not active then
    shortcut.setLabel(noctalia.tr("label.unavailable"))
    shortcut.setIcon("battery-off")
    shortcut.setActive(false)
    shortcut.setEnabled(false)
    return
  end
  shortcut.setLabel(label(active))
  shortcut.setIcon(ICON[active] or ICON.Standard)
  shortcut.setActive(active ~= "Standard")
  shortcut.setEnabled(true)
end

local function notifyChanged(path, fallback)
  -- Never trust the write alone: the firmware can refuse a change.
  local now = readActive(path) or fallback
  render(now)
  noctalia.notify(noctalia.tr("title"), noctalia.tr("notify.changed", { mode = label(now) }))
end

-- POSIX single-quote escaping for the terminal fallback command.
local function shQuote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function fail(message)
  noctalia.notifyError(noctalia.tr("title"), message)
end

-- pkexec cannot ask for credentials without a polkit agent. Only that case
-- falls back to a terminal; a dismissed or denied prompt must not, because the
-- user just said no.
local function noPolkitAgent(result)
  return string.find(string.lower(result.stderr or ""), "agent", 1, true) ~= nil
end

local function setupThenWrite(path, target, previous)
  local dir = noctalia.pluginDir()
  if not dir then
    render(previous)
    fail(noctalia.tr("error.no_plugin_dir"))
    return
  end
  local script = dir .. "/setup.sh"

  local function viaTerminal()
    if not noctalia.runInTerminal("sudo /bin/sh " .. shQuote(script)) then
      return false
    end
    render(previous)
    noctalia.notify(noctalia.tr("title"), noctalia.tr("notify.setup_running"))
    return true
  end
  local function viaPkexecFailed(result)
    render(previous)
    fail(noctalia.tr("error.setup_failed", { error = noctalia.string.trim(result.stderr or "") }))
  end

  if not noctalia.commandExists("pkexec") then
    if not viaTerminal() then
      render(previous)
      fail(noctalia.tr("error.setup_manual"))
    end
    return
  end

  noctalia.runAsync({ "pkexec", "/bin/sh", script }, function(result)
    if result.exitCode ~= 0 then
      if not (noPolkitAgent(result) and viaTerminal()) then
        viaPkexecFailed(result)
      end
      return
    end
    if noctalia.writeFile(path, target) then
      render(readActive(path) or target)
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notify.setup_done"))
    else
      render(previous)
      fail(noctalia.tr("error.write_failed"))
    end
  end)
end

function onClick()
  local path = attrPath()
  if not path then
    render(nil)
    return
  end
  -- A transient read failure still lets the tile cycle from Normal.
  local active = readActive(path) or "Standard"

  local target = NEXT[active] or "Standard"
  if noctalia.writeFile(path, target) then
    notifyChanged(path, target)
    return
  end

  render(active)
  setupThenWrite(path, target, active)
end

local initial = attrPath()
render(initial and readActive(initial))
