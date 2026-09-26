--!nonstrict
-- Vikunja manager panel: today, upcoming, per-project browsing, quick add and
-- row actions (complete, postpone, move between kanban buckets).

local STATE_KEY = "vk_snapshot"
local COMMAND_KEY = "vk_command"
local RESULT_KEY = "vk_action_result"

local snapshot = noctalia.state.get(STATE_KEY) or {
  configured = false,
  available = false,
  loading = true,
  busy = false,
  projectsLoading = false,
  error = "",
  host = "",
  counts = { overdue = 0, today = 0, soon = 0 },
  today = {},
  upcoming = {},
  projects = {},
  defaultProject = nil,
  projectOpen = nil,
  projectTasks = {},
  projectBuckets = {},
  projectLoading = false,
  addProject = nil,
  addBuckets = {},
}

local tab = "today"
local selectedId = nil
local projectIndex = 0
local bucketIndex = 0
local addText = ""
local addKey = 0
local requestCounter = 0
local feedback = ""
local feedbackError = false
local dirty = true

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function send(action, values)
  local command = { action = action, requestId = nextRequestId() }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
  return command.requestId
end

local function projectOpen()
  return snapshot.projectOpen
end

local function tasksForTab()
  if tab == "upcoming" then
    return snapshot.upcoming or {}
  end
  if tab == "projects" then
    return snapshot.projectTasks or {}
  end
  return snapshot.today or {}
end

local function selectedTask()
  if selectedId == nil then
    return nil
  end
  for _, list in ipairs({ snapshot.today or {}, snapshot.upcoming or {}, snapshot.projectTasks or {} }) do
    for _, task in ipairs(list) do
      if task.id == selectedId then
        return task
      end
    end
  end
  return nil
end

local function selectedProject()
  local list = snapshot.projects or {}
  return list[projectIndex + 1] or snapshot.defaultProject
end

local function selectedBucket()
  return (snapshot.addBuckets or {})[bucketIndex] or nil
end

local function projectOptions()
  local options = {}
  for _, project in ipairs(snapshot.projects or {}) do
    table.insert(options, project.title ~= "" and project.title or ("#" .. tostring(project.id)))
  end
  return options
end

local function bucketOptions()
  local options = { tr("panel.bucket_any") }
  for _, bucket in ipairs(snapshot.addBuckets or {}) do
    table.insert(options, bucket.title ~= "" and bucket.title or ("#" .. tostring(bucket.id)))
  end
  return options
end

local function dueLabel(task)
  return task.dueText ~= "" and task.dueText or tr("task.no_due")
end

local function taskRow(task)
  local selected = task.id == selectedId
  local overdue = task.bucket == "overdue"
  return ui.button({
    key = "task-" .. tostring(task.id),
    text = `{task.title}  ·  {task.project}  ·  {dueLabel(task)}`,
    glyph = overdue and "alert-triangle" or "circle",
    contentAlign = "start",
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = task.id
      feedback = ""
      render()
    end,
  })
end

local function taskRows(list)
  local rows = {}
  for _, task in ipairs(list) do
    table.insert(rows, taskRow(task))
  end
  return rows
end

local function projectRows()
  local rows = {}
  for index, project in ipairs(snapshot.projects or {}) do
    local selected = (index - 1) == projectIndex
    table.insert(rows, ui.button({
      key = "project-" .. tostring(project.id),
      text = `{project.title}  ·  {tostring(project.open or 0)} open`,
      glyph = "stack-2",
      contentAlign = "start",
      variant = selected and "primary" or "outline",
      selected = selected,
      onClick = function()
        feedback = ""
        send("open_project", { projectId = project.id })
        render()
      end,
    }))
  end
  return rows
end

-- One project's tasks: kanban projects render their buckets as drop zones, so a
-- row can be dragged onto another bucket.
local function projectTaskList()
  local rows = {}
  local buckets = snapshot.projectBuckets or {}
  if #buckets > 0 then
    for _, bucket in ipairs(buckets) do
      local children = {
        ui.row({ key = "bucket-" .. tostring(bucket.id), gap = 6, align = "center", paddingH = 2 }, {
          ui.glyph({ name = "columns-3", size = 14, color = "on_surface_variant" }),
          ui.label({
            text = `{bucket.title ~= "" and bucket.title or tr("panel.bucket_any")} · {#bucket.tasks}`,
            color = "on_surface_variant",
            fontSize = 12,
            fontWeight = "bold",
          }),
        }),
      }
      for _, task in ipairs(bucket.tasks) do
        table.insert(children, ui.dragSource({
          dragType = "vk-task",
          payload = tostring(task.id),
          previewAncestor = 1,
          enabled = snapshot.busy ~= true,
        }, { taskRow(task) }))
      end
      table.insert(rows, ui.dropZone({
        key = "zone-" .. tostring(bucket.id),
        accepts = { "vk-task" },
        value = tostring(bucket.id),
        onDrop = "onDropTask",
        direction = "column",
        gap = 8,
        align = "stretch",
        expandOnDrag = true,
      }, children))
    end
    return ui.column({ key = "project-tasks", align = "stretch", gap = 12, flexGrow = 1 }, rows)
  end
  for _, task in ipairs(snapshot.projectTasks or {}) do
    table.insert(rows, taskRow(task))
  end
  return ui.column({ key = "project-tasks", align = "stretch", gap = 8, flexGrow = 1 }, rows)
end

local function projectHeader()
  local open = projectOpen()
  if open == nil then
    return nil
  end
  local view = open.view ~= "" and open.view or open.kind
  return ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text = tr("panel.project_back"),
      glyph = "arrow-left",
      variant = "ghost",
      controlSize = "sm",
      onClick = "onProjectBack",
    }),
    ui.label({ text = open.title, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
    ui.label({
      text = `{view} · {tr("panel.project_open", { n = #(snapshot.projectTasks or {}) })}`,
      color = "on_surface_variant",
      fontSize = 12,
    }),
    ui.button({
      text = tr("actions.open"),
      glyph = "external-link",
      variant = "outline",
      controlSize = "sm",
      onClick = "onOpenProject",
    }),
  })
end

-- Bucket moves without a pointer: one button per bucket of the open project.
local function taskMoveRow(task)
  if projectOpen() == nil or #(snapshot.projectBuckets or {}) == 0 then
    return ui.spacer({ flexGrow = 0, height = 0 })
  end
  local buttons = {
    ui.label({ text = tr("actions.move_to"), color = "on_surface_variant", fontSize = 12 }),
  }
  for _, bucket in ipairs(snapshot.projectBuckets) do
    local current = bucket.id == task.bucketId
    table.insert(buttons, ui.button({
      text = bucket.title ~= "" and bucket.title or tr("panel.bucket_any"),
      variant = current and "primary" or "outline",
      controlSize = "sm",
      enabled = not current and snapshot.busy ~= true,
      onClick = function()
        send("move_task", { taskId = task.id, bucketId = bucket.id })
      end,
    }))
  end
  return ui.row({ gap = 6, align = "center" }, buttons)
end

local function taskToolbar(busy)
  local task = selectedTask()
  if task == nil then
    return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
  end
  return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({
        name = task.bucket == "overdue" and "alert-triangle" or "checkbox",
        size = 18,
        color = task.bucket == "overdue" and "error" or "tertiary",
      }),
      ui.label({ text = task.title, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = dueLabel(task), color = "on_surface_variant", fontSize = 12 }),
    }),
    ui.row({ gap = 6 }, {
      ui.button({
        text = tr("actions.complete"),
        glyph = "check",
        variant = "primary",
        enabled = not busy,
        onClick = "onComplete",
      }),
      ui.button({
        text = tr("actions.postpone_1"),
        variant = "outline",
        enabled = not busy,
        onClick = "onPostpone1",
      }),
      ui.button({
        text = tr("actions.postpone_3"),
        variant = "outline",
        enabled = not busy,
        onClick = "onPostpone3",
      }),
      ui.button({ text = tr("actions.open"), glyph = "external-link", variant = "outline", onClick = "onOpenTask" }),
      ui.button({ text = tr("actions.open_project"), glyph = "stack-2", variant = "outline", onClick = "onOpenTaskProject" }),
      ui.button({ text = tr("actions.copy"), glyph = "copy", variant = "ghost", onClick = "onCopyTask" }),
    }),
    taskMoveRow(task),
  })
end

-- Projects tab: either the project list (with open counts) or one project's
-- tasks (see projectTaskList).
local function toolbar()
  local busy = snapshot.busy == true
  if tab == "projects" and projectOpen() == nil then
    -- Opening a project is a single click on its row; nothing else is offered here.
    return ui.label({ text = tr("panel.projects_hint"), color = "on_surface_variant" })
  end
  return taskToolbar(busy)
end

local function emptyList(message)
  return ui.column({ key = "empty-" .. tab, align = "center", justify = "center", padding = 24, gap = 8, flexGrow = 1 }, {
    ui.glyph({ name = "checkbox", size = 34, color = "on_surface_variant" }),
    ui.label({ text = message, color = "on_surface_variant", textAlign = "center" }),
  })
end

local function itemList()
  if tab == "projects" then
    if projectOpen() ~= nil then
      if #(snapshot.projectTasks or {}) == 0 and #(snapshot.projectBuckets or {}) == 0 then
        return emptyList(snapshot.projectLoading and tr("panel.loading") or tr("panel.empty"))
      end
      return projectTaskList()
    end
    local rows = projectRows()
    if #rows == 0 then
      return emptyList(snapshot.projectsLoading and tr("panel.projects_loading") or tr("panel.empty"))
    end
    return ui.column({ key = "projects", align = "stretch", gap = 8, flexGrow = 1 }, rows)
  end
  local rows = taskRows(tasksForTab())
  if #rows == 0 then
    return emptyList(tr("panel.empty"))
  end
  return ui.column({ key = "tasks-" .. tab, align = "stretch", gap = 8, flexGrow = 1 }, rows)
end

local function tabButton(label, id, cb)
  return ui.button({
    text = label,
    selected = tab == id,
    variant = tab == id and "primary" or "ghost",
    onClick = cb,
  })
end

render = function()
  dirty = false
  local stats = snapshot.counts or { overdue = 0, today = 0, soon = 0 }
  local notes = {}
  if not snapshot.configured then
    table.insert(notes, ui.label({ text = tr("panel.not_configured"), color = "error", maxLines = 3 }))
  end
  if snapshot.loading or snapshot.projectLoading then
    table.insert(notes, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end
  if snapshot.busy then
    table.insert(notes, ui.label({ text = tr("panel.busy"), color = "primary" }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(notes, ui.label({ text = snapshot.error, color = "error", maxLines = 3 }))
  end
  if feedback ~= "" then
    table.insert(notes, ui.label({
      text = feedback,
      color = feedbackError and "error" or "tertiary",
      maxLines = 2,
    }))
  end

  local project = selectedProject()
  local projectTitle = project ~= nil and (project.title ~= "" and project.title or ("#" .. tostring(project.id))) or "—"

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.image({
        path = snapshot.configured == true and "assets/vikunja.png" or "assets/vikunja-grey.png",
        width = 30,
        height = 30,
        fit = "contain",
      }),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({
          text = tr("panel.subtitle") .. (snapshot.host ~= "" and (` · {snapshot.host}`) or ""),
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),

    ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tabs.today"), "today", "onTabToday"),
      tabButton(tr("tabs.upcoming"), "upcoming", "onTabUpcoming"),
      tabButton(tr("tabs.projects"), "projects", "onTabProjects"),
    }),

    ui.label({
      text = tr("panel.summary", {
        today = tonumber(stats.today) or 0,
        overdue = tonumber(stats.overdue) or 0,
        soon = tonumber(stats.soon) or 0,
      }),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = `add-{addKey}`,
        value = addText,
        placeholder = tr("panel.add_placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = "onAddChange",
        onSubmit = "onAddSubmit",
      }),
      ui.select({
        options = projectOptions(),
        selectedIndex = projectIndex,
        placeholder = "—",
        width = 170,
        controlSize = "sm",
        onChange = "onProjectChange",
      }),
      ui.select({
        options = bucketOptions(),
        selectedIndex = bucketIndex,
        placeholder = tr("panel.bucket_any"),
        width = 150,
        controlSize = "sm",
        visible = #(snapshot.addBuckets or {}) > 0,
        onChange = "onBucketChange",
      }),
      ui.button({
        text = tr("panel.add_button"),
        glyph = "plus",
        variant = "primary",
        controlSize = "sm",
        enabled = #(snapshot.projects or {}) > 0,
        onClick = "onAddSubmit",
      }),
    }),

    ui.label({
      text = tr("panel.add_hint", { project = projectTitle }),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),

    (tab == "projects" and projectHeader()) or ui.spacer({ flexGrow = 0, height = 0 }),
    toolbar(),
    ui.column({ gap = 3, align = "stretch" }, notes),
    ui.scroll({ key = "scroll-" .. tab, flexGrow = 1, gap = 10, align = "stretch" }, { itemList() }),
    ui.label({
      text = (snapshot.updatedAt or 0) > 0
        and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", snapshot.updatedAt) })
        or "",
      color = "on_surface_variant",
      fontSize = 11,
    }),
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  local previousRevision = snapshot.revision
  local previousBusy = snapshot.busy
  local previousLoading = snapshot.loading
  local previousProjectsLoading = snapshot.projectsLoading
  local previousError = snapshot.error
  local previousOverdue = (snapshot.counts or {}).overdue
  local previousProjectCount = #(snapshot.projects or {})
  local previousProjectTitle = (selectedProject() or {}).title
  local previousOpen = snapshot.projectOpen ~= nil and snapshot.projectOpen.id or nil
  local previousOpenTasks = #(snapshot.projectTasks or {})
  local previousOpenBuckets = #(snapshot.projectBuckets or {})
  local previousProjectLoading = snapshot.projectLoading
  local previousAddBuckets = #(snapshot.addBuckets or {})

  snapshot = value
  if #(snapshot.projects or {}) ~= previousProjectCount then
    projectIndex = math.max(0, math.min(projectIndex, #(snapshot.projects or {}) - 1))
  end
  if #(snapshot.addBuckets or {}) ~= previousAddBuckets then
    bucketIndex = math.max(0, math.min(bucketIndex, #(snapshot.addBuckets or {})))
  end
  if selectedId ~= nil and selectedTask() == nil then
    selectedId = nil
  end
  if (snapshot.projectOpen ~= nil and snapshot.projectOpen.id or nil) ~= previousOpen
    and snapshot.projectOpen ~= nil
  then
    for index, project in ipairs(snapshot.projects or {}) do
      if project.id == snapshot.projectOpen.id then
        projectIndex = index - 1
        bucketIndex = 0
      end
    end
  end

  if value.revision ~= previousRevision
    or value.busy ~= previousBusy
    or value.loading ~= previousLoading
    or value.projectsLoading ~= previousProjectsLoading
    or value.error ~= previousError
    or (snapshot.counts or {}).overdue ~= previousOverdue
    or (selectedProject() or {}).title ~= previousProjectTitle
    or (snapshot.projectOpen ~= nil and snapshot.projectOpen.id or nil) ~= previousOpen
    or #(snapshot.projectTasks or {}) ~= previousOpenTasks
    or #(snapshot.projectBuckets or {}) ~= previousOpenBuckets
    or snapshot.projectLoading ~= previousProjectLoading
  then
    dirty = true
  end
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then
    return
  end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then
    return
  end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  dirty = true
end)

local function requestBuckets()
  local project = selectedProject()
  if project ~= nil then
    send("load_buckets", { projectId = project.id })
  end
end

function onOpen(_context)
  feedback = ""
  send("refresh")
  if tab == "projects" then
    send("load_projects")
  end
  requestBuckets()
  render()
end

function update()
  if dirty then
    render()
  end
end

function onClose()
  panel.close()
end

function onRefresh()
  send("refresh")
  if tab == "projects" then
    send("load_projects")
  end
  requestBuckets()
end

local function switchTab(next)
  tab = next
  selectedId = nil
  if next == "projects" then
    send("load_projects")
  elseif projectOpen() ~= nil then
    send("close_project")
  end
  render()
end

function onTabToday() switchTab("today") end
function onTabUpcoming() switchTab("upcoming") end
function onTabProjects() switchTab("projects") end

function onAddChange(value)
  addText = type(value) == "string" and value or ""
end

function onAddSubmit()
  local title = noctalia.string.trim(addText)
  if title == "" then
    feedback = ""
    return
  end
  local project = selectedProject()
  local bucket = selectedBucket()
  send("add", {
    title = title,
    projectId = project ~= nil and project.id or nil,
    bucketId = bucket ~= nil and bucket.id or nil,
  })
  addText = ""
  addKey += 1
  render()
end

function onProjectChange(index)
  local value = tonumber(index)
  if value == nil then
    return
  end
  projectIndex = math.max(0, math.floor(value))
  bucketIndex = 0
  requestBuckets()
  render()
end

function onBucketChange(index)
  local value = tonumber(index)
  if value == nil then
    return
  end
  bucketIndex = math.max(0, math.floor(value))
  render()
end

function onComplete()
  local task = selectedTask()
  if task then
    send("complete", { taskId = task.id })
  end
end

function onPostpone1()
  local task = selectedTask()
  if task then
    send("postpone", { taskId = task.id, days = 1 })
  end
end

function onPostpone3()
  local task = selectedTask()
  if task then
    send("postpone", { taskId = task.id, days = 3 })
  end
end

function onOpenTask()
  local task = selectedTask()
  if task then
    send("open", { taskId = task.id, url = task.url })
  end
end

function onCopyTask()
  local task = selectedTask()
  if task then
    send("copy", { text = task.title })
  end
end

function onOpenTaskProject()
  local task = selectedTask()
  if task and task.projectId then
    send("load_buckets", { projectId = task.projectId })
    send("open_project", { projectId = task.projectId })
  end
end

function onProjectBack()
  selectedId = nil
  send("close_project")
  render()
end

function onOpenProject()
  local open = projectOpen()
  local project = selectedProject()
  local id = open ~= nil and open.id or (project ~= nil and project.id or nil)
  if id ~= nil then
    send("open", { url = `{snapshot.base or ""}/projects/{id}` })
  end
end

-- Dropping a row on a bucket moves the task there (the host owns the gesture,
-- this only describes where it landed).
function onDropTask(payload, value)
  local taskId = tonumber(payload)
  local bucketId = tonumber(value)
  if taskId ~= nil and bucketId ~= nil then
    send("move_task", { taskId = taskId, bucketId = bucketId })
  end
end
