--!nonstrict
-- Printers service: owns the lpstat polling and every CUPS action. The bar
-- widget, panel and shortcut only read published state and send commands
-- through noctalia.state.set("printer.cmd", ...).
--
-- Nothing about the printing setup is configured here: destinations, states
-- and jobs all come from lpstat at runtime.

noctalia.setUpdateInterval(1000)

local tickCount = 0
local lastFaulty = {} -- printer name -> true, for fault-transition notifications

-- ── helpers ──────────────────────────────────────────────────────────────

local function log(msg)
  noctalia.log(`printer: {msg}`)
end

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function clampInt(v, lo, hi, default)
  v = tonumber(v)
  if v == nil then
    return default
  end
  v = math.floor(v)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function cfgBool(key, default)
  local v = noctalia.getConfig(key)
  if type(v) == "boolean" then
    return v
  end
  return default
end

local function cfgInt(key, lo, hi, default)
  return clampInt(noctalia.getConfig(key), lo, hi, default)
end

local function cfgString(key, default)
  local v = noctalia.getConfig(key)
  if type(v) == "string" and trim(v) ~= "" then
    return trim(v)
  end
  return default
end

-- Every process this plugin spawns goes through here: an argv table, never a
-- shell string, so a printer or job name can never be interpreted as a command.
local function run(argv, onDone, timeoutMs)
  local accepted = noctalia.runAsync(argv, onDone, timeoutMs or 10000)
  if not accepted then
    log("failed to start: " .. table.concat(argv, " "))
    if onDone ~= nil then
      onDone({ exitCode = -1, stdout = "", stderr = "failed to start process", timedOut = false })
    end
  end
end

local function splitLines(s)
  local lines = {}
  for line in tostring(s or ""):gmatch("[^\n]+") do
    table.insert(lines, (line:gsub("\r$", "")))
  end
  return lines
end

local function splitFields(s)
  local fields = {}
  for field in tostring(s or ""):gmatch("%S+") do
    table.insert(fields, field)
  end
  return fields
end

-- ── parsing ──────────────────────────────────────────────────────────────

-- "system default destination: HP_Smart_Tank" -> "HP_Smart_Tank"
-- "no system default destination"             -> ""
local function parseDefault(stdout)
  for _, line in ipairs(splitLines(stdout)) do
    local after = line:match("destination:%s*(.+)$")
    if after ~= nil then
      return trim(after)
    end
  end
  return ""
end

-- "printer NAME is idle.  enabled since ..."  -> idle,     enabled
-- "printer NAME now printing NAME-12.  ..."   -> printing, enabled
-- "printer NAME disabled since ..."           -> disabled, not enabled
local function parsePrinters(stdout)
  local printers = {}
  for _, line in ipairs(splitLines(stdout)) do
    local name, rest = line:match("^printer%s+(%S+)%s+(.*)$")
    if name ~= nil then
      local state = "idle"
      local enabled = true
      if rest:match("^disabled") ~= nil or rest:match("^is%s+stopped") ~= nil then
        state = "disabled"
        enabled = false
      else
        local isState = rest:match("^is%s+([%w_-]+)")
        if isState ~= nil then
          state = isState
        elseif rest:match("^now%s+printing") ~= nil then
          state = "printing"
        end
      end
      table.insert(printers, { name = name, state = state, enabled = enabled })
    end
  end
  return printers
end

-- `lpstat -e` lists every destination CUPS can print to, including driverless
-- ones discovered over DNS-SD that have no permanent queue yet and so never
-- appear in `lpstat -p`. One name per line.
local function parseDestinations(stdout)
  local names = {}
  for _, line in ipairs(splitLines(stdout)) do
    local name = trim(line)
    if name ~= "" and name:match("^%S+$") ~= nil then
      table.insert(names, name)
    end
  end
  return names
end

-- Destination names differ only in punctuation between the DNS-SD advertisement
-- and the queue CUPS builds from it: the printer below is announced as
-- "HP_Smart_Tank_580_590_series_D692D5" and queued as
-- "HP_Smart_Tank_580-590_series_D692D5". Comparing the two verbatim lists the
-- same printer twice, so names are folded before they are matched.
local function foldName(name)
  return (tostring(name or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

-- Adds the discovered-only destinations to the configured ones, so a driverless
-- printer is offered before CUPS has materialized a queue for it. A destination
-- that is already a queue is dropped rather than listed a second time.
local function mergeDiscovered(printers, names)
  local known = {}
  for _, p in ipairs(printers) do
    known[foldName(p.name)] = true
  end
  for _, name in ipairs(names) do
    local key = foldName(name)
    if known[key] == nil then
      known[key] = true
      table.insert(printers, { name = name, state = "available", enabled = true, discovered = true })
    end
  end
  return printers
end

-- "device for NAME: dnssd://..." -> { NAME = uri }. Comparing a discovered
-- device's URI against these is exact, where comparing derived queue names is
-- not: CUPS and the GUI tools append their own suffixes when they create a
-- queue, so the same printer rarely ends up with the name this plugin derives.
local function parseDeviceUris(stdout)
  local uris = {}
  for _, line in ipairs(splitLines(stdout)) do
    local name, uri = line:match("^device for%s+([^:]+):%s*(.+)$")
    if name ~= nil then
      uris[trim(name)] = trim(uri)
    end
  end
  return uris
end

-- `lpinfo -l -v` describes one device per "Device:" block:
--
--   Device: uri = dnssd://HP%20Smart%20Tank...._ipp._tcp.local/?uuid=...
--           class = network
--           info = HP Smart Tank 580-590 series [D692D5]
--           make-and-model = HP Smart Tank 580-590 series
--
-- Bare scheme entries ("uri = ipp") are backends, not printers, so only URIs
-- carrying a "://" are real devices.
local function parseDevices(stdout)
  local devices = {}
  local current = nil
  for _, line in ipairs(splitLines(stdout)) do
    local uri = line:match("^Device:%s*uri%s*=%s*(.+)$")
    if uri ~= nil then
      uri = trim(uri)
      current = { uri = uri, info = "", model = "" }
      if uri:find("://") ~= nil then
        table.insert(devices, current)
      else
        current = nil
      end
    elseif current ~= nil then
      local info = line:match("^%s*info%s*=%s*(.*)$")
      local model = line:match("^%s*make%-and%-model%s*=%s*(.*)$")
      if info ~= nil then
        current.info = trim(info)
      elseif model ~= nil then
        model = trim(model)
        current.model = model ~= "Unknown" and model or ""
      end
    end
  end
  return devices
end

-- One physical printer is usually advertised several times (IPP, IPPS and a raw
-- pdl-datastream port). Rank the driverless-capable URIs above the raw ones and
-- keep one entry per model, so the panel offers a printer rather than a list of
-- its protocols.
local function rankUri(uri)
  if uri:find("_ipps%._tcp") ~= nil or uri:match("^ipps://") ~= nil then
    return 4
  end
  if uri:find("_ipp%._tcp") ~= nil or uri:match("^ipp://") ~= nil then
    return 3
  end
  if uri:find("_pdl%-datastream") ~= nil or uri:match("^socket://") ~= nil then
    return 1
  end
  return 2
end

local function dedupeDevices(devices)
  local best = {}
  local order = {}
  for _, d in ipairs(devices) do
    -- `info` usually carries a bracketed serial ("HP ... [D692D5]") that `model`
    -- does not, so keying on it (rather than the bare model name) keeps two
    -- physical printers of the same model from collapsing into one row.
    local key = d.info ~= "" and d.info or (d.model ~= "" and d.model or d.uri)
    d.rank = rankUri(d.uri)
    if best[key] == nil then
      best[key] = d
      table.insert(order, key)
    elseif d.rank > best[key].rank then
      best[key] = d
    end
  end
  local result = {}
  for _, key in ipairs(order) do
    table.insert(result, best[key])
  end
  return result
end

-- CUPS queue names allow no spaces and no "/", "#" or tab. Derive one from the
-- model, the way the CUPS web interface does.
local function queueNameFor(device, taken)
  local base = device.model ~= "" and device.model or device.info
  base = trim(base)
  if base == "" then
    base = "printer"
  end
  base = base:gsub("[^%w%.%-_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if base == "" then
    base = "printer"
  end
  local name = base
  local n = 1
  while taken[name] ~= nil do
    n += 1
    name = `{base}_{n}`
  end
  return name
end

-- `lpstat -l -o` prints one job header per job, followed by indented attribute
-- lines that carry the reason a job is stuck:
--
--   HP_Smart_Tank-42   andrewdems   12288   Thu 04 Sep 2026 09:12:03 PM EEST
--   \tStatus: cfFilterChain: pdftopdf (PID 84217) stopped with status 1
--   \tAlerts: job-completed-with-errors
--
-- An indented line therefore belongs to the job above it, never to a job of its
-- own, so the header test has to be anchored to the left margin.
local function parseJobs(stdout)
  local jobs = {}
  local current = nil
  for _, line in ipairs(splitLines(stdout)) do
    if line:match("^%s") ~= nil then
      if current ~= nil then
        local status = line:match("^%s*Status:%s*(.+)$")
        local alerts = line:match("^%s*Alerts:%s*(.+)$")
        if status ~= nil then
          current.status = trim(status)
        elseif alerts ~= nil then
          current.alerts = trim(alerts)
          current.failed = current.alerts:find("error") ~= nil
        end
      end
    else
      local fields = splitFields(line)
      local id = fields[1]
      if id ~= nil and id ~= "" then
        local when = ""
        if #fields > 3 then
          when = table.concat(fields, " ", 4)
        end
        current = {
          id = id,
          -- The trailing "-<number>" is the job number; the rest is the queue,
          -- which may itself contain dashes ("HP_Smart_Tank_580-590_series").
          printer = id:match("^(.*)%-%d+$") or id,
          user = fields[2] or "",
          size = fields[3] or "",
          when = when,
          status = "",
          alerts = "",
          failed = false,
        }
        table.insert(jobs, current)
      end
    end
  end
  return jobs
end

-- ── publishing ───────────────────────────────────────────────────────────

local function notifyFaults(printers)
  local nowFaulty = {}
  for _, p in ipairs(printers) do
    if not p.enabled then
      nowFaulty[p.name] = true
      if lastFaulty[p.name] == nil and cfgBool("notify_on_fault", true) then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.printer_stopped", { printer = p.name }))
      end
    end
  end
  lastFaulty = nowFaulty
end

local function publish(defaultPrinter, printers, jobs)
  local hasFault = false
  for _, p in ipairs(printers) do
    if not p.enabled then
      hasFault = true
    end
  end
  for _, j in ipairs(jobs) do
    if j.failed then
      hasFault = true
    end
  end

  noctalia.state.set("printer.printers", printers)
  noctalia.state.set("printer.jobs", jobs)
  noctalia.state.set("printer.status", {
    defaultPrinter = defaultPrinter,
    printerCount = #printers,
    jobCount = #jobs,
    hasFault = hasFault,
  })
end

-- Discoverable devices that are not already a queue, each with the name the
-- panel would give it. lpinfo talks to the CUPS backends, so it is slower than
-- lpstat, and is only worth scanning while the panel's "Add a printer" section
-- is actually open (see wantDevices()).
local function publishDevices(printers, onDone)
  local taken = {}
  for _, p in ipairs(printers) do
    taken[p.name] = true
  end

  run({ "lpstat", "-v" }, function(uriResult)
    local queuedUris = {}
    -- Folded queue names, as a fallback for a queue pointing at the same
    -- printer through a different URI than the one discovery reports (a
    -- hand-made ipp:// queue against a dnssd:// advertisement, say). A fold
    -- that two different queue names collide on is marked false rather than
    -- kept as one of them, so an ambiguous match reports "not queued" instead
    -- of naming the wrong queue.
    local queuedNames = {}
    for name, uri in pairs(parseDeviceUris(uriResult.stdout)) do
      queuedUris[uri] = name
      local key = foldName(name)
      if queuedNames[key] == nil then
        queuedNames[key] = name
      elseif queuedNames[key] ~= name then
        queuedNames[key] = false
      end
    end

    run({ "lpinfo", "-l", "--include-schemes", "dnssd,ipp,ipps,socket,lpd,usb", "-v" }, function(result)
      local devices = dedupeDevices(parseDevices(result.stdout))
      local rows = {}
      for _, d in ipairs(devices) do
        local queuedAs = queuedUris[d.uri]
        if queuedAs == nil and d.model ~= "" then
          local byName = queuedNames[foldName(d.model)]
          if byName then
            queuedAs = byName
          end
        end
        local suggested = queuedAs
        if suggested == nil then
          -- Reserve the derived name, so two unqueued devices that fold to the
          -- same base are offered distinct names rather than both claiming it.
          suggested = queueNameFor(d, taken)
          taken[suggested] = true
        end
        table.insert(rows, {
          uri = d.uri,
          info = d.info ~= "" and d.info or d.uri,
          model = d.model,
          suggestedName = suggested,
          alreadyQueued = queuedAs ~= nil,
          queuedAs = queuedAs or "",
        })
      end
      noctalia.state.set("printer.devices", rows)
      if onDone ~= nil then
        onDone()
      end
    end, 20000)
  end)
end

-- The panel sets this while "Add a printer" is expanded; scanning lpinfo on
-- every poll regardless would burn CPU on DNS-SD/USB discovery nobody is
-- looking at.
local function wantDevices()
  return noctalia.state.get("printer.wantDevices") == true
end

-- lpstat is called four times with plain argv rather than once behind a shell
-- pipeline, so the plugin never needs /bin/sh.
--
-- refreshing guards against overlap: lpinfo's device scan can run for seconds,
-- and without this a slow chain plus a poll tick (or a user action's own
-- refresh) could start a second chain whose earlier completion publishes stale
-- state over the newer one. A refresh that is skipped this way is never lost
-- silently: the next poll tick, or the action that asked for it, still has a
-- fresh CUPS state to report shortly after.
local refreshing = false

local function refresh()
  if refreshing then
    return
  end
  refreshing = true
  run({ "lpstat", "-d" }, function(defResult)
    local defaultPrinter = parseDefault(defResult.stdout)
    run({ "lpstat", "-p" }, function(printerResult)
      local printers = parsePrinters(printerResult.stdout)
      run({ "lpstat", "-e" }, function(destResult)
        printers = mergeDiscovered(printers, parseDestinations(destResult.stdout))
        run({ "lpstat", "-l", "-o" }, function(jobResult)
          local jobs = parseJobs(jobResult.stdout)
          notifyFaults(printers)
          publish(defaultPrinter, printers, jobs)
          if wantDevices() then
            publishDevices(printers, function()
              refreshing = false
            end)
          else
            refreshing = false
          end
        end)
      end)
    end)
  end)
end

-- ── actions ──────────────────────────────────────────────────────────────

local function cancelJob(id)
  id = trim(id)
  if id == "" then
    return
  end
  run({ "cancel", id }, function()
    refresh()
  end)
end

local function cancelAll()
  run({ "cancel", "-a" }, function()
    refresh()
  end)
end

local function setDefault(name)
  name = trim(name)
  if name == "" then
    return
  end
  run({ "lpoptions", "-d", name }, function()
    refresh()
  end)
end

-- The clipboard text is written to a file under the plugin's data dir, handed
-- to lp as an argument and removed again, so no shell pipeline is involved and
-- the text never appears on a command line.
local function printClipboard()
  local status = noctalia.state.get("printer.status")
  local defaultPrinter = type(status) == "table" and status.defaultPrinter or ""
  if defaultPrinter == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.no_default"))
    return
  end

  local text = noctalia.clipboardText()
  if text == nil or trim(text) == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.clipboard_empty"))
    return
  end

  local dir, dirErr = noctalia.pluginDataDir()
  if dir == nil then
    noctalia.notifyError(noctalia.tr("title"), dirErr or "no data directory")
    return
  end

  -- Timestamped rather than a fixed name, so two overlapping "print clipboard"
  -- calls (a double-click, or the panel and an IPC call landing together)
  -- never race on the same file underneath each other's lp/removeFile.
  local path = `{dir}/clipboard-{math.floor(noctalia.nowMs())}.txt`
  local ok, writeErr = noctalia.writeFile(path, text)
  if not ok then
    noctalia.notifyError(noctalia.tr("title"), writeErr or "could not stage the clipboard")
    return
  end

  run({ "lp", "-d", defaultPrinter, path }, function(result)
    noctalia.removeFile(path)
    if result.exitCode == 0 then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.sent", { printer = defaultPrinter }))
      refresh()
    else
      noctalia.notifyError(noctalia.tr("title"), trim(result.stderr) ~= "" and trim(result.stderr) or "lp failed")
    end
  end)
end

local function openQueue()
  run({ "xdg-open", cfgString("cups_url", "http://localhost:631/jobs/") })
end

local function openPrinterSettings()
  local argv = splitFields(cfgString("settings_command", "system-config-printer"))
  if #argv == 0 then
    return
  end
  if not noctalia.commandExists(argv[1]) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.missing_command", { command = argv[1] }))
    return
  end
  run(argv)
end

-- Adds a discovered device as a permanent queue. IPP Everywhere (-m everywhere)
-- is the driverless path: no vendor driver, no PPD to maintain. A printer that
-- cannot do driverless needs its own driver, which is system-config-printer's
-- job, not this plugin's, so the failure is reported rather than worked around.
local function addPrinter(name, uri)
  name = trim(name)
  uri = trim(uri)
  if name == "" or uri == "" then
    return
  end
  run({ "lpadmin", "-p", name, "-E", "-v", uri, "-m", "everywhere" }, function(result)
    if result.exitCode == 0 then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.added", { printer = name }))
      refresh()
    else
      local err = trim(result.stderr)
      noctalia.notifyError(
        noctalia.tr("title"),
        err ~= "" and err or noctalia.tr("notifications.add_failed", { printer = name })
      )
    end
  end, 30000)
end

local function removePrinter(name)
  name = trim(name)
  if name == "" then
    return
  end
  run({ "lpadmin", "-x", name }, function(result)
    if result.exitCode == 0 then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.removed", { printer = name }))
      refresh()
    else
      local err = trim(result.stderr)
      noctalia.notifyError(
        noctalia.tr("title"),
        err ~= "" and err or noctalia.tr("notifications.remove_failed", { printer = name })
      )
    end
  end, 30000)
end

-- ── command channel ──────────────────────────────────────────────────────

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "cancel" then
    cancelJob(cmd.id)
  elseif op == "cancel_all" then
    cancelAll()
  elseif op == "set_default" then
    setDefault(cmd.name)
  elseif op == "print_clipboard" then
    printClipboard()
  elseif op == "open_queue" then
    openQueue()
  elseif op == "open_settings" then
    openPrinterSettings()
  elseif op == "add" then
    addPrinter(cmd.name, cmd.uri)
  elseif op == "remove" then
    removePrinter(cmd.name)
  elseif op == "refresh" then
    refresh()
  end
end

-- printer.cmd holds a queue, not a single command: the panel appends to it
-- rather than overwriting, so two commands sent in quick succession (cancel
-- job A, then job B) are both delivered even if the watch callback only fires
-- once for both writes, instead of the second silently replacing the first.
noctalia.state.watch("printer.cmd", function(queue)
  if type(queue) == "table" and #queue > 0 then
    for _, cmd in ipairs(queue) do
      handleCommand(cmd)
    end
    noctalia.state.set("printer.cmd", {})
  end
end)

function onIpc(event, payload)
  if event == "refresh" then
    refresh()
  elseif event == "cancel" then
    cancelJob(payload)
  elseif event == "cancel-all" then
    cancelAll()
  elseif event == "print-clipboard" then
    printClipboard()
  elseif event == "status" then
    local status = noctalia.state.get("printer.status")
    if type(status) == "table" then
      noctalia.notify(
        noctalia.tr("title"),
        noctalia.trp("notifications.status", status.jobCount or 0, {
          printer = status.defaultPrinter ~= "" and status.defaultPrinter or noctalia.tr("panel.no_default"),
          count = status.jobCount or 0,
        })
      )
    end
  end
end

function onConfigChanged()
  refresh()
end

function onEnable()
  refresh()
end

function update()
  tickCount += 1
  if tickCount % cfgInt("poll_interval_seconds", 5, 300, 10) == 0 then
    refresh()
  end
end

noctalia.state.set("printer.printers", {})
noctalia.state.set("printer.jobs", {})
noctalia.state.set("printer.devices", {})
noctalia.state.set("printer.cmd", {})
noctalia.state.set("printer.status", { defaultPrinter = "", printerCount = 0, jobCount = 0, hasFault = false })
refresh()
