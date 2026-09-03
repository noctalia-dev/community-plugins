--!nonstrict

local common = require("./common.luau")

local snapshot = noctalia.state.get(common.SNAPSHOT_KEY) or { status = "starting", upcoming = {} }
local action = noctalia.state.get(common.ACTION_KEY) or { status = "idle" }
local draft = ""
local submitted_request_id = nil
local input_revision = 0
local panel_open = false
local show_diagnostics = false
local render_panel

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function task_due_text(task)
  if type(task) ~= "table" then return tr("due.unscheduled") end
  if task.dueKind == "time" and tonumber(task.dueAt) ~= nil then
    return noctalia.formatTime("%a %b %d, %H:%M", math.floor(task.dueAt / 1000))
  end
  if type(task.dueDay) == "string" and task.dueDay ~= "" then return task.dueDay end
  return tr("due.unscheduled")
end

local function metadata_chips(task)
  local children = {}
  if type(task.project) == "string" and task.project ~= "" then
    table.insert(children, ui.label({ text = "+" .. task.project, color = "primary", fontSize = 11 }))
  end
  for _, tag in ipairs(type(task.tags) == "table" and task.tags or {}) do
    table.insert(children, ui.label({ text = "#" .. tostring(tag), color = "tertiary", fontSize = 11 }))
  end
  if #children == 0 then
    table.insert(children, ui.label({ text = tr("task.no_project_tags"), color = "on_surface_variant", fontSize = 11 }))
  end
  return ui.row({ gap = 8, wrap = true }, children)
end

local function package_controls()
  local status = tostring(snapshot.packageStatus or "missing")
  if status == "running" or status == "checking" then
    local label = status == "checking" and tr("actions.checking_package") or tr("actions.building_package")
    return {
      ui.button({ text = label, glyph = "loader", variant = "outline", controlSize = "sm", enabled = false }),
    }
  end
  if status == "ready" then
    return {
      ui.button({ text = tr("actions.open_package_folder"), glyph = "folder-open", variant = "primary", controlSize = "sm", onClick = "onOpenPackageDirectory" }),
      ui.button({ text = tr("actions.copy_package_path"), glyph = "copy", variant = "outline", controlSize = "sm", onClick = "onCopyPackagePath" }),
      ui.button({ text = tr("actions.rebuild_package"), glyph = "refresh", variant = "ghost", controlSize = "sm", onClick = "onBuildPackage" }),
    }
  end
  return {
    ui.button({
      text = status == "error" and tr("actions.retry_package") or tr("actions.build_package"),
      glyph = status == "error" and "refresh" or "package-import",
      variant = "primary",
      controlSize = "sm",
      onClick = "onBuildPackage",
    }),
  }
end

local function status_banner()
  if snapshot.status == "ready" and snapshot.companionUpdateRequired ~= true then return nil end
  local key = "status." .. tostring(snapshot.status or "starting")
  if snapshot.status == "ready" and snapshot.companionUpdateRequired == true then
    key = "status.companion_outdated"
  end
  local status_error = type(snapshot.error) == "string" and snapshot.error or ""
  local package_status = tostring(snapshot.packageStatus or "missing")
  local guidance = status_error
  if guidance == "" then
    guidance = package_status == "ready" and tr("status.package_ready_hint") or tr("status.setup_hint")
  end
  if package_status == "error" and type(snapshot.packageError) == "string" and snapshot.packageError ~= "" then
    guidance = snapshot.packageError
  end
  return ui.column({ gap = 7, padding = 10, radius = 9, fill = "error/0.08", border = "error/0.25", borderWidth = 1 }, {
    ui.row({ gap = 7, align = "center" }, {
      ui.glyph({ name = "alert-triangle", color = "error", size = 16 }),
      ui.label({ text = tr(key), color = "error", fontWeight = "bold", flexGrow = 1 }),
    }),
    ui.label({ text = guidance, color = "on_surface_variant", fontSize = 11, maxLines = 4 }),
    ui.row({ gap = 7, wrap = true }, package_controls()),
    ui.row({ gap = 7 }, {
      ui.button({ text = tr("actions.launch"), glyph = "external-link", variant = "outline", controlSize = "sm", onClick = "onLaunch" }),
      ui.button({ text = tr("actions.refresh"), glyph = "refresh", variant = "ghost", controlSize = "sm", onClick = "onRefresh" }),
    }),
  })
end

local function action_banner()
  if action.status == "idle" or action.status == "working" then return nil end
  local color = action.status == "success" and "primary"
    or action.status == "unknown" and "tertiary" or "error"
  local text
  if action.status == "success" then
    text = tr("action.success." .. tostring(action.type or "default"))
  elseif action.status == "unknown" then
    text = action.error or tr("error.outcome_unknown")
  else
    text = action.error or tr("error.command_failed")
  end
  return ui.label({ text = text, color = color, fontSize = 11, maxLines = 3 })
end

local function undo_card()
  local undo = snapshot.undo
  if type(undo) ~= "table" or (tonumber(undo.expiresAt) or 0) <= noctalia.nowMs() then return nil end
  local task = undo.task
  if type(task) ~= "table" then return nil end
  return ui.row({ gap = 8, align = "center", padding = 9, radius = 8, fill = "primary/0.08" }, {
    ui.glyph({ name = "circle-check", color = "primary", size = 16 }),
    ui.label({ text = tr("undo.completed", { title = task.title or tr("task.untitled") }), flexGrow = 1, maxLines = 2, fontSize = 11 }),
    ui.button({ text = tr("actions.undo"), variant = "ghost", controlSize = "sm", onClick = "onUndo" }),
  })
end

local function task_card(task)
  if type(task) ~= "table" then
    return ui.column({ gap = 8, padding = 18, align = "center", radius = 10, fill = "surface_container" }, {
      ui.glyph({ name = "circle-check", size = 28, color = "primary" }),
      ui.label({ text = tr("task.none_due"), fontWeight = "bold" }),
      ui.label({ text = tr("task.none_due_hint"), color = "on_surface_variant", fontSize = 11 }),
    })
  end

  local due_at = common.task_due_at(task)
  local overdue = due_at ~= nil and due_at < noctalia.nowMs()
  local tracked = type(snapshot.currentTask) == "table" and snapshot.currentTask.id == task.id
  local busy = common.action_busy(action)
  local overdue_text_color = tostring(noctalia.getConfig("overdue_text_color") or "error")
  local details = {
    ui.row({ gap = 8, align = "start" }, {
      ui.glyph({ name = tracked and "player-play-filled" or "circle-dashed-check", color = tracked and "primary" or overdue and "error" or "on_surface", size = 18 }),
      ui.label({ text = task.title or tr("task.untitled"), fontSize = 16, fontWeight = "bold", flexGrow = 1, maxLines = 4 }),
    }),
    ui.row({ gap = 7, align = "center" }, {
      ui.glyph({ name = "calendar-time", color = overdue and "error" or "on_surface_variant", size = 14 }),
      ui.label({ text = task_due_text(task), color = overdue and overdue_text_color or "on_surface_variant", fontSize = 11 }),
      ui.label({ text = "• " .. common.relative_due(task), color = overdue and overdue_text_color or "on_surface_variant", fontSize = 11 }),
    }),
    metadata_chips(task),
  }

  if (tonumber(task.timeEstimate) or 0) > 0 or (tonumber(task.timeSpent) or 0) > 0 then
    table.insert(details, ui.row({ gap = 12 }, {
      ui.label({ text = tr("task.estimate", { value = common.format_duration(task.timeEstimate) }), color = "on_surface_variant", fontSize = 11 }),
      ui.label({ text = tr("task.spent", { value = common.format_duration(task.timeSpent) }), color = "on_surface_variant", fontSize = 11 }),
    }))
  end

  if type(task.notes) == "string" and common.trim(task.notes) ~= "" then
    table.insert(details, ui.separator({}))
    table.insert(details, ui.markdown({ text = task.notes, maxWidth = 420 }))
  end

  table.insert(details, ui.separator({}))
  local primary_actions = {
    ui.button({
      text = busy and tr("actions.working") or tr("actions.complete"),
      glyph = "check",
      variant = "primary",
      enabled = not busy,
      onClick = "onComplete",
    }),
    ui.button({ text = tr("actions.open"), glyph = "external-link", variant = "outline", enabled = not busy, onClick = "onOpenTask" }),
  }
  if noctalia.getConfig("show_timer_controls") ~= false then
    table.insert(primary_actions, ui.button({
      text = tracked and tr("actions.stop_timer") or tr("actions.start_timer"),
      glyph = tracked and "player-stop-filled" or "player-play-filled",
      variant = "ghost",
      enabled = not busy,
      onClick = "onTimerToggle",
    }))
  end
  table.insert(details, ui.row({ gap = 7, wrap = true }, primary_actions))

  table.insert(details, ui.label({ text = tr("snooze.title"), color = "on_surface_variant", fontSize = 10, fontWeight = "bold" }))
  table.insert(details, ui.row({ gap = 6, wrap = true }, {
    ui.button({ text = tr("snooze.hour"), variant = "ghost", controlSize = "sm", enabled = not busy, onClick = "onSnoozeHour" }),
    ui.button({ text = tr("snooze.tomorrow"), variant = "ghost", controlSize = "sm", enabled = not busy, onClick = "onSnoozeTomorrow" }),
    ui.button({ text = tr("snooze.week"), variant = "ghost", controlSize = "sm", enabled = not busy, onClick = "onSnoozeWeek" }),
  }))

  return ui.column({ gap = 10, padding = 13, radius = 10, fill = "surface_container", border = overdue and "error/0.35" or "outline/0.35", borderWidth = 1 }, details)
end

local function capture_card()
  local busy = action.status == "working" and action.type == "add"
  return ui.column({ gap = 7, padding = 11, radius = 9, fill = "surface_container_low" }, {
    ui.label({ text = tr("capture.title"), fontWeight = "bold" }),
    ui.label({ text = tr("capture.hint"), color = "on_surface_variant", fontSize = 10, maxLines = 3 }),
    ui.row({ gap = 7, align = "center" }, {
      ui.input({
        key = "capture-" .. tostring(input_revision),
        value = draft,
        placeholder = tr("capture.placeholder"),
        flexGrow = 1,
        enabled = not busy,
        onChange = "onCaptureChanged",
        onSubmit = "onCaptureSubmit",
      }),
      ui.button({ text = busy and tr("actions.adding") or tr("actions.add"), glyph = "plus", enabled = not busy and common.trim(draft) ~= "", onClick = "onCaptureAdd" }),
    }),
  })
end

local function diagnostics_card()
  if not show_diagnostics then return nil end
  local rows = {
    { tr("diagnostics.status"), tr("status." .. tostring(snapshot.status or "starting")) },
    { tr("diagnostics.companion"), snapshot.companionVersion ~= "" and snapshot.companionVersion or "—" },
    { tr("diagnostics.protocol"), tostring(snapshot.protocolVersion or "—") },
    { tr("diagnostics.package"), tr("package.status." .. tostring(snapshot.packageStatus or "missing")) },
    { tr("diagnostics.required_companion"), snapshot.requiredCompanionVersion ~= "" and snapshot.requiredCompanionVersion or "—" },
    { tr("diagnostics.tasks"), tostring(snapshot.counts and snapshot.counts.active or 0) },
    { tr("diagnostics.due"), tostring(snapshot.counts and snapshot.counts.due or 0) },
    { tr("diagnostics.overdue"), tostring(snapshot.counts and snapshot.counts.overdue or 0) },
    { tr("diagnostics.app"), snapshot.appRunning and tr("diagnostics.running") or tr("diagnostics.not_running") },
    { tr("diagnostics.launch_method"), snapshot.launchMethod ~= "" and snapshot.launchMethod or "—" },
  }
  local children = { ui.label({ text = tr("diagnostics.title"), fontWeight = "bold" }) }
  for _, row in ipairs(rows) do
    table.insert(children, ui.row({ gap = 8 }, {
      ui.label({ text = row[1], color = "on_surface_variant", fontSize = 11, width = 130 }),
      ui.label({ text = row[2], fontSize = 11, flexGrow = 1, maxLines = 2 }),
    }))
  end
  table.insert(children, ui.label({ text = tr("diagnostics.bridge_dir"), color = "on_surface_variant", fontSize = 10 }))
  table.insert(children, ui.label({ text = snapshot.bridgeDir or "—", fontSize = 10, maxLines = 3 }))
  table.insert(children, ui.label({ text = tr("diagnostics.package_path"), color = "on_surface_variant", fontSize = 10 }))
  table.insert(children, ui.label({ text = snapshot.packagePath or "—", fontSize = 10, maxLines = 3 }))
  table.insert(children, ui.row({ gap = 7, wrap = true }, package_controls()))
  if snapshot.packageError and snapshot.packageError ~= "" then
    table.insert(children, ui.label({ text = snapshot.packageError, color = "error", fontSize = 10, maxLines = 4 }))
  end
  if snapshot.lastError and snapshot.lastError ~= "" then
    table.insert(children, ui.label({ text = snapshot.lastError, color = "error", fontSize = 10, maxLines = 4 }))
  end
  table.insert(children, ui.row({ gap = 7 }, {
    ui.button({ text = tr("actions.copy_path"), glyph = "copy", variant = "ghost", controlSize = "sm", onClick = "onCopyBridgePath" }),
    ui.button({ text = tr("actions.settings"), glyph = "settings", variant = "ghost", controlSize = "sm", onClick = "onSettings" }),
  }))
  return ui.column({ gap = 6, padding = 11, radius = 9, border = "outline/0.35", borderWidth = 1 }, children)
end

render_panel = function()
  if not panel_open then return end
  local content = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "checks", color = "primary", size = 20 }),
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", tooltip = tr("actions.refresh"), variant = "ghost", onClick = "onRefresh" }),
      ui.button({ glyph = "activity", tooltip = tr("diagnostics.title"), variant = show_diagnostics and "primary" or "ghost", onClick = "onDiagnostics" }),
      ui.button({ glyph = "settings", tooltip = tr("actions.settings"), variant = "ghost", onClick = "onSettings" }),
      ui.button({ glyph = "close", tooltip = tr("actions.close"), variant = "ghost", onClick = "onClosePanel" }),
    }),
  }

  local banner = status_banner()
  if banner then table.insert(content, banner) end
  local undo = undo_card()
  if undo then table.insert(content, undo) end
  local result = action_banner()
  if result then table.insert(content, result) end

  local view = snapshot.view
  if type(view) == "table" and (view.count or 0) > 1 then
    table.insert(content, ui.row({ gap = 7, align = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", controlSize = "sm", onClick = "onPrevious" }),
      ui.label({ text = tr("task.position", { index = view.index or 1, count = view.count or 1 }), color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
      ui.button({ glyph = "chevron-right", variant = "ghost", controlSize = "sm", onClick = "onNext" }),
    }))
  end

  table.insert(content, task_card(view and view.task or nil))
  table.insert(content, capture_card())
  local diagnostics = diagnostics_card()
  if diagnostics then table.insert(content, diagnostics) end

  panel.render(ui.column({ gap = 10, padding = 13, flexGrow = 1 }, {
    content[1],
    ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 10 }, { table.unpack(content, 2) }) }),
  }))
end

noctalia.state.watch(common.SNAPSHOT_KEY, function(value)
  snapshot = type(value) == "table" and value or snapshot
  render_panel()
end)

noctalia.state.watch(common.ACTION_KEY, function(value)
  action = type(value) == "table" and value or action
  local is_submitted_capture = submitted_request_id ~= nil and action.requestId == submitted_request_id
  if is_submitted_capture and action.status == "success" and action.type == "add" then
    draft = ""
    submitted_request_id = nil
    input_revision += 1
  elseif is_submitted_capture and common.terminal_action(action) then
    submitted_request_id = nil
  end
  render_panel()
end)

function onOpen()
  panel_open = true
  render_panel()
end

function onClose()
  panel_open = false
end

function onClosePanel() panel.close() end
function onSettings() noctalia.openSettings() end
function onRefresh() common.send_intent("refresh") end
function onLaunch() common.send_intent("launch") end
function onDiagnostics()
  show_diagnostics = not show_diagnostics
  render_panel()
end
function onPrevious() common.send_intent("browse", { delta = -1 }) end
function onNext() common.send_intent("browse", { delta = 1 }) end

function onComplete()
  local task = snapshot.view and snapshot.view.task or nil
  if type(task) == "table" then common.send_intent("complete", { taskId = task.id }) end
end

function onOpenTask()
  local task = snapshot.view and snapshot.view.task or nil
  if type(task) == "table" then common.send_intent("open", { taskId = task.id }) end
end

function onTimerToggle()
  local task = snapshot.view and snapshot.view.task or nil
  if type(task) == "table" then common.send_intent("timer_toggle", { taskId = task.id }) end
end

local function snooze(mode)
  local task = snapshot.view and snapshot.view.task or nil
  if type(task) == "table" then common.send_intent("snooze", { taskId = task.id, mode = mode }) end
end

function onSnoozeHour() snooze("hour") end
function onSnoozeTomorrow() snooze("tomorrow") end
function onSnoozeWeek() snooze("week") end
function onUndo() common.send_intent("undo") end

function onCaptureChanged(value)
  draft = tostring(value or "")
  render_panel()
end

local function submit_capture(value)
  local text = common.trim(value ~= nil and value or draft)
  if text == "" or action.status == "working" then return end
  draft = text
  submitted_request_id = common.send_intent("add", { input = text, source = "panel" })
  render_panel()
end

function onCaptureSubmit(value) submit_capture(value) end
function onCaptureAdd() submit_capture(draft) end

function onCopyBridgePath()
  if snapshot.bridgeDir and snapshot.bridgeDir ~= "" then
    noctalia.copyToClipboard(snapshot.bridgeDir, "text/plain")
  end
end

function onBuildPackage() common.send_intent("package_build") end
function onOpenPackageDirectory() common.send_intent("package_open_directory") end
function onCopyPackagePath()
  if snapshot.packageStatus == "ready" and snapshot.packagePath and snapshot.packagePath ~= "" then
    noctalia.copyToClipboard(snapshot.packagePath, "text/plain")
  end
end

render_panel()
