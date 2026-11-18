--!nonstrict
-- Vikunja backend: today/overdue counts, task list, add, complete, postpone.

local STATE_KEY = "vk_snapshot"
-- Entries get a small scalar push reliably; the snapshot itself is big enough
-- that the host does not deliver every update of it. A revision counter tells
-- the panel when to re-read the snapshot.
local REV_KEY = "vk_rev"
local COMMAND_KEY = "vk_command"
local RESULT_KEY = "vk_action_result"

-- Vikunja caps a page at `max_items_per_page` (50 by default).
local PAGE_SIZE = 50
-- Guard rails: never walk more pages than this for one list.
local MAX_PAGES = 8
-- A poll that never called back must not leave the plugin spinning.
local STUCK_REFRESH_SEC = 20
-- Local time a due date is set to when adding or postponing (Vikunja stores UTC).
local DUE_HOUR = 9

local snapshot = {
  revision = 0,
  updatedAt = 0,
  busy = false,
  configured = false,
  available = false,
  loading = true,
  projectsLoading = false,
  error = "",
  host = "",
  counts = { overdue = 0, today = 0, soon = 0 },
  today = {},
  upcoming = {},
  projects = {},
  defaultProject = nil,
  -- Browsing one project: every open task, grouped by kanban bucket when the
  -- project's view has them (dateless tasks included).
  projectOpen = nil,
  projectTasks = {},
  projectBuckets = {},
  showDone = false,
  projectLoading = false,
  -- Buckets of the project the add row targets (kanban projects only).
  addProject = nil,
  addBuckets = {},
  -- Open task count per project id, from the on-demand sweep.
  openCounts = {},
  openCountsAt = 0,
  -- view/buckets cache per project so reopening one is a single request.
  viewCache = {},
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local refreshStartedAt = 0
local projectStartedAt = 0
local actionBusy = false
-- Wall-clock stamp of the last busy transition: a dropped HTTP callback would
-- otherwise leave every action rejected as busy forever.
local actionBusySince = 0
local function setBusy(value)
  actionBusy = value and true or false
  actionBusySince = actionBusy and os.time() or 0
end
local dataSignature = ""
local prevOverdue = {}

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function asString(v)
  if v == nil then
    return ""
  end
  if type(v) == "boolean" then
    return v and "true" or "false"
  end
  return tostring(v)
end

local function nowSec()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return math.floor(ms / 1000)
    end
  end
  return os.time()
end

local function refreshIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 60
  seconds = math.max(15, math.min(3600, math.floor(seconds)))
  return seconds * 1000
end

local function soonDays()
  local days = tonumber(noctalia.getConfig("soon_days")) or 7
  return math.max(1, math.min(60, math.floor(days)))
end

local function timezone()
  return trim(noctalia.getConfig("timezone"))
end

local function baseUrl()
  local url = trim(noctalia.getConfig("base_url"))
  url = url:gsub("/+$", "")
  url = url:gsub("/api$", "")
  return url
end

local function hostLabel()
  local url = baseUrl()
  return url:match("^https?://([^/:]+)") or url
end

local function apiToken()
  return trim(noctalia.getConfig("api_token"))
end

local function isConfigured()
  return baseUrl() ~= "" and apiToken() ~= ""
end

local function taskUrl(id)
  return baseUrl() .. "/tasks/" .. tostring(id)
end

-- ---------------------------------------------------------------------------
-- local time helpers (Vikunja stores UTC, the user reads local days)

-- Local DUE_HOUR on the day of `epoch`, expressed as the UTC string Vikunja wants.
-- Time arithmetic. os.date/os.time honour the system zone (verified in the
-- shell runtime: os.date("%z") = +0300, os.date("!") = UTC), so everything here
-- is plain Luau - no helper process needed.

local function localOffsetSeconds()
  local zone = os.date("%z") -- e.g. "+0300"
  local sign, hours, minutes = zone:match("^([+-])(%d%d)(%d%d)$")
  if sign == nil then
    return 0
  end
  local offset = tonumber(hours) * 3600 + tonumber(minutes) * 60
  return sign == "-" and -offset or offset
end

-- This runtime reads os.time({...}) fields as UTC even though os.date
-- honours the zone (os.date("%z") = +0300 here). Probe it once and convert
-- explicitly, so due dates land on the local day the user picked.
local timeTableIsUtc = nil

local function tableFieldsAreUtc()
  if timeTableIsUtc == nil then
    local now = os.date("*t")
    local asTable = os.time({
      year = now.year, month = now.month, day = now.day,
      hour = now.hour, min = now.min, sec = now.sec,
    })
    timeTableIsUtc = math.abs(asTable - os.time()) > 60
  end
  return timeTableIsUtc
end

-- Epoch of the instant whose UTC wall clock is `fields`.
local function epochFromUtcFields(fields)
  local epoch = os.time(fields)
  if tableFieldsAreUtc() then
    return epoch
  end
  return epoch + localOffsetSeconds()
end

-- Epoch of the instant whose *local* wall clock is `fields`.
local function epochFromLocalFields(fields)
  local epoch = os.time(fields)
  if tableFieldsAreUtc() then
    return epoch - localOffsetSeconds()
  end
  return epoch
end

-- Parses "2026-10-04T09:00:00Z" / "…+03:00" into a local epoch.
-- Day helpers, all in local time: the plugin's day boundaries follow the
-- system zone (startOfLocalDay is midnight today, dayShift moves whole days).
local function startOfLocalDay(epoch)
  local t = os.date("*t", epoch or os.time())
  return epochFromLocalFields({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

local function dayShift(epoch, days)
  local t = os.date("*t", epoch)
  return epochFromLocalFields({
    year = t.year, month = t.month, day = t.day + (days or 0),
    hour = 0, min = 0, sec = 0,
  })
end

local function dateLabel(epoch)
  return os.date("%Y-%m-%d", epoch)
end

local function timeLabel(epoch)
  return os.date("%H:%M", epoch)
end

local function parseDue(raw)
  local text = asString(raw)
  if text == "" or text:match("^0001%-01%-01") then
    return nil
  end
  local year, month, day, hour, min, sec = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if year == nil then
    return nil
  end
  local fields = {
    year = tonumber(year), month = tonumber(month), day = tonumber(day),
    hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
  }
  local zoneOffset = 0
  local zoneHour, zoneMinute = text:match("([+-]%d%d):(%d%d)$")
  if zoneHour ~= nil then
    zoneOffset = tonumber(zoneHour) * 3600 + tonumber(zoneMinute) * 60
  end
  -- The wall clock in the payload is UTC-shifted by its own zone suffix.
  return epochFromUtcFields(fields) - zoneOffset
end

-- Local due hour on `epoch`'s day, written the way Vikunja stores it (UTC).
local function dueStringFor(epoch)
  local day = os.date("*t", epoch)
  local stamp = epochFromLocalFields({
    year = day.year, month = day.month, day = day.day,
    hour = DUE_HOUR, min = 0, sec = 0,
  })
  return os.date("!%Y-%m-%dT%H:%M:%SZ", stamp)
end

local function dueBucket(dueEpoch)
  local todayStart = startOfLocalDay()
  if dueEpoch < todayStart then
    return "overdue"
  end
  if dueEpoch < dayShift(todayStart, 1) then
    return "today"
  end
  return "soon"
end

local function dueText(dueEpoch)
  local todayStart = startOfLocalDay()
  if dueEpoch < todayStart then
    return noctalia.tr("task.overdue", { n = math.floor((todayStart - dueEpoch) / 86400) + 1 })
  end
  if dueEpoch < dayShift(todayStart, 1) then
    return `{noctalia.tr("task.due_today")} {timeLabel(dueEpoch)}`
  end
  local days = math.floor((startOfLocalDay(dueEpoch) - todayStart) / 86400)
  if days == 1 then
    return `{noctalia.tr("task.due_tomorrow")} {timeLabel(dueEpoch)}`
  end
  return `{dateLabel(dueEpoch)} {timeLabel(dueEpoch)}`
end

-- ---------------------------------------------------------------------------
-- API plumbing

local function apiRequestBase(base, method, path, body, callback)
  local req = {
    url = base .. path:gsub("^/+", ""),
    method = method or "GET",
    headers = { "Accept: application/json", "Authorization: Bearer " .. apiToken() },
  }
  if body ~= nil then
    req.body = noctalia.json.encode(body) or ""
    table.insert(req.headers, "Content-Type: application/json")
  end

  local function safeCb(res)
    if type(callback) ~= "function" then
      return
    end
    local okCall, errCall = pcall(callback, res)
    if not okCall then
      noctalia.log(`vikunja: callback error on {path}: {tostring(errCall)}`)
    end
  end

  local ok = noctalia.http(req, safeCb)
  if not ok then
    safeCb({ ok = false, status = 0, body = "http queue full" })
  end
  return ok
end

local function apiRequest(method, path, body, callback)
  return apiRequestBase(baseUrl() .. "/api/v1/", method, path, body, callback)
end

local function apiRequestV2(method, path, body, callback)
  return apiRequestBase(baseUrl() .. "/api/v2/", method, path, body, callback)
end

local function decodeBody(res)
  if type(res) ~= "table" then
    return nil, "no response"
  end
  if not res.ok and (res.status == 0 or res.status == nil) then
    return nil, trim(res.body) ~= "" and trim(res.body) or "network error"
  end
  if res.status == 401 then
    return nil, "token rejected (401) — check the API token"
  end
  if res.status == 403 then
    return nil, "forbidden (403) — the API token lacks permissions"
  end
  if res.status and res.status >= 400 then
    -- Vikunja explains 4xx answers in the body ("Bucket does not exist …");
    -- losing that text would leave the panel with a bare status code.
    local detail = ""
    if type(res.body) == "string" and res.body ~= "" then
      local decoded = noctalia.json.decode(res.body)
      if type(decoded) == "table" then
        for _, field in ipairs({ "message", "detail" }) do
          if type(decoded[field]) == "string" and decoded[field] ~= "" then
            detail = ": " .. decoded[field]
            break
          end
        end
      end
    end
    return nil, "HTTP " .. tostring(res.status) .. detail
  end
  local body = res.body
  if type(body) ~= "string" or body == "" then
    return {}, nil
  end
  local data, err = noctalia.json.decode(body)
  if data == nil then
    return nil, err or "invalid JSON"
  end
  return data, nil
end

local function query(params)
  local parts = {}
  for _, pair in ipairs(params) do
    if pair[2] ~= nil and tostring(pair[2]) ~= "" then
      table.insert(parts, pair[1] .. "=" .. noctalia.string.urlEncode(tostring(pair[2])))
    end
  end
  return table.concat(parts, "&")
end

-- ---------------------------------------------------------------------------
-- snapshot + task shaping

local function notifyOk(msg)
  noctalia.notify(noctalia.tr("title"), msg)
end

local function notifyErr(msg)
  noctalia.notifyError(noctalia.tr("title"), msg)
end

local function actionResult(command, ok, message)
  noctalia.state.set(RESULT_KEY, {
    requestId = command and command.requestId or "",
    action = command and command.action or "",
    ok = ok,
    message = message or "",
  })
end

local function updateRevision(signature)
  if signature ~= dataSignature then
    dataSignature = signature
    snapshot.revision += 1
  end
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  snapshot.configured = isConfigured()
  snapshot.host = hostLabel()
  snapshot.base = baseUrl()
  noctalia.state.set(STATE_KEY, snapshot)
  noctalia.state.set(REV_KEY, snapshot.revision)
end

-- `projectId` is the project being browsed: view payloads leave project_id at 0.
local function parseTask(raw, titles, projectId)
  if type(raw) ~= "table" then
    return nil
  end
  local id = tonumber(raw.id)
  if id == nil then
    return nil
  end
  local due = parseDue(raw.due_date)
  -- View payloads send project_id as 0 (or omit it): the project being browsed
  -- is then the only trustworthy source.
  local rawProject = tonumber(raw.project_id)
  local projectId = (rawProject ~= nil and rawProject > 0) and rawProject or (tonumber(projectId) or 0)
  return {
    id = id,
    title = asString(raw.title),
    projectId = projectId,
    project = titles[projectId] or ("#" .. tostring(projectId)),
    priority = tonumber(raw.priority) or 0,
    due = due,
    dueText = due and dueText(due) or "",
    dueDate = due and dateLabel(due) or "",
    bucket = due and dueBucket(due) or "none",
    bucketId = tonumber(raw.bucket_id),
    done = raw.done == true,
    url = taskUrl(id),
  }
end

local function sortTasks(list)
  table.sort(list, function(a, b)
    if a.due ~= b.due then
      if a.due == nil then return false end
      if b.due == nil then return true end
      return a.due < b.due
    end
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a.title < b.title
  end)
end

local function resolveDefaultProject(projects)
  local wanted = lower(trim(noctalia.getConfig("default_project")))
  if wanted ~= "" then
    for _, project in ipairs(projects) do
      if lower(project.title) == wanted or tostring(project.id) == wanted then
        return project
      end
    end
  end
  return projects[1]
end

local function applySnapshot(tasks, projects, errors)
  local titles = {}
  for _, project in ipairs(projects) do
    titles[project.id] = project.title
  end

  local parsed = {}
  local okParse, errParse = pcall(function()
    for _, raw in ipairs(tasks) do
      local task = parseTask(raw, titles)
      if task ~= nil then
        table.insert(parsed, task)
      end
    end
  end)
  if not okParse then
    noctalia.log(`vikunja: parse error: {tostring(errParse)}`)
    table.insert(errors, "parse: " .. tostring(errParse))
  end

  local today, upcoming = {}, {}
  local counts = { overdue = 0, today = 0, soon = 0 }
  for _, task in ipairs(parsed) do
    if task.bucket == "overdue" then
      counts.overdue += 1
      table.insert(today, task)
    elseif task.bucket == "today" then
      counts.today += 1
      table.insert(today, task)
    else
      counts.soon += 1
      table.insert(upcoming, task)
    end
  end
  sortTasks(today)
  sortTasks(upcoming)

  local seen = {}
  local overdueTitles = {}
  for _, task in ipairs(today) do
    if task.bucket == "overdue" then
      seen[tostring(task.id)] = true
      table.insert(overdueTitles, task.title)
    end
  end
  pcall(function()
    if noctalia.getConfig("notify_on_due") == false then
      return
    end
    local fresh = {}
    for id in pairs(seen) do
      if not prevOverdue[id] then
        table.insert(fresh, id)
      end
    end
    if #fresh > 0 and #overdueTitles > 0 then
      local names = {}
      for index = 1, math.min(#overdueTitles, 3) do
        table.insert(names, overdueTitles[index])
      end
      notifyErr(noctalia.tr("result.overdue_notice", {
        n = #overdueTitles,
        titles = table.concat(names, ", "),
      }))
    end
  end)
  prevOverdue = seen

  snapshot.today = today
  snapshot.upcoming = upcoming
  snapshot.counts = counts
  -- The API returns id/title only; open counts live in their own field and this
  -- assignment must not wipe them.
  local counts = snapshot.openCounts or {}
  local merged = {}
  for _, project in ipairs(projects) do
    table.insert(merged, {
      id = project.id,
      title = project.title,
      open = counts[project.id],
    })
  end
  snapshot.projects = merged
  snapshot.defaultProject = resolveDefaultProject(projects)
  snapshot.loading = false
  snapshot.updatedAt = nowSec()
  snapshot.error = errors[1] or ""
  snapshot.available = #errors < 2
  updateRevision(table.concat({
    tostring(counts.overdue), tostring(counts.today), tostring(counts.soon),
    tostring(#today), tostring(#upcoming), tostring(#projects),
  }, "|"))
  publishSnapshot()
end

-- ---------------------------------------------------------------------------
-- fetching

local function tasksFilter()
  -- Everything due up to the end of the lookahead day; overdue comes along.
  return `done = false && due_date < now/d+{soonDays() + 1}d`
end

local function fetchTasksPage(filter, page, acc, onDone)
  local path = "tasks?" .. query({
    { "filter", filter },
    { "filter_timezone", timezone() },
    -- Vikunja 2.6.0 accepts repeated sort params; a comma list 400s.
    { "sort_by", "due_date" },
    { "sort_by", "priority" },
    { "order_by", "asc" },
    { "order_by", "desc" },
    { "per_page", PAGE_SIZE },
    { "page", page },
  })
  apiRequest("GET", path, nil, function(res)
    local data, err = decodeBody(res)
    if data == nil then
      onDone(acc, err)
      return
    end
    if type(data) ~= "table" then
      onDone(acc, "unexpected task payload")
      return
    end
    for _, raw in ipairs(data) do
      table.insert(acc, raw)
    end
    if #data == PAGE_SIZE and page < MAX_PAGES then
      fetchTasksPage(filter, page + 1, acc, onDone)
      return
    end
    onDone(acc, nil)
  end)
end

local function fetchProjects(onDone)
  apiRequest("GET", "projects?" .. query({
    { "per_page", PAGE_SIZE },
    { "is_archived", "false" },
  }), nil, function(res)
    local data, err = decodeBody(res)
    if data == nil or type(data) ~= "table" then
      onDone({}, err or "unexpected project payload")
      return
    end
    local out = {}
    for _, raw in ipairs(data) do
      local id = tonumber(raw.id)
      if id ~= nil then
        table.insert(out, { id = id, title = asString(raw.title) })
      end
    end
    -- Keep the API order: it is the order the user sees in Vikunja, and the
    -- first project is the fallback target for quick add.
    onDone(out, nil)
  end)
end

local refreshAll
local openProject

refreshAll = function()
  if refreshPending and refreshStartedAt > 0 and (nowSec() - refreshStartedAt) >= STUCK_REFRESH_SEC then
    noctalia.log("vikunja: refresh timed out")
    refreshPending = false
    refreshStartedAt = 0
    snapshot.loading = false
    if snapshot.error == "" then
      snapshot.error = "refresh timed out"
    end
    noctalia.setUpdateInterval(refreshIntervalMs())
    publishSnapshot()
  end

  if snapshot.projectLoading and projectStartedAt > 0 and (nowSec() - projectStartedAt) >= STUCK_REFRESH_SEC then
    noctalia.log("vikunja: project load timed out")
    snapshot.projectLoading = false
    projectStartedAt = 0
    snapshot.error = "project load timed out"
    publishSnapshot()
  end

  -- A tick arriving while a request is in flight used to set refreshAgain, which
  -- started an extra round as soon as the queue drained and skewed the poll rate.
  if refreshPending then
    return
  end
  refreshPending = true
  refreshAgain = false
  refreshStartedAt = nowSec()
  refreshGeneration += 1
  local generation = refreshGeneration
  snapshot.host = hostLabel()

  if not isConfigured() then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("result.not_configured")
    snapshot.today = {}
    snapshot.upcoming = {}
    snapshot.projects = {}
    snapshot.defaultProject = nil
    snapshot.counts = { overdue = 0, today = 0, soon = 0 }
    refreshPending = false
    refreshStartedAt = 0
    updateRevision("not-configured")
    publishSnapshot()
    return
  end

  if not snapshot.available then
    snapshot.loading = true
    publishSnapshot()
  end
  noctalia.setUpdateInterval(1000)

  local pending = 2
  local bag = {}
  local errors = {}
  local function finish()
    if generation ~= refreshGeneration then
      return
    end
    pending -= 1
    if pending > 0 then
      return
    end
    refreshPending = false
    refreshStartedAt = 0
    local okApply, errApply = pcall(applySnapshot, bag.tasks or {}, bag.projects or {}, errors)
    if not okApply then
      noctalia.log(`vikunja: apply snapshot failed: {tostring(errApply)}`)
      snapshot.loading = false
      snapshot.error = "refresh failed: " .. tostring(errApply)
      publishSnapshot()
    end
    noctalia.setUpdateInterval(refreshIntervalMs())
    if refreshAgain then
      refreshAgain = false
      refreshAll()
    end
  end

  fetchTasksPage(tasksFilter(), 1, {}, function(tasks, err)
    if generation ~= refreshGeneration then
      return
    end
    bag.tasks = tasks
    if err then
      table.insert(errors, "tasks: " .. tostring(err))
    end
    finish()
  end)

  fetchProjects(function(projects, err)
    if generation ~= refreshGeneration then
      return
    end
    bag.projects = projects
    if err then
      table.insert(errors, "projects: " .. tostring(err))
    end
    finish()
  end)
end

-- On demand: open tasks per project (used by the Projects tab).
local COUNT_TTL_SEC = 300

-- Counting open tasks is expensive (a paginated sweep of every open task), so
-- the result is cached for COUNT_TTL_SEC instead of re-counting on every tab open.
local function loadProjectCounts(command)
  if not isConfigured() then
    actionResult({ action = "load_projects" }, false, noctalia.tr("result.not_configured"))
    return
  end
  local force = type(command) == "table" and command.force == true
  local age = nowSec() - (snapshot.openCountsAt or 0)
  if not force and (snapshot.openCountsAt or 0) > 0 and age < COUNT_TTL_SEC then
    publishSnapshot()
    return
  end
  if snapshot.projectsLoading then
    return
  end
  snapshot.projectsLoading = true
  publishSnapshot()

  fetchTasksPage("done = false", 1, {}, function(tasks, err)
    local counts = {}
    local okParse = pcall(function()
      for _, raw in ipairs(tasks) do
        local id = tonumber(raw.project_id) or 0
        counts[id] = (counts[id] or 0) + 1
      end
    end)
    if not okParse then
      noctalia.log("vikunja: project count parse error")
    end
    snapshot.openCounts = counts
    snapshot.openCountsAt = nowSec()
    local out = {}
    for _, project in ipairs(snapshot.projects or {}) do
      table.insert(out, { id = project.id, title = project.title, open = counts[project.id] or 0 })
    end
    table.sort(out, function(a, b)
      if a.open ~= b.open then return a.open > b.open end
      return lower(a.title) < lower(b.title)
    end)
    snapshot.projects = out
    snapshot.projectsLoading = false
    snapshot.updatedAt = nowSec()
    if err then
      snapshot.error = "projects: " .. tostring(err)
    end
    publishSnapshot()
  end)
end

-- Tasks the plugin knows about: today, upcoming, the open project.
local function findTask(id)
  local wanted = tonumber(id)
  if wanted == nil then
    return nil
  end
  for _, task in ipairs(snapshot.today or {}) do
    if task.id == wanted then
      return task
    end
  end
  for _, task in ipairs(snapshot.upcoming or {}) do
    if task.id == wanted then
      return task
    end
  end
  for _, task in ipairs(snapshot.projectTasks or {}) do
    if task.id == wanted then
      return task
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- browsing one project

local function fetchProjectViews(projectId, onDone)
  apiRequest("GET", `projects/{projectId}/views?per_page=50`, nil, function(res)
    local data, err = decodeBody(res)
    if data == nil or type(data) ~= "table" then
      onDone({}, err or "unexpected view payload")
      return
    end
    local out = {}
    for _, raw in ipairs(data) do
      if type(raw) == "table" and tonumber(raw.id) ~= nil then
        table.insert(out, {
          id = tonumber(raw.id),
          title = asString(raw.title),
          kind = lower(asString(raw.view_kind)),
          position = tonumber(raw.position) or 0,
          defaultBucketId = tonumber(raw.default_bucket_id) or 0,
        })
      end
    end
    table.sort(out, function(a, b) return a.position < b.position end)
    onDone(out, nil)
  end)
end

-- A kanban view is what makes the bucket grouping possible; otherwise use the
-- first view (list/table/gantt all return the same tasks).
local function pickView(views)
  -- A project can hold more than one kanban view; the one the board is used with
  -- is the last, not the first (they are ordered by position).
  local kanban = nil
  for _, view in ipairs(views) do
    if view.kind == "kanban" then
      kanban = view
    end
  end
  return kanban or views[#views] or views[1]
end

local function fetchBuckets(projectId, viewId, onDone)
  apiRequest("GET", `projects/{projectId}/views/{viewId}/buckets?per_page=50`, nil, function(res)
    local data, err = decodeBody(res)
    if data == nil or type(data) ~= "table" then
      onDone({}, err or "unexpected bucket payload")
      return
    end
    local out = {}
    for _, raw in ipairs(data) do
      if type(raw) == "table" and tonumber(raw.id) ~= nil then
        table.insert(out, {
          id = tonumber(raw.id),
          title = asString(raw.title),
          position = tonumber(raw.position) or 0,
        })
      end
    end
    table.sort(out, function(a, b) return a.position < b.position end)
    onDone(out, nil)
  end)
end

local function fetchViewTasks(projectId, viewId, page, acc, onDone)
  local path = `projects/{projectId}/views/{viewId}/tasks?` .. query({
    { "filter", "done = false" },
    { "filter_timezone", timezone() },
    -- Vikunja 2.6.0 accepts repeated sort params; a comma list 400s.
    { "sort_by", "due_date" },
    { "sort_by", "priority" },
    { "order_by", "asc" },
    { "order_by", "desc" },
    { "per_page", PAGE_SIZE },
    { "page", page },
  })
  apiRequest("GET", path, nil, function(res)
    local data, err = decodeBody(res)
    if data == nil then
      onDone(acc, err)
      return
    end
    if type(data) ~= "table" then
      onDone(acc, "unexpected task payload")
      return
    end
    for _, raw in ipairs(data) do
      table.insert(acc, raw)
    end
    if #data == PAGE_SIZE and page < MAX_PAGES then
      fetchViewTasks(projectId, viewId, page + 1, acc, onDone)
      return
    end
    onDone(acc, nil)
  end)
end

local function projectById(projectId)
  for _, project in ipairs(snapshot.projects or {}) do
    if project.id == projectId then
      return project
    end
  end
  return { id = projectId, title = "#" .. tostring(projectId) }
end

-- Publishes one project's tasks, grouped by its kanban buckets when it has
-- any. `buckets` may be empty for a list/table/gantt project.
-- Switching to another project while one loads must drop the older answers.
local projectGeneration = 0

-- v2 serves a kanban view's buckets with their tasks in one request ("List a
-- kanban view's buckets with their tasks"). The flat v1 endpoint does not carry
-- bucket assignments, which is why this path uses v2.
local function fetchBucketTasks(projectId, viewId, includeDone, onDone)
  local args = {
    { "filter_timezone", timezone() },
    { "per_page", PAGE_SIZE },
    { "page", 1 },
  }
  if not includeDone then
    table.insert(args, 1, { "filter", "done = false" })
  end
  local path = `projects/{projectId}/views/{viewId}/buckets/tasks?` .. query(args)
  apiRequestV2("GET", path, nil, function(res)
    local data, err = decodeBody(res)
    if data == nil then
      onDone(nil, err)
      return
    end
    local items = type(data) == "table" and (data.items or data) or nil
    if type(items) ~= "table" then
      onDone(nil, "unexpected bucket payload")
      return
    end
    onDone(items, nil)
  end)
end

-- When `bucketItems` (the v2 kanban answer) is present the buckets and their
-- tasks come from it; otherwise a flat task list is processed.
local function publishProject(projectId, project, view, bucketItems, bucketError, tasks, taskError, generation)
  if generation ~= nil and generation ~= projectGeneration then
    return
  end
  local errors = {}
  if bucketError ~= nil then
    table.insert(errors, "buckets: " .. tostring(bucketError))
  end
  if taskError ~= nil then
    table.insert(errors, "tasks: " .. tostring(taskError))
  end

  local titles = {}
  for _, candidate in ipairs(snapshot.projects or {}) do
    titles[candidate.id] = candidate.title
  end

  local parsed = {}
  local bucketGroups = {}
  local okParse = pcall(function()
    if type(bucketItems) == "table" and #bucketItems > 0 then
      for _, rawBucket in ipairs(bucketItems) do
        if type(rawBucket) == "table" and tonumber(rawBucket.id) ~= nil then
          local group = { id = tonumber(rawBucket.id), title = asString(rawBucket.title), tasks = {} }
          for _, rawTask in ipairs(rawBucket.tasks or {}) do
            local task = parseTask(rawTask, titles, projectId)
            if task ~= nil then
              table.insert(group.tasks, task)
              table.insert(parsed, task)
            end
          end
          sortTasks(group.tasks)
          table.insert(bucketGroups, group)
        end
      end
      return
    end
    for _, raw in ipairs(tasks or {}) do
      local task = parseTask(raw, titles, projectId)
      if task ~= nil then
        table.insert(parsed, task)
      end
    end
  end)
  if not okParse then
    noctalia.log("vikunja: project task parse error")
  end

  sortTasks(parsed)
  snapshot.projectTasks = parsed
  snapshot.projectBuckets = bucketGroups
  snapshot.projectOpen = {
    id = project.id,
    title = project.title,
    viewId = view.id,
    view = view.title,
    kind = view.kind,
  }
  local cache = snapshot.viewCache or {}
  cache[projectId] = { id = view.id, title = view.title, kind = view.kind, buckets = buckets or {} }
  snapshot.viewCache = cache
  snapshot.projectLoading = false
  projectStartedAt = 0
  snapshot.updatedAt = nowSec()
  snapshot.error = errors[1] or ""
  publishSnapshot()
  if #errors > 0 and #parsed == 0 then
    actionResult({ action = "open_project" }, false, noctalia.tr("result.failed", { error = errors[1] }))
  else
    actionResult({ action = "open_project" }, true, noctalia.tr("result.project_opened", {
      project = project.title,
    }))
  end
end

openProject = function(command)
  local projectId = tonumber(command.projectId or command.id)
  if projectId == nil then
    actionResult(command, false, noctalia.tr("result.failed", { error = "unknown project" }))
    return
  end
  snapshot.projectLoading = true
  projectStartedAt = nowSec()
  projectGeneration += 1
  local generation = projectGeneration
  snapshot.error = ""
  -- Opening a different project clears the header too, otherwise the panel would
  -- show the previous project's name above a list that is now empty.
  if snapshot.projectOpen ~= nil and snapshot.projectOpen.id ~= projectId then
    snapshot.projectOpen = nil
  end
  snapshot.projectTasks = {}
  snapshot.projectBuckets = {}
  publishSnapshot()

  local function stale()
    return generation ~= projectGeneration
  end

  local project = projectById(projectId)

  local function loadTasks(view, buckets, bucketError)
    fetchViewTasks(projectId, view.id, 1, {}, function(tasks, taskError)
      publishProject(projectId, project, view, buckets, bucketError, tasks, taskError, generation)
    end)
  end

  -- A project already opened once knows which view to use: the extra views call
  -- is saved, the tasks still come fresh.
  local cached = (snapshot.viewCache or {})[projectId]
  if cached ~= nil then
    if cached.kind == "kanban" and cached.id ~= 0 then
      fetchBucketTasks(projectId, cached.id, snapshot.showDone, function(items, err)
        if generation ~= projectGeneration then
          return
        end
        publishProject(projectId, project, cached, items, err, nil, nil, generation)
      end)
    else
      loadTasks(cached, {}, nil)
    end
    return
  end

  fetchProjectViews(projectId, function(views, viewError)
    if stale() then
      return
    end
    if viewError ~= nil and (views == nil or #views == 0) then
      snapshot.projectLoading = false
      projectStartedAt = 0
      snapshot.error = "views: " .. tostring(viewError)
      snapshot.projectOpen = { id = project.id, title = project.title, viewId = 0, view = "", kind = "list" }
      snapshot.projectTasks = {}
      snapshot.projectBuckets = {}
      publishSnapshot()
      actionResult(command, false, noctalia.tr("result.failed", { error = tostring(viewError) }))
      return
    end
    local view = pickView(views or {}) or { id = 0, title = "", kind = "list" }
    if view.kind ~= "kanban" or view.id == 0 then
      loadTasks(view, {}, nil)
      return
    end
    -- Kanban: v2 returns the buckets together with their tasks in one request.
    fetchBucketTasks(projectId, view.id, snapshot.showDone, function(items, err)
      if generation ~= projectGeneration then
        return
      end
      if items == nil then
        -- No v2 (or it failed): fall back to the flat task list.
        publishProject(projectId, project, view, nil, nil, {}, err, generation)
        return
      end
      publishProject(projectId, project, view, items, err, nil, nil, generation)
    end)
  end)
end

-- Buckets of one project's kanban view: what the add row can file a new task
-- into, and what a drag-and-drop move targets.

local function loadBuckets(command)
  local projectId = tonumber(command.projectId or command.id)
  if projectId == nil then
    return
  end
  fetchProjectViews(projectId, function(views, viewError)
    local view = pickView(views or {})
    if viewError ~= nil or view == nil or view.kind ~= "kanban" or view.id == 0 then
      snapshot.addProject = projectId
      snapshot.addBuckets = {}
      publishSnapshot()
      return
    end
    fetchBuckets(projectId, view.id, function(buckets, bucketError)
      snapshot.addProject = projectId
      snapshot.addViewId = view.id
      snapshot.addBuckets = bucketError ~= nil and {} or (buckets or {})
      local cache = snapshot.viewCache or {}
      cache[projectId] = { id = view.id, title = view.title, kind = view.kind, buckets = buckets or {} }
      snapshot.viewCache = cache
      publishSnapshot()
    end)
  end)
end

-- Move a task into another bucket of the open project's kanban view.
-- Buckets can be deleted in the web UI while the panel still holds their ids:
-- drop the cached view and let the next click work on fresh data.
local function dropBucketCache(projectId)
  local cache = snapshot.viewCache or {}
  if projectId ~= nil then
    cache[projectId] = nil
  end
  snapshot.viewCache = cache
  snapshot.addBuckets = {}
  snapshot.addProject = nil
end

-- Vikunja answers a dead bucket reference with "Bucket does not exist [BucketID: …]".
local function staleBucketError(text)
  local message = lower(text)
  return message:find("bucket", 1, true) ~= nil and message:find("exist", 1, true) ~= nil
end

local function moveTask(command)
  local taskId = tonumber(command.taskId or command.id)
  local bucketId = tonumber(command.bucketId)
  local open = snapshot.projectOpen
  if taskId == nil or bucketId == nil or open == nil then
    actionResult(command, false, noctalia.tr("result.failed", { error = "unknown task or bucket" }))
    return
  end
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local task = findTask(taskId)
  setBusy(true)
  publishSnapshot()
  apiRequestV2("PUT", `projects/{open.id}/views/{open.viewId}/buckets/{bucketId}/tasks`, {
    task_id = taskId,
  }, function(res)
    local data, err = decodeBody(res)
    local ok = data ~= nil and (res.status == nil or res.status < 400)
    setBusy(false)
    if ok then
      local bucketTitle = tostring(bucketId)
      for _, bucket in ipairs(snapshot.projectBuckets or {}) do
        if bucket.id == bucketId then
          bucketTitle = bucket.title
        end
      end
      local message = noctalia.tr("result.moved", {
        title = task ~= nil and task.title or tostring(taskId),
        bucket = bucketTitle,
      })
      actionResult(command, true, message)
      notifyOk(message)
      publishSnapshot()
      openProject({ action = "open_project", projectId = open.id, requestId = command.requestId })
    elseif staleBucketError(tostring(err) .. " " .. tostring(res and res.body)) then
      local message = noctalia.tr("result.bucket_gone")
      dropBucketCache(open.id)
      actionResult(command, false, message)
      notifyErr(message)
      openProject({ action = "open_project", projectId = open.id, requestId = command.requestId })
    else
      actionResult(command, false, noctalia.tr("result.failed", { error = err or "move failed" }))
      notifyErr(noctalia.tr("result.failed", { error = err or "move failed" }))
      publishSnapshot()
    end
  end)
end

local function closeProject(command)
  snapshot.projectOpen = nil
  snapshot.projectTasks = {}
  snapshot.projectBuckets = {}
  snapshot.projectLoading = false
  projectStartedAt = 0
  publishSnapshot()
  actionResult(command, true, noctalia.tr("result.project_closed"))
end

-- ---------------------------------------------------------------------------
-- actions

local function finishAction(command, ok, message)
  setBusy(false)
  actionResult(command, ok, message)
  if ok then
    notifyOk(message)
  else
    notifyErr(message)
  end
  publishSnapshot()
  refreshAll()
  -- With a project open, its task list is refreshed too: a new task or a
  -- postponed date has to show up there.
  local open = snapshot.projectOpen
  if open ~= nil then
    openProject({ action = "open_project", projectId = open.id, requestId = "refresh-open" })
  end
end

local function toggleDone(command)
  snapshot.showDone = not snapshot.showDone
  local open = snapshot.projectOpen
  if open ~= nil then
    openProject({ action = "open_project", projectId = open.id, requestId = command and command.requestId })
  else
    publishSnapshot()
    actionResult(command or { action = "toggle_done" }, true,
      noctalia.tr(snapshot.showDone and "result.done_shown" or "result.done_hidden"))
  end
end

local function completeTask(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local task = findTask(command.taskId or command.id)
  if task == nil then
    actionResult(command, false, noctalia.tr("result.failed", { error = "unknown task" }))
    return
  end
  setBusy(true)
  publishSnapshot()
  -- The button is the only way back from done, so it toggles.
  local target = task.done ~= true
  apiRequest("POST", "tasks/" .. task.id, { done = target }, function(res)
    local data, err = decodeBody(res)
    local ok = data ~= nil and (res.status == nil or res.status < 400)
    if ok then
      finishAction(command, true, noctalia.tr(target and "result.completed" or "result.reopened", { title = task.title }))
    else
      finishAction(command, false, noctalia.tr("result.failed", { error = err or "complete failed" }))
    end
  end)
end

local function postponeTask(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local task = findTask(command.taskId or command.id)
  if task == nil then
    actionResult(command, false, noctalia.tr("result.failed", { error = "unknown task" }))
    return
  end
  local days = tonumber(command.days) or 1
  days = math.max(1, math.min(365, math.floor(days)))

  setBusy(true)
  publishSnapshot()
  -- Re-read the task so a due date changed elsewhere is respected.
  apiRequest("GET", "tasks/" .. task.id, nil, function(res)
    local raw, err = decodeBody(res)
    local due = task.due
    if type(raw) == "table" then
      due = parseDue(raw.due_date) or due
    end
    local base = due and startOfLocalDay(due) or startOfLocalDay()
    local target = dayShift(base, days)
    do
      local dueString = dueStringFor(target)
      apiRequest("POST", "tasks/" .. task.id, { due_date = dueString }, function(res2)
        local data2, err2 = decodeBody(res2)
        local ok = data2 ~= nil and (res2.status == nil or res2.status < 400)
        if not ok then
          finishAction(command, false, noctalia.tr("result.failed", {
            error = err2 or err or "postpone failed",
          }))
          return
        end
        -- A comment keeps the history readable in Vikunja itself.
        apiRequest("PUT", `tasks/{task.id}/comments`, { comment = `+{days}d (Noctalia)` }, function()
          finishAction(command, true, noctalia.tr("result.postponed", {
            title = task.title,
            date = dateLabel(target),
          }))
        end)
      end)
    end
  end)
end

local function addTask(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local title = trim(command.title or command.text)
  if title == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing title" }))
    return
  end
  local project = nil
  if command.projectId ~= nil then
    for _, candidate in ipairs(snapshot.projects or {}) do
      if tostring(candidate.id) == tostring(command.projectId) then
        project = candidate
        break
      end
    end
  end
  project = project or snapshot.defaultProject
  if project == nil then
    actionResult(command, false, noctalia.tr("result.no_project"))
    return
  end

  local days = tonumber(command.days) or 0
  local target = dayShift(startOfLocalDay(), math.max(0, math.min(365, math.floor(days))))
  local body = {
    title = title,
    due_date = dueStringFor(target),
  }
  local bucketId = tonumber(command.bucketId)
  if bucketId ~= nil and bucketId > 0 then
    body.bucket_id = bucketId
  end
  setBusy(true)
  publishSnapshot()
  body.due_date = dueStringFor(target)
  apiRequest("PUT", `projects/{project.id}/tasks`, body, function(res)
    local data, err = decodeBody(res)
    local ok = data ~= nil and (res.status == nil or res.status < 400)
    if ok then
      finishAction(command, true, noctalia.tr("result.added", { title = title }))
    elseif bucketId ~= nil and staleBucketError(tostring(err) .. " " .. tostring(res and res.body)) then
      local message = noctalia.tr("result.bucket_gone")
      dropBucketCache(project.id)
      finishAction(command, false, message)
    else
      finishAction(command, false, noctalia.tr("result.failed", { error = err or "add failed" }))
    end
  end)
end

local function openTask(command)
  local task = findTask(command.taskId or command.id)
  local url = command.url or (task and task.url) or ""
  if url == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "unknown task" }))
    return
  end
  noctalia.runAsync({ "xdg-open", url })
  actionResult(command, true, noctalia.tr("result.opened", {
    name = task ~= nil and task.title or url,
  }))
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  if command.action == "refresh" then
    refreshAll()
    return
  end
  if command.action == "load_projects" then
    loadProjectCounts(command)
    return
  end
  if command.action == "open_project" then
    openProject(command)
    return
  end
  if command.action == "close_project" then
    closeProject(command)
    return
  end
  if command.action == "toggle_done" then
    toggleDone(command)
  elseif command.action == "load_buckets" then
    loadBuckets(command)
    return
  end
  if command.action == "move_task" then
    moveTask(command)
    return
  end
  if command.action == "complete" then
    completeTask(command)
    return
  end
  if command.action == "postpone" then
    postponeTask(command)
    return
  end
  if command.action == "add" then
    addTask(command)
    return
  end
  if command.action == "open" then
    openTask(command)
    return
  end
  if command.action == "copy" then
    local text = trim(command.text or command.name)
    if text ~= "" then
      noctalia.copyToClipboard(text, "text/plain")
      actionResult(command, true, noctalia.tr("result.copied", { text = text }))
      notifyOk(noctalia.tr("result.copied", { text = text }))
    end
    return
  end
  actionResult(command, false, "Unknown action: " .. command.action)
end

noctalia.state.watch(COMMAND_KEY, executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  if actionBusy and actionBusySince > 0 and os.time() - actionBusySince > 12 then
    setBusy(false)
    publishSnapshot()
  end
  refreshAll()
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())
  refreshPending = false
  refreshStartedAt = 0
  refreshAll()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshPending = false
    refreshStartedAt = 0
    refreshAll()
  elseif event == "projects" then
    loadProjectCounts({ action = "load_projects" })
  elseif event == "add" then
    -- `add <title>`: quick capture from a keybinding or script.
    addTask({ action = "add", title = tostring(_payload or ""), requestId = "ipc-add" })
  elseif event == "complete" then
    completeTask({ action = "complete", taskId = tonumber(_payload), requestId = "ipc-complete" })
  elseif event == "postpone" then
    -- `postpone <taskId> <days>`
    local id, days = tostring(_payload or ""):match("^(%d+)%s+(%d+)$")
    if id ~= nil then
      postponeTask({ action = "postpone", taskId = tonumber(id), days = tonumber(days), requestId = "ipc-postpone" })
    end
  elseif event == "move" then
    -- `move <taskId> <bucketId>` inside the open project's kanban view
    local id, bucket = tostring(_payload or ""):match("^(%d+)%s+(%d+)$")
    if id ~= nil then
      moveTask({ action = "move", taskId = tonumber(id), bucketId = tonumber(bucket), requestId = "ipc-move" })
    end
  elseif event == "open_project" then
    openProject({ action = "open_project", projectId = _payload })
  elseif event == "close_project" then
    closeProject({ action = "close_project" })
  end
end