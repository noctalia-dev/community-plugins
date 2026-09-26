--!nonstrict
local Store = require("./lib/store.luau")
local Capture = require("./lib/capture.luau")
local Text = require("./lib/text.luau")

local SCAN_LINES_PER_TICK = 4
local SCAN_TICK_MS = 250

local lastSignature = nil
local scanPending = false
local forceScan = false
local gitPendingAt = nil

local function interval()
  local ms = tonumber(noctalia.getConfig("poll_interval_ms")) or 5000
  if ms < 1000 then
    ms = 1000
  end
  return ms
end

local function publish(snapshot, index)
  noctalia.state.set("snapshot", snapshot)
  noctalia.state.set("index", index or {})
end

-- Due reminders -----------------------------------------------------------
--
-- Two independent alerts:
--   * a per-todo alert at its due time (or the moment it is discovered past
--     due), keyed by a stable todo id so each fires once; and
--   * a coarse daily summary of overdue/due-today counts.
--
-- The update loop asks for a short tick while a timed todo is imminent.

local REMINDER_KEPT = 200

local function reminderPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/reminders.json"
end

local function loadReminders()
  local path = reminderPath()
  if path == nil then
    return {}
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return {}
  end
  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" then
    return {}
  end
  if type(data.notified) ~= "table" then
    data.notified = {}
  end
  return data
end

local function saveReminders(data)
  local path = reminderPath()
  if path == nil then
    return
  end
  noctalia.writeFile(path, noctalia.json.encode(data))
end

local function trimNotified(notified)
  local count = 0
  for _ in pairs(notified) do
    count = count + 1
  end
  if count <= REMINDER_KEPT then
    return
  end
  local keys = {}
  for key in pairs(notified) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for index = 1, count - REMINDER_KEPT do
    notified[keys[index]] = nil
  end
end

-- Milliseconds until the next timed todo becomes due, or nil when none has a
-- future time today/soon. Used to tighten the update interval.
-- Milliseconds until the next timed todo falls due, or nil. Reads the clock
-- once, and the result is cached until the next scan because it only changes
-- when the notes change or time passes: recomputing it on every 250 ms tick
-- was enough to blow the update() CPU budget on a large vault.
local nextDueCache = { at = 0, value = nil }

local function nextDueInMs(snapshot)
  local now = noctalia.nowMs()
  if nextDueCache.at ~= nil and (now - nextDueCache.at) < 5000 and nextDueCache.value ~= nil then
    return nextDueCache.value
  end
  local soonest
  for _, todo in ipairs(snapshot.todos) do
    if not todo.done and todo.due ~= nil and todo.time ~= nil then
      local dueAt = Text.dueEpochMs(todo.due, todo.time)
      if dueAt ~= nil then
        local remaining = dueAt - now
        if remaining > 0 and (soonest == nil or remaining < soonest) then
          soonest = remaining
        end
      end
    end
  end
  -- Store the absolute due instant so a cached value still shrinks with time.
  nextDueCache.at = now
  nextDueCache.value = soonest and (now + soonest) or nil
  return nextDueCache.value - now
end

local function invalidateNextDue()
  nextDueCache.at = 0
  nextDueCache.value = nil
end

local function checkReminders(snapshot)
  if noctalia.getConfig("due_reminders") == false then
    return
  end
  local today = Text.todayIso()
  local now = noctalia.nowMs()
  local state = loadReminders()
  local notified = state.notified or {}
  local notifiedChanged = false

  for _, todo in ipairs(snapshot.todos) do
    if not todo.done and todo.due ~= nil and Text.isOverdue(todo.due, todo.time) then
      local key = todo.id .. "@" .. todo.due .. (todo.time ~= nil and ("T" .. todo.time) or "")
      if notified[key] == nil then
        notified[key] = now
        notifiedChanged = true
        local label = Text.fmtDue(todo.due, todo.time) or todo.due
        noctalia.notify("Quill", todo.text .. " · " .. label)
      end
    end
  end
  if notifiedChanged then
    trimNotified(notified)
  end

  local overdue, dueToday = 0, 0
  for _, todo in ipairs(snapshot.todos) do
    if not todo.done and todo.due ~= nil then
      if Text.isOverdue(todo.due, todo.time) then
        overdue = overdue + 1
      elseif todo.due == today then
        dueToday = dueToday + 1
      end
    end
  end

  if overdue + dueToday > 0 then
    local sig = today .. "|" .. tostring(overdue) .. "|" .. tostring(dueToday)
    if state.sig ~= sig and (state.at == nil or (now - state.at) >= 30 * 60 * 1000) then
      local parts = {}
      if dueToday > 0 then
        parts[#parts + 1] = tostring(dueToday) .. " due today"
      end
      if overdue > 0 then
        parts[#parts + 1] = tostring(overdue) .. " overdue"
      end
      noctalia.notify("Quill", table.concat(parts, " · "))
      state.sig = sig
      state.at = now
    end
  end

  state.notified = notified
  saveReminders(state)
end

-- Git history -------------------------------------------------------------

local function commitNotes()
  if noctalia.getConfig("git_history") == false then
    return
  end
  if not noctalia.commandExists("git") then
    return
  end

  local dir = Store.notesDir()
  local message = "notes: " .. os.date("%Y-%m-%d %H:%M:%S")

  local home = noctalia.expandPath("~")
  if dir == home or dir == "/" then
    noctalia.notifyError("Quill", "Git history is off: the notes folder is your home directory")
    return
  end

  -- `-- .` keeps every operation scoped to the notes folder, so a notes folder
  -- that happens to sit inside a larger repository does not stage and commit
  -- the rest of the user's working tree.
  local function commit()
    noctalia.runAsync({ "git", "-C", dir, "add", "-A", "--", "." }, function()
      noctalia.runAsync({ "git", "-C", dir, "commit", "-q", "-m", message, "--", "." }, function(result)
        if result == nil or result.exitCode == 0 then
          return
        end
        if string.find(result.stderr or "", "who you are", 1, true) ~= nil then
          noctalia.runAsync({
            "git", "-C", dir,
            "-c", "user.name=Noctalia Quill",
            "-c", "user.email=quill@localhost",
            "commit", "-q", "-m", message, "--", ".",
          }, function() end)
        end
      end)
    end)
  end

  if noctalia.fileExists(dir .. "/.git") then
    commit()
  else
    noctalia.runAsync({ "git", "-C", dir, "init", "-q" }, function(result)
      if result ~= nil and result.exitCode == 0 then
        commit()
      end
    end)
  end
end

-- Scanning ----------------------------------------------------------------

local function finishSnapshot(snapshot, index)
  publish(snapshot, index)
  invalidateNextDue()
  local ok, err = pcall(checkReminders, snapshot)
  if not ok then
    noctalia.log("notes: reminders failed: " .. tostring(err))
  end
end

local function startScan(force)
  local ok, files, signature = pcall(Store.snapshotFiles)
  if not ok then
    noctalia.log("notes: listing failed: " .. tostring(files))
    return
  end
  if not force and signature == lastSignature then
    return
  end
  lastSignature = signature
  local snapshot, index = Store.beginScan(signature, files)
  if snapshot ~= nil then
    finishSnapshot(snapshot, index)
  else
    scanPending = true
  end
end

local ok, err = pcall(function()
  Store.ensureDir()
  startScan(true)
end)
if not ok then
  noctalia.log("notes: initial scan failed: " .. tostring(err))
end

noctalia.setUpdateInterval(scanPending and SCAN_TICK_MS or interval())

noctalia.state.watch("refresh_request", function()
  forceScan = true
  noctalia.setUpdateInterval(SCAN_TICK_MS)
end)

noctalia.state.watch("notes_dirty", function()
  gitPendingAt = noctalia.nowMs()
end)

function update()
  if forceScan then
    forceScan = false
    scanPending = false
    startScan(true)
  elseif not scanPending then
    startScan(false)
  end

  if scanPending then
    local snapshot, index = Store.scanStep(SCAN_LINES_PER_TICK)
    if snapshot ~= nil then
      scanPending = false
      finishSnapshot(snapshot, index)
    end
  end

  noctalia.setUpdateInterval(scanPending and SCAN_TICK_MS or interval())

  -- A timed todo about to fall due needs a finer tick than the poll interval,
  -- otherwise a 14:30 reminder could be up to poll_interval_ms late.
  local snapshot = noctalia.state.get("snapshot")
  local dueIn = type(snapshot) == "table" and nextDueInMs(snapshot) or nil
  if dueIn ~= nil and dueIn <= 60000 then
    noctalia.setUpdateInterval(SCAN_TICK_MS)
  end

  if gitPendingAt ~= nil then
    local delay = tonumber(noctalia.getConfig("git_debounce_ms")) or 8000
    if noctalia.nowMs() - gitPendingAt >= delay then
      gitPendingAt = nil
      commitNotes()
    end
  end
end

function onConfigChanged()
  lastSignature = nil
  scanPending = false
  forceScan = true
end

-- Scriptable surface:
--   noctalia msg plugin fel/quill:index refresh
--   noctalia msg plugin fel/quill:index capture '{"text":"buy milk tomorrow"}'
--   noctalia msg plugin fel/quill:index commit
function onIpc(event, payload)
  if event == "refresh" then
    forceScan = true
    noctalia.setUpdateInterval(SCAN_TICK_MS)
    return
  end

  if event == "commit" then
    commitNotes()
    return
  end

  if event == "capture" then
    local text = Text.payloadField(payload, "text")
    if text == "" then
      noctalia.notifyError("Quill", "Nothing to capture")
      return
    end
    Capture.capture(text, noctalia.getConfig("ai_capture") ~= false, function(status)
      noctalia.notify("Quill", status)
      Store.markDirty()
    end, Capture.projectContext())
  end
end
