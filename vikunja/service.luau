--!nonstrict
-- Vikunja backend: today/overdue counts, task list, add, complete, postpone.

local STATE_KEY = "vk_snapshot"
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
  projectLoading = false,
  -- Buckets of the project the add row targets (kanban projects only).
  addProject = nil,
  addBuckets = {},
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local refreshStartedAt = 0
local projectStartedAt = 0
local actionBusy = false
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

local function startOfLocalDay(epoch)
  local t = os.date("*t", epoch or os.time())
  return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

local function dayShift(epoch, days)
  local t = os.date("*t", epoch)
  return os.time({
    year = t.year, month = t.month, day = t.day + (days or 0),
    hour = 0, min = 0, sec = 0,
  })
end

-- Local DUE_HOUR on the day of `epoch`, expressed as the UTC string Vikunja wants.
local function dueStringFor(epoch)
  local t = os.date("*t", epoch)
  local localStamp = os.time({
    year = t.year, month = t.month, day = t.day,
    hour = DUE_HOUR, min = 0, sec = 0,
  })
  return os.date("!%Y-%m-%dT%H:%M:%SZ", localStamp)
end

local function dateLabel(epoch)
  return os.date("%Y-%m-%d", epoch)
end

local function timeLabel(epoch)
  return os.date("%H:%M", epoch)
end

local function utcOffsetSeconds()
  return os.time() - os.time(os.date("!*t"))
end

-- Vikunja sends UTC RFC3339; the plugin works in local days.
local function parseDue(raw)
  local text = asString(raw)
  if text == "" or text:match("^0001%-01%-01") then
    return nil
  end
  local year, month, day, hour, min, sec = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if year == nil then
    return nil
  end
  local utcEpoch = os.time({
    year = tonumber(year), month = tonumber(month), day = tonumber(day),
    hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
  })
  return utcEpoch + utcOffsetSeconds()
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

local function apiRequest(method, path, body, callback)
  local req = {
    url = baseUrl() .. "/api/v1/" .. path:gsub("^/+", ""),
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
    return nil, "HTTP " .. tostring(res.status)
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
end

local function parseTask(raw, titles)
  if type(raw) ~= "table" then
    return nil
  end
  local id = tonumber(raw.id)
  if id == nil then
    return nil
  end
  local due = parseDue(raw.due_date)
  local projectId = tonumber(raw.project_id) or 0
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
  snapshot.projects = projects
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
    { "sort_by", "due_date,priority" },
    { "order_by", "asc,desc" },
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

  if refreshPending then
    refreshAgain = true
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
local function loadProjectCounts()
  if not isConfigured() then
    actionResult({ action = "load_projects" }, false, noctalia.tr("result.not_configured"))
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
  for _, view in ipairs(views) do
    if view.kind == "kanban" then
      return view
    end
  end
  return views[1]
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
    { "sort_by", "due_date,priority" },
    { "order_by", "asc,desc" },
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

local function groupByBucket(tasks, buckets)
  local groups = {}
  local index = {}
  for _, bucket in ipairs(buckets) do
    table.insert(groups, { id = bucket.id, title = bucket.title, tasks = {} })
    index[bucket.id] = #groups
  end
  local leftover = {}
  for _, task in ipairs(tasks) do
    local position = task.bucketId ~= nil and index[task.bucketId] or nil
    if position ~= nil then
      table.insert(groups[position].tasks, task)
    else
      table.insert(leftover, task)
    end
  end
  if #leftover > 0 then
    table.insert(groups, { id = 0, title = noctalia.tr("panel.bucket_other"), tasks = leftover })
  end
  -- Empty buckets stay visible: they are drop targets in Vikunja itself.
  return groups
end

local function projectById(projectId)
  for _, project in ipairs(snapshot.projects or {}) do
    if project.id == projectId then
      return project
    end
  end
  return { id = projectId, title = "#" .. tostring(projectId) }
end

local function openProject(command)
  local projectId = tonumber(command.projectId or command.id)
  if projectId == nil then
    actionResult(command, false, noctalia.tr("result.failed", { error = "unknown project" }))
    return
  end
  -- A slow or stuck load must never swallow the next click: after a few
  -- seconds the click wins and the load starts over.
  if snapshot.projectLoading and projectStartedAt > 0 and (nowSec() - projectStartedAt) < 5 then
    return
  end
  snapshot.projectLoading = true
  projectStartedAt = nowSec()
  snapshot.error = ""
  publishSnapshot()

  local project = projectById(projectId)
  fetchProjectViews(projectId, function(views, viewError)
    local view = pickView(views)
    local errors = {}
    if viewError then
      table.insert(errors, "views: " .. tostring(viewError))
    end
    view = view or { id = 0, title = "", kind = "list" }

    local function loadTasks(buckets, bucketError)
      if bucketError then
        table.insert(errors, "buckets: " .. tostring(bucketError))
      end
      fetchViewTasks(projectId, view.id, 1, {}, function(tasks, taskError)
        if taskError then
          table.insert(errors, "tasks: " .. tostring(taskError))
        end
        local titles = {}
        for _, candidate in ipairs(snapshot.projects or {}) do
          titles[candidate.id] = candidate.title
        end
        local parsed = {}
        local okParse = pcall(function()
          for _, raw in ipairs(tasks) do
            local task = parseTask(raw, titles)
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
        snapshot.projectBuckets = #buckets > 0 and groupByBucket(parsed, buckets) or {}
        snapshot.projectOpen = {
          id = project.id,
          title = project.title,
          viewId = view.id,
          view = view.title,
          kind = view.kind,
        }
        snapshot.projectLoading = false
        projectStartedAt = 0
        snapshot.updatedAt = nowSec()
        snapshot.error = errors[1] or ""
        if view.kind == "kanban" and view.id ~= 0 then
          snapshot.addProject = project.id
          snapshot.addViewId = view.id
          snapshot.addBuckets = buckets or {}
        end
        publishSnapshot()
        if #errors > 0 and #parsed == 0 then
          actionResult(command, false, noctalia.tr("result.failed", { error = errors[1] }))
        else
          actionResult(command, true, noctalia.tr("result.project_opened", { project = project.title }))
        end
      end)
    end

    if view.kind == "kanban" and view.id ~= 0 then
      fetchBuckets(projectId, view.id, function(buckets, bucketError)
        loadTasks(buckets or {}, bucketError)
      end)
      return
    end
    loadTasks({}, nil)
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
    local view = pickView(views)
    if viewError ~= nil or view == nil or view.kind ~= "kanban" or view.id == 0 then
      snapshot.addProject = projectId
      snapshot.addBuckets = {}
      publishSnapshot()
      return
    end
    fetchBuckets(projectId, view.id, function(buckets, bucketError)
      snapshot.addProject = projectId
      snapshot.addBuckets = bucketError ~= nil and {} or (buckets or {})
      snapshot.addViewId = view.id
      publishSnapshot()
    end)
  end)
end

-- Move a task into another bucket of the open project's kanban view.
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
  actionBusy = true
  publishSnapshot()
  apiRequest("POST", `projects/{open.id}/views/{open.viewId}/buckets/{bucketId}/tasks`, {
    task_id = taskId,
  }, function(res)
    local data, err = decodeBody(res)
    local ok = data ~= nil and (res.status == nil or res.status < 400)
    actionBusy = false
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
  actionBusy = false
  actionResult(command, ok, message)
  if ok then
    notifyOk(message)
  else
    notifyErr(message)
  end
  publishSnapshot()
  refreshAll()
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
  actionBusy = true
  publishSnapshot()
  apiRequest("POST", "tasks/" .. task.id, { done = true }, function(res)
    local data, err = decodeBody(res)
    local ok = data ~= nil and (res.status == nil or res.status < 400)
    if ok then
      finishAction(command, true, noctalia.tr("result.completed", { title = task.title }))
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

  actionBusy = true
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
    apiRequest("POST", "tasks/" .. task.id, { due_date = dueStringFor(target) }, function(res2)
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
  actionBusy = true
  publishSnapshot()
  apiRequest("PUT", `projects/{project.id}/tasks`, body, function(res)
    local data, err = decodeBody(res)
    local ok = data ~= nil and (res.status == nil or res.status < 400)
    if ok then
      finishAction(command, true, noctalia.tr("result.added", { title = title }))
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
  actionResult(command, true, noctalia.tr("result.copied", { text = url }))
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
    loadProjectCounts()
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
  if command.action == "load_buckets" then
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
    loadProjectCounts()
  elseif event == "open_project" then
    openProject({ action = "open_project", projectId = _payload })
  elseif event == "close_project" then
    closeProject({ action = "close_project" })
  end
end
