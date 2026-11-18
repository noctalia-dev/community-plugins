--!nonstrict
-- The sheets on the desktop, as opposed to the notes behind them.
--
-- A desktop widget's rotation, the background panel Noctalia draws behind it,
-- and the widget entry itself are host state in settings.toml, and no plugin
-- call writes them. So everything here either reads that file or shells out to
-- tools/noctes-widget, which is the only thing in noctes that writes outside
-- its own data directory.
--
-- Nothing in here knows what a note contains.

local M = {}

local SETTINGS_PATH = "~/.local/state/noctalia/settings.toml"
local WIDGET_TYPE = "remo/noctes:note"
local TIMEOUT_MS = 10000

-- Whether the helper can run at all: nil until the probe answers, false when
-- python3 is missing or the script is not executable. Notes work either way;
-- only the sheets on the desktop need it.
M.ready = nil

local toldAboutTool = false

local function tool()
  local dir = noctalia.pluginDir()
  if dir == nil then
    noctalia.log("noctes: no plugin dir, cannot reach the widget tool")
    return nil
  end
  return dir .. "/tools/noctes-widget"
end

-- State about this machine's desk. Kept in the plugin's own data directory
-- rather than beside notes.json, because `save_path` can be a synced folder
-- and another machine's settings.toml has sheets of its own.
local function localFile(name)
  local dir = noctalia.pluginDataDir()
  if dir == nil or dir == "" then
    return nil
  end
  noctalia.mkdirAll(dir)
  return dir .. "/" .. name
end

local function failed()
  noctalia.notifyError(noctalia.tr("notify.add_failed.title"),
    noctalia.tr("notify.add_failed.body"))
end

-- Said once per run. The helper being gone is a standing condition, not an
-- event, and one notification per click on a sheet would be its own problem.
local function missing()
  if toldAboutTool then
    return
  end
  toldAboutTool = true
  noctalia.notifyError(noctalia.tr("notify.no_tool.title"), noctalia.tr("notify.no_tool.body"))
end

-- Every command below goes through here first. A probe that has not answered
-- yet is treated as usable: the call is what finds out.
local function usable()
  if M.ready == false then
    missing()
    return false
  end
  return true
end

-- Runs the helper. Returns whether it started; onDone, when given, receives the
-- result once it exits, and is never called for a run that did not start.
local function run(argv, onDone)
  local started = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("noctes: noctes-widget " .. tostring(argv[2]) .. " failed: "
        .. tostring(result.stderr))
    end
    if onDone ~= nil then
      onDone(result)
    end
  end, TIMEOUT_MS)
  return started ~= false
end

-- `--help` exits 0 without reading or writing settings.toml, so it answers the
-- three questions that matter as one: the script ships, it is executable, and
-- there is a python3 to run it.
function M.probe(onDone)
  local path = tool()
  local answered = false

  local function settle(ready)
    if answered then
      return
    end
    answered = true
    M.ready = ready
    if not ready then
      noctalia.log("noctes: tools/noctes-widget will not run; sheets are unavailable")
    end
    if onDone ~= nil then
      onDone(ready)
    end
  end

  if path == nil then
    settle(false)
    return
  end

  local started = noctalia.runAsync({ path, "--help" }, function(result)
    settle(result.exitCode == 0)
  end, 5000)

  if not started then
    settle(false)
  end
end

-- The helper picks the key, since the keys already spoken for are split between
-- the note list and settings.toml, and reports it as `key=` on its first line
-- and the output the sheet went to as `output=` on its second.
local function field(stdout, name)
  local found = string.match("\n" .. (stdout or ""), "\n" .. name .. "=([^\n]+)")
  return found ~= nil and noctalia.string.trim(found) or nil
end

-- Logical size of one output, which is what a sheet's cx/cy are stored against.
local function logicalSize(screen)
  return math.floor(screen.width / (screen.scale or 1)),
    math.floor(screen.height / (screen.scale or 1))
end

-- The connected outputs, and the one a sheet should land on: the focused one,
-- else the first. Only connected outputs are candidates - the name the
-- compositor reports as focused can be a monitor that has just gone.
local function screens()
  local focused = noctalia.focusedOutputName()
  local all, target = {}, nil
  for _, screen in ipairs(noctalia.outputs()) do
    local width, height = logicalSize(screen)
    local entry = { name = screen.name, width = width, height = height }
    table.insert(all, entry)
    if target == nil or screen.name == focused or screen.focused then
      target = entry
    end
  end
  return target, all
end

local function sizeOf(screen)
  return string.format("%dx%d", screen.width, screen.height)
end

-- ── Reading the desk ────────────────────────────────────────────────────────

-- Every desktop widget in settings.toml as { id, type, output, key }, and the
-- ids [desktop_widgets] widget_order lists, read line by line the way the
-- helper reads the file: a table runs until the next line that opens one, so
-- a `[` inside a quoted value cannot cut it short. widget_order comes on one
-- line or wrapped over many, whichever toml++ chose.
local function widgetsIn(contents)
  local widgets, order, listed = {}, {}, {}
  local current, section, collecting = nil, nil, false

  for line in string.gmatch(contents .. "\n", "([^\n]*)\n") do
    if collecting then
      for id in string.gmatch(line, '"([^"]*)"') do
        listed[id] = true
      end
      collecting = not string.find((string.gsub(line, '"[^"]*"', "")), "]", 1, true)
    elseif string.match(line, "^%s*%[") then
      local id, rest = string.match(line, "^%s*%[desktop_widgets%.widget%.([%w%-]+)([%.%w]*)%]%s*$")
      current, section = nil, nil
      if string.match(line, "^%s*%[desktop_widgets%]%s*$") then
        section = "desktop"
      elseif id ~= nil and (rest == "" or rest == ".settings") then
        if widgets[id] == nil then
          widgets[id] = { id = id }
          table.insert(order, id)
        end
        current, section = widgets[id], rest == "" and "body" or "settings"
      end
    elseif section == "desktop" and string.match(line, "^%s*widget_order%s*=") then
      local value = string.match(line, "=(.*)$")
      for id in string.gmatch(value, '"([^"]*)"') do
        listed[id] = true
      end
      collecting = not string.find((string.gsub(value, '"[^"]*"', "")), "]", 1, true)
    elseif current ~= nil then
      local name, value = string.match(line, '^%s*([%w_]+)%s*=%s*"([^"]*)"')
      if section == "body" and (name == "type" or name == "output") then
        current[name] = value
      elseif section == "settings" and name == "key" then
        current.key = value
      end
    end
  end

  local list = {}
  for _, id in ipairs(order) do
    table.insert(list, widgets[id])
  end
  return list, listed
end

-- Which keys actually have a sheet, and on which output. The panel needs this
-- to tell a stuck note from a loose one, and a sheet on the other monitor is
-- the usual reason a note looks like it exists nowhere.
--
-- onResult also gets the number of sheets with no key at all - the ones
-- Noctalia's own widget editor produces, since a plugin cannot fill in a
-- widget's settings as it is created - and the set of ids widget_order lists.
function M.boundKeys(onResult)
  noctalia.readFileAsync(noctalia.expandPath(SETTINGS_PATH), function(contents, err)
    if contents == nil then
      noctalia.log("noctes: cannot read settings: " .. tostring(err))
      return
    end

    local widgets, listed = widgetsIn(contents)
    local bound, loose = {}, 0
    for _, widget in ipairs(widgets) do
      if widget.type == WIDGET_TYPE then
        if (widget.key or "") ~= "" then
          table.insert(bound, { key = widget.key, output = widget.output or "?", id = widget.id })
        else
          loose = loose + 1
        end
      end
    end

    onResult(bound, loose, listed)
  end)
end

-- The sheets this machine has seen, key -> widget id. Machine-local like the
-- tilt marker: a synced notes.json holds notes whose sheets live in another
-- machine's settings.toml, and those were never here to be deleted.
function M.remembered()
  local path = localFile("sheets.json")
  if path == nil or not noctalia.fileExists(path) then
    return {}
  end
  local decoded = noctalia.json.decode(noctalia.readFile(path) or "")
  return type(decoded) == "table" and decoded or {}
end

function M.remember(sheets)
  local path = localFile("sheets.json")
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode(sheets)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

-- ── Changing the desk ───────────────────────────────────────────────────────

-- Adds a sheet. `key` binds it to an existing note; without one the helper
-- generates a key avoiding everything in `avoid`. onKey receives the key used
-- and the output the sheet is on; onFail, when given, runs instead when the
-- helper ran and no sheet came of it.
-- `near` is the key of the sheet the new one should land beside.
--
-- Returns false when the helper could not even be started, which is the
-- caller's cue that no sheet is coming and a note is on its own.
function M.add(options, onKey, onFail)
  local path = tool()
  local target, all = screens()
  if target == nil then
    noctalia.log("noctes: no output to place a sheet on")
  end
  if path == nil or target == nil or not usable() then
    return false
  end

  local sizes = {}
  for _, screen in ipairs(all) do
    table.insert(sizes, screen.name .. "=" .. sizeOf(screen))
  end

  local argv = {
    path, "add",
    "--output", target.name,
    "--screen", sizeOf(target),
    "--geometry", table.concat(sizes, ","),
    "--avoid", table.concat(options.avoid or {}, ","),
  }
  -- The sheet the caller was looking at, for the helper to place the new one
  -- beside. It wins over the focused output, which is about windows: clicking a
  -- sheet or the panel leaves focus on whatever window is open behind them, so
  -- on its own it puts every new sheet on the screen being worked in.
  if (options.near or "") ~= "" then
    table.insert(argv, "--near")
    table.insert(argv, options.near)
  end
  if (options.key or "") ~= "" then
    table.insert(argv, "--key")
    table.insert(argv, options.key)
  end

  return run(argv, function(result)
    local key = result.exitCode == 0 and field(result.stdout, "key") or nil
    if key == nil then
      if result.exitCode == 0 then
        noctalia.log("noctes: noctes-widget gave no key")
      end
      failed()
      if onFail ~= nil then
        onFail()
      end
      return
    end
    onKey(key, field(result.stdout, "output"))
  end)
end

function M.remove(key, onDone)
  local path = tool()
  if path == nil or key == nil or key == "" or not usable() then
    return false
  end
  return run({ path, "remove", "--key", key }, onDone)
end

-- Adopts the sheets Noctalia's widget editor left keyless, square and framed,
-- and drops settings an older noctes left on its sheets. `avoid` is every key
-- the notes hold, so an adopted sheet never takes the key of a note whose own
-- sheet was deleted and starts showing that note.
function M.scatter(avoid, onDone)
  local path = tool()
  if path == nil or not usable() then
    return false
  end
  return run({ path, "scatter", "--avoid", table.concat(avoid or {}, ",") }, onDone)
end

-- Every sheet crooked, or every sheet square.
function M.tilt(crooked, onDone)
  local path = tool()
  if path == nil or not usable() then
    return false
  end
  return run({ path, "tilt", crooked and "--random" or "--square" }, onDone)
end

-- ── The crooked-sheets switch ───────────────────────────────────────────────
--
-- Rotation is host state, so this cannot be a render-time decision: turning
-- the switch off rewrites every sheet's angle. What was last applied is kept
-- in a file, not in memory, because the setting can change while the shell is
-- not running, and the next start has to notice.
--
-- The file is written only once the helper has done its part. Written before,
-- a helper that failed or was missing would leave it claiming a state the
-- sheets are not in, and nothing would ever try again.

local tiltWanted, tiltRunning = nil, false

function M.syncTilt(crooked)
  tiltWanted = crooked
  if tiltRunning then
    return
  end

  local marker = localFile("tilt.state")
  if marker == nil then
    return
  end
  local applied = "random"
  if noctalia.fileExists(marker) then
    applied = noctalia.string.trim(noctalia.readFile(marker) or "random")
  end
  if (applied == "random") == crooked then
    return
  end

  tiltRunning = true
  local started = M.tilt(crooked, function(result)
    tiltRunning = false
    if result.exitCode ~= 0 then
      return
    end
    noctalia.writeFile(marker, crooked and "random" or "square")
    -- Flipped again while the helper ran: catch up now.
    if tiltWanted ~= crooked then
      M.syncTilt(tiltWanted)
    end
  end)
  if not started then
    tiltRunning = false
  end
end

-- Sheets on a connector that is no longer there. A monitor unplugged, switched
-- off or taken by a KVM can take its wall of notes with it: the widgets stay in
-- settings.toml, bound to an output nothing draws. This brings those onto a
-- screen that is connected and leaves every other sheet alone, and remembers
-- where each one was, so the gather that sees that output again sends them
-- back.
function M.gather(onDone)
  local path = tool()
  if path == nil or not usable() then
    return false
  end

  local target, all = screens()
  if target == nil then
    return false
  end

  local live = {}
  for _, screen in ipairs(all) do
    table.insert(live, screen.name)
  end

  local argv = {
    path, "gather",
    "--outputs", table.concat(live, ","),
    "--output", target.name,
    "--screen", sizeOf(target),
  }
  local homes = localFile("homes.json")
  if homes ~= nil then
    table.insert(argv, "--homes")
    table.insert(argv, homes)
  end

  return run(argv, onDone)
end

-- Noctalia's own widget editor is what moves, resizes and rotates a sheet, and
-- no Luau call opens it - only the IPC command, so the plugin asks its own CLI.
function M.toggleEditor()
  noctalia.runAsync({ "noctalia", "msg", "desktop-widgets-toggle-edit" }, nil, 5000)
end

return M
