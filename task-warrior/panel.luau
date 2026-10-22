--!nonstrict
-- Task Warrior panel: tag tabs, task list, sort/filter, and a form that doubles
-- as quick-add (empty selection) or edit (click a task to load its fields).
-- A pure view over the service's "tasks"/"status" state; all taskwarrior
-- mutations are sent to the service as "request" state values.

local ENV = getfenv()

-- ── data from the service ────────────────────────────────────────────────────

local tasks = noctalia.state.get("tasks") or {}
local status = noctalia.state.get("status")

-- ── local ui state ───────────────────────────────────────────────────────────

local currentTag = "" -- "" is the pseudo-tag for the All tab
local sortBy = "urgency"
local projectFilter = "" -- "" = all projects
local form = { description = "", tags = "", project = "", due = "", priority = "" }
local editingTask = nil -- task currently loaded into `form`, nil = add mode; also the diffing baseline on save
local editingOriginal = nil -- snapshot of `form` at selection time, for change detection
local shown = {} -- tasks currently rendered; row callbacks index into this
local requestSeq = 0
-- Bumped whenever a new task is selected or the form is discarded, and used as
-- part of the form inputs' `key` so they get fresh nodes and reseed with the
-- new values — ui.input is uncontrolled (see ui_tree_reconciler.cpp), a reused
-- node ignores prop `value` changes after its first render.
local formGeneration = 0

-- ── service requests ─────────────────────────────────────────────────────────

local function sendRequest(kind, payload)
  requestSeq += 1
  local req = payload or {}
  req.seq = "panel-" .. requestSeq
  req.kind = kind
  noctalia.state.set("request", req)
end

-- ── date helpers ─────────────────────────────────────────────────────────────

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

-- "overdue" | "today" | "later" | nil
local function dueLevel(s)
  local due = parseTaskDate(s)
  if due == nil then
    return nil
  end
  local now = os.time()
  if due < now then
    return "overdue"
  end
  if os.date("%Y%m%d", due) == os.date("%Y%m%d", now) then
    return "today"
  end
  return "later"
end

local function formatDue(s)
  local due = parseTaskDate(s)
  if due == nil then
    return ""
  end
  local now = os.time()
  if due < now then
    local days = math.floor((now - due) / 86400)
    if days >= 1 then
      return noctalia.tr("panel.due.overdue-days", { days = tostring(days) })
    end
    return noctalia.tr("panel.due.overdue")
  end
  local today = os.date("%Y%m%d", now)
  local dueDay = os.date("%Y%m%d", due)
  if dueDay == today then
    return noctalia.tr("panel.due.today", { time = os.date("%H:%M", due) })
  end
  local dayDiff = math.floor((due - now) / 86400)
  if dayDiff <= 1 then
    return noctalia.tr("panel.due.tomorrow")
  end
  if dayDiff <= 7 then
    return noctalia.tr("panel.due.in-days", { days = tostring(dayDiff) })
  end
  return os.date("%Y-%m-%d", due)
end

-- A taskwarrior-parseable, round-trippable rendering of a task's due date, for
-- seeding the edit form's due input (unlike formatDue's relative text, which
-- taskwarrior can't parse back as a due expression).
local function dueEditValue(s)
  local due = parseTaskDate(s)
  if due == nil then
    return ""
  end
  return os.date("%Y-%m-%dT%H:%M:%S", due)
end

-- ── colors ───────────────────────────────────────────────────────────────────

local function priorityColor(priority)
  if priority == "H" then
    return "error"
  elseif priority == "M" then
    return "primary"
  elseif priority == "L" then
    return "on_surface_variant"
  end
  return "outline"
end

local function dueColor(s)
  local level = dueLevel(s)
  if level == "overdue" then
    return "error"
  elseif level == "today" then
    return "primary"
  end
  return "on_surface_variant"
end

-- ── derived task views ───────────────────────────────────────────────────────

local function collectTags(list)
  local seen = {}
  local result = {}
  for _, t in ipairs(list) do
    for _, tag in ipairs(t.tags or {}) do
      if not seen[tag] then
        seen[tag] = true
        table.insert(result, tag)
      end
    end
  end
  table.sort(result)
  return result
end

local function collectProjects(list)
  local seen = {}
  local result = {}
  for _, t in ipairs(list) do
    local p = t.project
    if p ~= nil and p ~= "" and not seen[p] then
      seen[p] = true
      table.insert(result, p)
    end
  end
  table.sort(result)
  return result
end

local function tabTags()
  local recorded = collectTags(tasks)
  if noctalia.getConfig("show_all_tab") then
    table.insert(recorded, 1, "")
  end
  return recorded
end

-- Self-healing active tab: falls back to the first tab when the stored tag
-- disappears from the recorded tags.
local function effectiveTag(tags)
  for _, tag in ipairs(tags) do
    if tag == currentTag then
      return currentTag
    end
  end
  return tags[1] or ""
end

local function hasTag(t, tag)
  for _, candidate in ipairs(t.tags or {}) do
    if candidate == tag then
      return true
    end
  end
  return false
end

local priorityRank = { H = 3, M = 2, L = 1 }

local function compareTasks(a, b)
  local urgencyA = a.urgency or 0
  local urgencyB = b.urgency or 0
  if sortBy == "due" then
    local da = parseTaskDate(a.due)
    local db = parseTaskDate(b.due)
    if da ~= nil and db ~= nil and da ~= db then
      return da < db
    end
    if (da ~= nil) ~= (db ~= nil) then
      return da ~= nil
    end
  elseif sortBy == "priority" then
    local pa = priorityRank[a.priority] or 0
    local pb = priorityRank[b.priority] or 0
    if pa ~= pb then
      return pa > pb
    end
  elseif sortBy == "project" then
    local pa = a.project or ""
    local pb = b.project or ""
    if pa ~= pb then
      if pa == "" or pb == "" then
        return pb == ""
      end
      return pa < pb
    end
  end
  if urgencyA ~= urgencyB then
    return urgencyA > urgencyB
  end
  return (a.uuid or "") < (b.uuid or "")
end

-- Tasks for the active tab, before the project filter (feeds the project dropdown).
local function tabTasks(tag)
  if tag == "" then
    return tasks
  end
  local result = {}
  for _, t in ipairs(tasks) do
    if hasTag(t, tag) then
      table.insert(result, t)
    end
  end
  return result
end

local function visibleTasks(tag)
  local result = {}
  for _, t in ipairs(tabTasks(tag)) do
    if projectFilter == "" or t.project == projectFilter then
      table.insert(result, t)
    end
  end
  table.sort(result, compareTasks)
  return result
end

-- ── add form ─────────────────────────────────────────────────────────────────

-- The tags input follows the active tab: "+work" on the +work tab, empty on All.
local function defaultTagsText(tag)
  return tag ~= "" and ("+" .. tag) or ""
end

local function parseTags(text)
  local result = {}
  for tag in string.gmatch(string.gsub(text, "%+", " "), "%S+") do
    table.insert(result, tag)
  end
  return result
end

-- Quick due-date chips: tapping one drops its taskwarrior expression into the
-- due input (tap again to clear). `chip` is the short label; `key` is what
-- taskwarrior parses.
local duePresets = {
  { key = "1h", chip = noctalia.tr("panel.due-preset.1h") },
  { key = "4h", chip = noctalia.tr("panel.due-preset.4h") },
  { key = "eod", chip = noctalia.tr("panel.due-preset.today") },
  { key = "tomorrow", chip = noctalia.tr("panel.due-preset.tomorrow") },
  { key = "3d", chip = noctalia.tr("panel.due-preset.3d") },
  { key = "1w", chip = noctalia.tr("panel.due-preset.1w") },
  { key = "2w", chip = noctalia.tr("panel.due-preset.2w") },
  { key = "1m", chip = noctalia.tr("panel.due-preset.1m") },
}

-- L/M/H, each with the accent it lights up in when active.
local priorityChoices = {
  { key = "L", color = "tertiary" }, -- green
  { key = "M", color = "primary" }, -- yellow
  { key = "H", color = "error" }, -- red
}

local sortOptions = {
  { key = "urgency", name = noctalia.tr("panel.sort.urgency") },
  { key = "due", name = noctalia.tr("panel.sort.due") },
  { key = "priority", name = noctalia.tr("panel.sort.priority") },
  { key = "project", name = noctalia.tr("panel.sort.project") },
}

local function optionNames(options)
  local names = {}
  for _, o in ipairs(options) do
    table.insert(names, o.name)
  end
  return names
end

local function optionKeyByName(options, name)
  for _, o in ipairs(options) do
    if o.name == name then
      return o.key
    end
  end
  return nil
end

local render -- forward declaration

-- ── static callbacks ─────────────────────────────────────────────────────────

-- Re-render only while editing: that's the one case where a keystroke can
-- flip the Save/Discard buttons' visibility (formChanged()). Add-mode typing
-- doesn't need it — the input already shows what was typed on its own.
local function rerenderIfEditing()
  if editingTask ~= nil then
    render()
  end
end

function onDescChange(value)
  form.description = value
  rerenderIfEditing()
end

function onTagsChange(value)
  form.tags = value
  rerenderIfEditing()
end

function onProjectChange(value)
  form.project = value
  rerenderIfEditing()
end

function onDueChange(value)
  form.due = value
  rerenderIfEditing()
end

function onSortChange(_, text)
  local key = optionKeyByName(sortOptions, text)
  if key ~= nil and key ~= sortBy then
    sortBy = key
    render()
  end
end

function onAddSubmit()
  local description = string.gsub(form.description, "^%s+", "")
  if description == "" then
    return
  end
  local fields = {}
  local formTags = parseTags(form.tags)
  if #formTags > 0 then
    fields.tags = { from = {}, to = formTags }
  end
  if form.project ~= "" then
    fields.project = form.project
  end
  if form.due ~= "" then
    fields.due = form.due
  end
  if form.priority ~= "" then
    fields.priority = form.priority
  end
  sendRequest("add", { description = description, fields = fields })
  -- Deliberately leave the form populated: it lets you fire off a batch of
  -- similar tasks, tweaking only what differs. (Clearing fields here would also
  -- desync from the still-visible input text, since ui.input is uncontrolled.)
  render()
end

function onUndo()
  sendRequest("undo")
end

function onRefresh()
  sendRequest("refresh")
end

-- form callbacks (form doubles as add-form and edit-form, keyed by editingTask)

local function formChanged()
  if editingOriginal == nil then
    return false
  end
  return form.description ~= editingOriginal.description
    or form.project ~= editingOriginal.project
    or form.due ~= editingOriginal.due
    or form.tags ~= editingOriginal.tags
    or form.priority ~= editingOriginal.priority
end

-- Drop any in-progress edit and empty the compose form back to a blank
-- quick-add (tags default to the active tab). Bumps formGeneration so the
-- uncontrolled inputs reseed from the now-empty `form`.
local function resetForm()
  formGeneration += 1
  editingTask = nil
  editingOriginal = nil
  form.description = ""
  form.project = ""
  form.due = ""
  form.priority = ""
  form.tags = defaultTagsText(effectiveTag(tabTags()))
end

function onFormDiscard()
  resetForm()
  render()
end

function onFormSave()
  if editingTask == nil then
    return
  end
  local t = editingTask
  local fields = {}
  local description = string.gsub(form.description, "^%s+", "")
  if description ~= "" and description ~= (t.description or "") then
    fields.description = description
  end
  if form.project ~= (t.project or "") then
    fields.project = form.project
  end
  if form.due ~= editingOriginal.due then
    fields.due = form.due
  end
  if form.priority ~= (t.priority or "") then
    fields.priority = form.priority
  end
  fields.tags = { from = t.tags or {}, to = parseTags(form.tags) }
  sendRequest("modify", { uuid = t.uuid, fields = fields })
  onFormDiscard()
end

function onFormDone()
  if editingTask ~= nil then
    sendRequest("done", { uuid = editingTask.uuid })
    onFormDiscard()
  end
end

function onFormDelete()
  if editingTask ~= nil then
    sendRequest("delete", { uuid = editingTask.uuid })
    onFormDiscard()
  end
end

-- ── dynamic callbacks (per tab / per row / per priority key) ─────────────────

local function tabCb(i, tag)
  local name = "tab_" .. i
  ENV[name] = function()
    currentTag = tag
    projectFilter = ""
    form.tags = defaultTagsText(tag)
    render()
  end
  return name
end

local function selectTask(t)
  formGeneration += 1
  editingTask = t
  form.description = t.description or ""
  form.project = t.project or ""
  form.due = dueEditValue(t.due)
  form.tags = table.concat(t.tags or {}, " ")
  form.priority = t.priority or ""
  editingOriginal = {
    description = form.description,
    project = form.project,
    due = form.due,
    tags = form.tags,
    priority = form.priority,
  }
end

local function rowCb(action, i)
  local name = "row_" .. action .. "_" .. i
  ENV[name] = function()
    local t = shown[i]
    if t == nil then
      return
    end
    if action == "done" then
      sendRequest("done", { uuid = t.uuid })
    elseif action == "del" then
      sendRequest("delete", { uuid = t.uuid })
    elseif action == "select" then
      selectTask(t)
      render()
    end
  end
  return name
end

local function prioCb(key)
  local name = "prio_" .. key
  ENV[name] = function()
    form.priority = (form.priority == key) and "" or key
    render()
  end
  return name
end

function onProjectFilter(_, text)
  local value = text == noctalia.tr("panel.filter.all-projects") and "" or text
  if value ~= projectFilter then
    projectFilter = value
    render()
  end
end

-- ── ui builders ──────────────────────────────────────────────────────────────

-- Compact L/M/H priority picker: three letter buttons, each over a colour bar
-- that's faint when idle and lit in the level's accent when active. Tapping the
-- active one again clears the priority (see prioCb).
local function prioritySelector(current)
  local cells = {}
  for _, c in ipairs(priorityChoices) do
    local active = current == c.key
    table.insert(
      cells,
      ui.column({ gap = 3, align = "center" }, {
        ui.button({
          text = c.key,
          variant = active and "default" or "ghost",
          width = 44,
          fontSize = 12,
          onClick = prioCb(c.key),
        }),
        ui.box({ width = 22, height = 3, radius = 2, fill = active and c.color or (c.color .. "/0.25") }),
      })
    )
  end
  return ui.row({ gap = 2, align = "center" }, cells)
end

-- Tap a due chip to fill the due input with its expression; tap the active one
-- again to clear it. Bump formGeneration so the (uncontrolled) due input picks
-- up the new value instead of keeping whatever text it was last seeded with.
local function dueChipCb(key)
  local name = "due_chip_" .. key
  ENV[name] = function()
    form.due = (form.due == key) and "" or key
    formGeneration += 1
    render()
  end
  return name
end

-- The row under the due input: due-preset chips on the left, then the priority
-- picker and (add form only) the Add button pushed to the right.
local function dueChipRow(current, trailing)
  local items = {}
  for _, o in ipairs(duePresets) do
    table.insert(
      items,
      ui.button({
        text = o.chip,
        variant = current == o.key and "primary" or "ghost",
        fontSize = 11,
        onClick = dueChipCb(o.key),
      })
    )
  end
  table.insert(items, ui.spacer({ flexGrow = 1 }))
  table.insert(items, prioritySelector(form.priority))
  if trailing ~= nil then
    table.insert(items, trailing)
  end
  return ui.row({ gap = 4, align = "center" }, items)
end

-- The shared middle of the compose form (tags/project, due, and the chip/
-- priority row) — identical between add and edit apart from placeholders and
-- the submit target. `dueTrailing` rides along on the chip row (see above).
local function composeMiddle(sessionKey, onSubmit, tagsPlaceholder, projectPlaceholder, duePlaceholder, dueTrailing)
  return {
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = sessionKey .. "-tags",
        value = form.tags,
        placeholder = tagsPlaceholder,
        flexGrow = 1,
        onChange = "onTagsChange",
        onSubmit = onSubmit,
      }),
      ui.input({
        key = sessionKey .. "-project",
        value = form.project,
        placeholder = projectPlaceholder,
        flexGrow = 1,
        onChange = "onProjectChange",
        onSubmit = onSubmit,
      }),
    }),
    ui.input({
      key = sessionKey .. "-due",
      value = form.due,
      placeholder = duePlaceholder,
      onChange = "onDueChange",
      onSubmit = onSubmit,
    }),
    dueChipRow(form.due, dueTrailing),
  }
end

local function taskRow(i, t)
  local meta = {}
  if t.project ~= nil and t.project ~= "" then
    table.insert(meta, ui.label({ text = t.project, color = "primary", fontSize = 11 }))
  end
  if t.due ~= nil then
    table.insert(meta, ui.label({ text = formatDue(t.due), color = dueColor(t.due), fontSize = 11 }))
  end
  if t.tags ~= nil and #t.tags > 0 then
    table.insert(meta, ui.label({ text = "+" .. table.concat(t.tags, " +"), color = "on_surface_variant", fontSize = 11, maxLines = 1 }))
  end

  -- border is always set (never omitted): the reconciler only applies a color
  -- prop when present, so an unselected row reusing a previously-selected
  -- row's node would keep a stale border if we left the prop out instead.
  local rowProps = {
    key = t.uuid,
    gap = 8,
    fill = "surface",
    radius = 8,
    padding = 8,
    align = "center",
    border = (editingTask ~= nil and t.uuid == editingTask.uuid) and "primary" or "primary/0",
    borderWidth = 1,
  }

  return ui.row(rowProps, {
    ui.box({ width = 4, height = 34, fill = priorityColor(t.priority), radius = 2 }),
    ui.button({ glyph = "check", variant = "ghost", onClick = rowCb("done", i) }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.button({ text = t.description or "", variant = "ghost", contentAlign = "start", onClick = rowCb("select", i) }),
      ui.row({ gap = 10 }, meta),
    }),
    ui.label({ text = string.format("%.1f", t.urgency or 0), color = "on_surface_variant", fontSize = 11 }),
    ui.button({ glyph = "trash", variant = "ghost", onClick = rowCb("del", i) }),
  })
end

local function renderListView()
  local tags = tabTags()
  local tag = effectiveTag(tags)
  shown = visibleTasks(tag)

  -- tabs
  local tabButtons = {}
  for i, t in ipairs(tags) do
    table.insert(
      tabButtons,
      ui.button({
        text = t == "" and noctalia.tr("panel.tabs.all") or ("+" .. t),
        variant = t == tag and "primary" or "ghost",
        onClick = tabCb(i, t),
      })
    )
  end

  -- project filter options
  local projectSelect = { { key = "", name = noctalia.tr("panel.filter.all-projects") } }
  for _, p in ipairs(collectProjects(tabTasks(tag))) do
    table.insert(projectSelect, { key = p, name = p })
  end
  local projectIndex = 0
  for i, o in ipairs(projectSelect) do
    if o.key == projectFilter then
      projectIndex = i - 1
    end
  end

  local sortIndex = 0
  for i, o in ipairs(sortOptions) do
    if o.key == sortBy then
      sortIndex = i - 1
    end
  end

  -- task rows
  local rows = {}
  for i, t in ipairs(shown) do
    table.insert(rows, taskRow(i, t))
  end

  local children = {
    -- header
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "swords", color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 15 }),
      ui.label({
        text = noctalia.trp("panel.header.count", #shown),
        color = "on_surface_variant",
        fontSize = 11,
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ glyph = "arrow-back-up", variant = "ghost", onClick = "onUndo" }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
    }),
  }

  -- error banner
  if type(status) == "table" and status.error ~= nil and status.error ~= "" then
    table.insert(children, ui.label({ text = status.error, color = "error", fontSize = 11 }))
  end

  table.insert(children, ui.row({ gap = 4 }, tabButtons))

  -- compose form: quick-add when nothing is selected, edit when a task is.
  local formChildren = {}
  local sessionKey = "form-" .. tostring(formGeneration)

  if editingTask ~= nil then
    local t = editingTask

    table.insert(formChildren, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "pencil", color = "primary" }),
      ui.label({ text = noctalia.tr("panel.edit.title"), fontSize = 12, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = noctalia.tr("panel.edit.urgency", { urgency = string.format("%.1f", t.urgency or 0) }),
        color = "on_surface_variant",
        fontSize = 11,
      }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onFormDiscard" }),
    }))
    table.insert(formChildren, ui.input({
      key = sessionKey .. "-description",
      value = form.description,
      placeholder = noctalia.tr("panel.edit.description"),
      onChange = "onDescChange",
      onSubmit = "onFormSave",
    }))
    for _, c in ipairs(composeMiddle(
      sessionKey,
      "onFormSave",
      noctalia.tr("panel.edit.tags-placeholder"),
      noctalia.tr("panel.edit.project"),
      noctalia.tr("panel.edit.due-placeholder")
    )) do
      table.insert(formChildren, c)
    end

    local actionButtons = {}
    if formChanged() then
      table.insert(actionButtons, ui.button({ text = noctalia.tr("panel.edit.save"), glyph = "check", variant = "primary", onClick = "onFormSave" }))
      table.insert(actionButtons, ui.button({ text = noctalia.tr("panel.edit.discard"), glyph = "x", variant = "outline", onClick = "onFormDiscard" }))
    end
    table.insert(actionButtons, ui.spacer({ flexGrow = 1 }))
    table.insert(actionButtons, ui.button({ text = noctalia.tr("panel.edit.done"), glyph = "circle-check", variant = "outline", onClick = "onFormDone" }))
    table.insert(actionButtons, ui.button({ text = noctalia.tr("panel.edit.delete"), glyph = "trash", variant = "destructive", onClick = "onFormDelete" }))
    table.insert(formChildren, ui.row({ gap = 8 }, actionButtons))
  else
    table.insert(formChildren, ui.input({
      key = sessionKey .. "-description",
      value = form.description,
      placeholder = noctalia.tr("panel.add.placeholder"),
      onChange = "onDescChange",
      onSubmit = "onAddSubmit",
    }))
    for _, c in ipairs(composeMiddle(
      sessionKey,
      "onAddSubmit",
      noctalia.tr("panel.add.tags-placeholder"),
      noctalia.tr("panel.add.project-placeholder"),
      noctalia.tr("panel.add.due-placeholder"),
      ui.button({
        text = noctalia.tr("panel.add.submit"),
        glyph = "plus",
        variant = "primary",
        height = 34,
        onClick = "onAddSubmit",
      })
    )) do
      table.insert(formChildren, c)
    end
  end

  table.insert(
    children,
    ui.column({ gap = 8, fill = "surface", radius = 10, padding = 10 }, formChildren)
  )

  -- sort + project filter
  table.insert(
    children,
    ui.row({ gap = 6 }, {
      ui.select({
        options = optionNames(sortOptions),
        selectedIndex = sortIndex,
        width = 200,
        onChange = "onSortChange",
      }),
      ui.select({
        options = optionNames(projectSelect),
        selectedIndex = projectIndex,
        width = 200,
        onChange = "onProjectFilter",
      }),
      ui.spacer({ flexGrow = 1 }),
    })
  )

  -- task list
  if #rows > 0 then
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 6 }, rows))
  else
    table.insert(
      children,
      ui.row({ flexGrow = 1, justify = "center", align = "center" }, {
        ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface_variant" }),
      })
    )
  end

  -- flexGrow=1: without it this column sizes to its natural content height
  -- instead of the panel's fixed height, so the ui.scroll below never gets a
  -- bounded "remaining space" to grow into — it just renders at full content
  -- height with no scrollbar, and the panel window clips whatever overflows.
  return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
end

render = function()
  panel.render(renderListView())
end

-- ── state + lifecycle ────────────────────────────────────────────────────────

noctalia.state.watch("tasks", function(value)
  tasks = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("status", function(value)
  status = value
  render()
end)

function onOpen(_)
  -- Each open starts fresh: close + reopen is the "clear the form" gesture.
  resetForm()
  sendRequest("refresh")
  render()
end

function update()
  -- Slow tick to keep relative due dates ("in 2d", "overdue") fresh while open.
  render()
end

form.tags = defaultTagsText(effectiveTag(tabTags()))
noctalia.setUpdateInterval(60000)
render()
