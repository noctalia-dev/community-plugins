--!nonstrict
-- Task Warrior taskwarrior service: the single owner of all `task` CLI access.
--
-- Publishes shared state:
--   tasks   : array of pending task tables (from `task export`)
--   summary : { pending = n, overdue = n, dueToday = n }  (for the bar widget)
--   status  : { error = string?, at = epoch }      (for the panel error banner)
-- Consumes shared state:
--   request : { seq, kind = "add"|"done"|"delete"|"modify"|"undo"|"refresh", ... }
--     add    : { description, fields }
--     done   : { uuid }
--     delete : { uuid }
--     modify : { uuid, fields }
--   fields  : { description?, project?, due?, priority?, tags? = { from = {...}, to = {...} } }
--             nil field = leave untouched, "" = clear the attribute.
--
-- Requests are queued and run strictly one at a time; the task list is
-- re-exported once per queue drain.

local TASK_BASE = "task rc.confirmation=off rc.verbose=nothing rc.color=off "
local EXPORT_CMD = "task rc.json.array=on rc.color=off rc.verbose=nothing rc.confirmation=off status:pending export"
local COMMAND_TIMEOUT_MS = 15000

local pending = {}
local busy = false
local lastExport = nil
local cachedTasks = {}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function shq(s)
  return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

local function firstLine(s)
  if type(s) ~= "string" then
    return ""
  end
  return string.match(s, "[^\r\n]+") or ""
end

-- Whitespace tokenizer honoring single/double quotes, so inline taskwarrior
-- syntax typed into the description field still works.
local function tokenize(input)
  local tokens = {}
  local current = ""
  local quote = nil
  for i = 1, #input do
    local c = string.sub(input, i, i)
    if quote ~= nil then
      if c == quote then
        quote = nil
      else
        current = current .. c
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == " " or c == "\t" then
      if current ~= "" then
        table.insert(tokens, current)
        current = ""
      end
    else
      current = current .. c
    end
  end
  if current ~= "" then
    table.insert(tokens, current)
  end
  return tokens
end

-- Taskwarrior export dates look like "20250917T140000Z" (UTC). Luau's
-- os.time(table), unlike stock Lua's, always interprets the table as UTC
-- (see loslib.cpp: it calls timegm(), not mktime()) — so feeding it these
-- already-UTC fields directly gives the correct absolute epoch with no
-- local-offset correction needed.
local function parseTaskDate(s)
  if type(s) ~= "string" or #s < 16 then
    return nil
  end
  local y = tonumber(string.sub(s, 1, 4))
  local mo = tonumber(string.sub(s, 5, 6))
  local d = tonumber(string.sub(s, 7, 8))
  local h = tonumber(string.sub(s, 10, 11))
  local mi = tonumber(string.sub(s, 12, 13))
  local se = tonumber(string.sub(s, 14, 15))
  if y == nil or mo == nil or d == nil or h == nil or mi == nil or se == nil then
    return nil
  end
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se })
end

local function summarize(tasks)
  local overdue = 0
  local dueToday = 0
  local now = os.time()
  local today = os.date("%Y%m%d", now)
  for _, t in ipairs(tasks) do
    local due = parseTaskDate(t.due)
    if due ~= nil then
      if due < now then
        overdue += 1
      elseif os.date("%Y%m%d", due) == today then
        dueToday += 1
      end
    end
  end
  return { pending = #tasks, overdue = overdue, dueToday = dueToday }
end

local function publishStatus(err)
  noctalia.state.set("status", { error = err, at = os.time() })
end

-- ── export / refresh ─────────────────────────────────────────────────────────

local function refresh()
  noctalia.runAsync(EXPORT_CMD, function(r)
    if r.timedOut or r.exitCode ~= 0 then
      local msg = firstLine(r.stderr)
      publishStatus(msg ~= "" and msg or noctalia.tr("service.export-failed"))
      return
    end
    -- Unchanged output: skip the parse and the tasks re-publish (no downstream
    -- re-render), but keep the time-based overdue summary fresh.
    if r.stdout == lastExport then
      noctalia.state.set("summary", summarize(cachedTasks))
      publishStatus(nil)
      return
    end
    local tasks = noctalia.json.decode(r.stdout)
    if type(tasks) ~= "table" then
      publishStatus(noctalia.tr("service.parse-failed"))
      return
    end
    lastExport = r.stdout
    cachedTasks = tasks
    noctalia.state.set("tasks", tasks)
    noctalia.state.set("summary", summarize(tasks))
    publishStatus(nil)
  end, COMMAND_TIMEOUT_MS)
end

-- ── request handling ─────────────────────────────────────────────────────────

-- fields -> shell-quoted taskwarrior attribute args.
local function fieldArgs(f)
  local args = {}
  if f.description ~= nil then
    table.insert(args, shq("description:" .. f.description))
  end
  if f.project ~= nil then
    table.insert(args, shq("project:" .. f.project))
  end
  if f.due ~= nil then
    table.insert(args, shq("due:" .. f.due))
  end
  if f.priority ~= nil then
    table.insert(args, shq("priority:" .. f.priority))
  end
  if type(f.tags) == "table" then
    local from = f.tags.from or {}
    local to = f.tags.to or {}
    local fromSet = {}
    local toSet = {}
    for _, t in ipairs(from) do
      fromSet[t] = true
    end
    for _, t in ipairs(to) do
      toSet[t] = true
      if not fromSet[t] then
        table.insert(args, shq("+" .. t))
      end
    end
    for _, t in ipairs(from) do
      if not toSet[t] then
        table.insert(args, shq("-" .. t))
      end
    end
  end
  return args
end

local successKeys = {
  add = "service.added",
  done = "service.completed",
  delete = "service.deleted",
  modify = "service.updated",
  undo = "service.undone",
}

-- Build the shell-quoted argument list for a request, or nil to skip it.
local function argsFor(req)
  if req.kind == "add" then
    local tokens = tokenize(tostring(req.description or ""))
    if #tokens == 0 then
      return nil
    end
    local args = { "add" }
    for _, t in ipairs(tokens) do
      table.insert(args, shq(t))
    end
    for _, a in ipairs(fieldArgs(req.fields or {})) do
      table.insert(args, a)
    end
    return args
  elseif req.kind == "done" and req.uuid ~= nil then
    return { shq(req.uuid), "done" }
  elseif req.kind == "delete" and req.uuid ~= nil then
    return { shq(req.uuid), "delete" }
  elseif req.kind == "modify" and req.uuid ~= nil then
    local args = fieldArgs(req.fields or {})
    if #args == 0 then
      return nil
    end
    table.insert(args, 1, shq(req.uuid))
    table.insert(args, 2, "modify")
    return args
  elseif req.kind == "undo" then
    return { "undo" }
  end
  return nil
end

local function runNext()
  if busy then
    return
  end
  local req = table.remove(pending, 1)
  if req == nil then
    return
  end

  if req.kind == "refresh" then
    if #pending > 0 then
      runNext()
    else
      refresh()
    end
    return
  end

  local args = argsFor(req)
  if args == nil then
    if #pending > 0 then
      runNext()
    else
      refresh()
    end
    return
  end

  busy = true
  noctalia.runAsync(TASK_BASE .. table.concat(args, " "), function(r)
    busy = false
    if r.exitCode == 0 and not r.timedOut then
      local key = successKeys[req.kind]
      if key ~= nil then
        noctalia.notify("Task Warrior", noctalia.tr(key))
      end
    else
      local msg = firstLine(r.stderr)
      noctalia.notifyError("Task Warrior", msg ~= "" and msg or noctalia.tr("service.command-failed"))
    end
    -- Refresh once per queue drain, not once per action.
    if #pending > 0 then
      runNext()
    else
      refresh()
    end
  end, COMMAND_TIMEOUT_MS)
end

noctalia.state.watch("request", function(req)
  if type(req) ~= "table" or req.kind == nil then
    return
  end
  table.insert(pending, req)
  runNext()
end)

-- ── lifecycle ────────────────────────────────────────────────────────────────

function update()
  refresh()
end

noctalia.setUpdateInterval(math.max(5, noctalia.getConfig("refresh_interval") or 30) * 1000)
