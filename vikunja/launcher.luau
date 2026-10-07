--!nonstrict
-- /vk launcher: search open tasks, add a task, complete one.

local STATE_KEY = "vk_snapshot"
local COMMAND_KEY = "vk_command"
local PANEL_ID = "omertahaoztop/vikunja:manager"
local MAX_ROWS = 12

local snapshot = noctalia.state.get(STATE_KEY) or {
  configured = false,
  available = false,
  loading = true,
  error = "",
  host = "",
  counts = { overdue = 0, today = 0, soon = 0 },
  today = {},
  upcoming = {},
  projects = {},
  defaultProject = nil,
}

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
  end
end)

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function send(action, values)
  local command = { action = action, requestId = "launcher-" .. tostring(os.time()) }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
end

local function statusRow(title, subtitle, glyph)
  return { id = "", title = title, subtitle = subtitle, glyph = glyph or "checkbox" }
end

local function scoreText(filter, ...)
  if filter == "" then
    return 1
  end
  local best = nil
  for i = 1, select("#", ...) do
    local text = tostring(select(i, ...) or "")
    if text ~= "" then
      local score = noctalia.fuzzyScore(filter, text)
      if score ~= nil and (best == nil or score > best) then
        best = score
      end
      if best == nil and lower(text):find(lower(filter), 1, true) then
        best = 0.5
      end
    end
  end
  return best
end

local function openTasks()
  local out = {}
  for _, task in ipairs(snapshot.today or {}) do
    table.insert(out, task)
  end
  for _, task in ipairs(snapshot.upcoming or {}) do
    table.insert(out, task)
  end
  return out
end

-- Tasks matching `filter`, best match first.
local function matchedTasks(filter)
  local scored = {}
  for _, task in ipairs(openTasks()) do
    local score = scoreText(filter, task.title, task.project, task.dueText)
    if score ~= nil then
      table.insert(scored, { task = task, score = score })
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  local out = {}
  for index = 1, math.min(#scored, MAX_ROWS) do
    table.insert(out, scored[index].task)
  end
  return out
end

local function taskRows(tasks)
  local rows = {}
  for _, task in ipairs(tasks) do
    table.insert(rows, {
      id = "task:" .. tostring(task.id),
      title = task.title,
      subtitle = noctalia.tr("launcher.task_subtitle", {
        project = task.project,
        due = task.dueText,
      }),
      glyph = task.bucket == "overdue" and "alert-triangle" or "checkbox",
      score = 1,
    })
  end
  return rows
end

local function projectRows(filter)
  local rows = {}
  for _, project in ipairs(snapshot.projects or {}) do
    local score = scoreText(filter, project.title)
    if score ~= nil then
      table.insert(rows, {
        id = "proj:" .. tostring(project.id),
        title = project.title,
        subtitle = noctalia.tr("panel.project_open", { n = tonumber(project.open) or 0 }),
        glyph = "stack-2",
        score = score,
      })
    end
  end
  table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
  while #rows > MAX_ROWS do
    table.remove(rows)
  end
  return rows
end

local function addRow(text)
  local project = snapshot.defaultProject
  local projectTitle = project ~= nil and project.title or "—"
  return {
    id = "add:" .. text,
    title = noctalia.tr("launcher.add_title", { title = text }),
    subtitle = noctalia.tr("launcher.add_subtitle", { project = projectTitle }),
    glyph = "plus",
    score = 100,
  }
end

local function doneRow(task)
  return {
    id = "done:" .. tostring(task.id),
    title = `{noctalia.tr("actions.complete")}: {task.title}`,
    subtitle = noctalia.tr("launcher.task_subtitle", { project = task.project, due = task.dueText }),
    glyph = "check",
    score = 99,
  }
end

function onQuery(query)
  if not snapshot.configured then
    launcher.setResults(query, {
      statusRow(noctalia.tr("panel.not_configured"), "", "settings"),
      { id = "act:panel", title = noctalia.tr("actions.refresh"), subtitle = "Open settings", glyph = "layout-dashboard" },
    })
    return
  end

  if snapshot.loading and not snapshot.available then
    send("refresh")
    launcher.setResults(query, { statusRow(noctalia.tr("launcher.loading"), snapshot.host, "loader") })
    return
  end

  if not snapshot.available then
    launcher.setResults(query, {
      statusRow(noctalia.tr("launcher.unavailable"), snapshot.error or "", "cloud-off"),
      { id = "act:refresh", title = noctalia.tr("actions.refresh"), subtitle = "", glyph = "refresh" },
    })
    return
  end

  local text = trim(query)
  if text == "" then
    local rows = taskRows(matchedTasks(""))
    if #rows == 0 then
      rows = { statusRow(noctalia.tr("panel.empty"), noctalia.tr("panel.add_hint", {
        project = snapshot.defaultProject ~= nil and snapshot.defaultProject.title or "—",
      }), "checkbox") }
    end
    launcher.setResults(query, rows)
    return
  end

  local head = lower(text:match("^%S+") or "")
  local rest = trim(text:match("^%S+%s+(.*)$") or "")

  if head == "add" and rest ~= "" then
    local rows = { addRow(rest) }
    for _, row in ipairs(taskRows(matchedTasks(rest))) do
      table.insert(rows, row)
    end
    launcher.setResults(query, rows)
    return
  end

  if head == "done" and rest ~= "" then
    local tasks = matchedTasks(rest)
    if #tasks == 0 then
      launcher.setResults(query, { statusRow(noctalia.tr("launcher.no-matches"), rest, "search") })
      return
    end
    local rows = { doneRow(tasks[1]) }
    for index = 2, #tasks do
      table.insert(rows, {
        id = "done:" .. tostring(tasks[index].id),
        title = `{noctalia.tr("actions.complete")}: {tasks[index].title}`,
        subtitle = noctalia.tr("launcher.task_subtitle", {
          project = tasks[index].project,
          due = tasks[index].dueText,
        }),
        glyph = "check",
        score = 1,
      })
    end
    launcher.setResults(query, rows)
    return
  end

  if head == "projects" then
    local rows = projectRows(rest)
    if #rows == 0 then
      rows = { statusRow(noctalia.tr("launcher.no-matches"), rest, "search") }
    end
    launcher.setResults(query, rows)
    return
  end

  local rows = { addRow(text) }
  for _, row in ipairs(taskRows(matchedTasks(text))) do
    table.insert(rows, row)
  end
  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == nil or id == "" then
    return
  end

  local text = id:match("^add:(.+)$")
  if text then
    send("add", { title = text })
    noctalia.notify(noctalia.tr("title"), noctalia.tr("result.added", { title = text }))
    return
  end

  local taskId = id:match("^task:(%d+)$")
  if taskId then
    send("open", { taskId = tonumber(taskId) })
    return
  end

  local doneId = id:match("^done:(%d+)$")
  if doneId then
    send("complete", { taskId = tonumber(doneId) })
    return
  end

  local projectId = id:match("^proj:(%d+)$")
  if projectId then
    send("open", { url = `{snapshot.base or ""}/projects/{projectId}` })
    return
  end

  if id == "act:panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end
  if id == "act:refresh" then
    send("refresh")
    return
  end
end
