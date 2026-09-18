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
local ACTION_NOTICE_HOLD_MS = 3000
local ACTION_NOTICE_FADE_MS = 300

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local CONNECTION_STATUS_KEYS = {
  auth_required = true,
  checking = true,
  companion_missing = true,
  degraded = true,
  error = true,
  loading = true,
  missing = true,
  offline = true,
  outdated = true,
  protocol_mismatch = true,
  ready = true,
  stale = true,
  starting = true,
  timeout = true,
  waiting = true,
  unavailable = true,
  unauthorized = true,
  unknown = true,
}

local OVERALL_STATUS_KEYS = {
  auth_required = true,
  error = true,
  ready = true,
  stale = true,
  unavailable = true,
}

local function connection_status_text(value)
  local status = tostring(value or "unknown")
  if CONNECTION_STATUS_KEYS[status] then return tr("connection_status." .. status) end
  return status
end

local function overall_status_text(value)
  local status = tostring(value or "starting")
  if status == "offline" then return tr("status.rest_offline") end
  if status == "starting" then return tr("status.rest_loading") end
  if OVERALL_STATUS_KEYS[status] then return tr("status." .. status) end
  return status
end

local function nonempty_text(value)
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

local function displayed_task()
  if snapshot.status ~= "ready" then return nil end
  return snapshot.view and snapshot.view.task or nil
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
  return ui.row({ gap = 8 }, children)
end

-- rows do not wrap in the Noctalia plugin UI, so bound each row to two buttons.
local function button_grid(buttons, gap)
  local spacing = gap or 7
  local rows = {}
  local row = {}
  for _, button in ipairs(buttons) do
    button.props.flexGrow = 1
    table.insert(row, button)
    if #row == 2 then
      table.insert(rows, ui.row({ gap = spacing }, row))
      row = {}
    end
  end
  if #row > 0 then table.insert(rows, ui.row({ gap = spacing }, row)) end
  return ui.column({ gap = spacing }, rows)
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
      ui.button({ text = tr("actions.rebuild_package"), glyph = "refresh", variant = "outline", controlSize = "sm", onClick = "onBuildPackage" }),
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

local function notice_banner(key, guidance, color, controls)
  local children = {
    ui.row({ gap = 7, align = "center" }, {
      ui.glyph({ name = "alert-triangle", color = color, size = 16 }),
      ui.label({ text = tr(key), color = color, fontWeight = "bold", flexGrow = 1 }),
    }),
    ui.label({ text = guidance, color = "on_surface_variant", fontSize = 11, maxLines = 4 }),
  }
  if controls ~= nil then table.insert(children, controls) end
  return ui.column({ gap = 7, padding = 10, radius = 9, fill = color .. "/0.08", border = color .. "/0.25", borderWidth = 1 }, children)
end

local function rest_status_banner()
  local overall_status = tostring(snapshot.status or "starting")
  local rest_status = tostring(snapshot.restStatus or overall_status)
  local rest_error = type(snapshot.restError) == "string" and snapshot.restError or ""
  local failed = rest_status == "auth_required" or rest_status == "unauthorized"
    or rest_status == "offline" or rest_status == "unavailable"
    or rest_status == "error" or rest_status == "stale" or rest_status == "timeout"
  if overall_status == "ready" and not failed and rest_error == "" then return nil end

  local key = "status.rest_unavailable"
  local guidance = tr("status.rest_unavailable_hint")
  local color = "error"
  if rest_status == "auth_required" or rest_status == "unauthorized" or overall_status == "auth_required" then
    key = "status.rest_auth_required"
    guidance = tr("status.rest_auth_required_hint")
  elseif rest_status == "starting" or rest_status == "checking" or rest_status == "loading"
    or overall_status == "starting" then
    key = "status.rest_starting"
    guidance = tr("status.rest_starting_hint")
    color = "tertiary"
  elseif rest_status == "stale" or overall_status == "stale" then
    key = "status.rest_stale"
    guidance = tr("status.rest_stale_hint")
  elseif rest_status == "error" or overall_status == "error" then
    key = "status.rest_error"
    guidance = tr("status.rest_error_hint")
  end
  if rest_error ~= "" then guidance = rest_error end
  return notice_banner(key, guidance, color, ui.row({ gap = 7 }, {
    ui.button({ text = tr("actions.launch"), glyph = "external-link", variant = "outline", controlSize = "sm", onClick = "onLaunch" }),
    ui.button({ text = tr("actions.refresh"), glyph = "refresh", variant = "ghost", controlSize = "sm", onClick = "onRefresh" }),
  }))
end

local function bridge_status_banner()
  local bridge_status = tostring(snapshot.bridgeStatus or "unknown")
  local bridge_error = type(snapshot.bridgeError) == "string" and snapshot.bridgeError or ""
  local hook_status = tostring(snapshot.hookStatus or "unknown")
  local hook_error = type(snapshot.hookError) == "string" and snapshot.hookError or ""
  local hook_failed = hook_status == "error" or hook_status == "protocol_mismatch" or hook_error ~= ""
  if bridge_status == "ready" and snapshot.companionUpdateRequired ~= true
    and bridge_error == "" and not hook_failed then return nil end
  if bridge_status == "unknown" and snapshot.bridgeStatus == nil
    and hook_status == "unknown" and snapshot.hookStatus == nil then return nil end

  local key = "status.bridge_unavailable"
  local guidance = tr("status.bridge_unavailable_hint")
  if bridge_status == "ready" and hook_failed then
    key = hook_status == "protocol_mismatch" and "status.hook_protocol_mismatch" or "status.hook_error"
    guidance = hook_status == "protocol_mismatch" and tr("status.hook_protocol_mismatch_hint")
      or tr("status.hook_error_hint")
  elseif snapshot.companionUpdateRequired == true or bridge_status == "outdated" then
    key = "status.companion_outdated"
    guidance = tr("status.companion_outdated_hint")
  elseif bridge_status == "starting" or bridge_status == "checking" or bridge_status == "loading" then
    key = "status.bridge_starting"
    guidance = tr("status.bridge_starting_hint")
  elseif bridge_status == "stale" or bridge_status == "degraded" then
    key = "status.bridge_stale"
    guidance = tr("status.bridge_stale_hint")
  elseif bridge_status == "protocol_mismatch" then
    key = "status.bridge_protocol_mismatch"
    guidance = tr("status.bridge_protocol_mismatch_hint")
  elseif bridge_status == "error" then
    key = "status.bridge_error"
    guidance = tr("status.bridge_error_hint")
  end
  if bridge_error ~= "" then guidance = bridge_error end
  if bridge_status == "ready" and hook_error ~= "" then guidance = hook_error end
  if bridge_status ~= "ready" and snapshot.packageStatus == "error"
    and type(snapshot.packageError) == "string" and snapshot.packageError ~= "" then
    guidance = snapshot.packageError
  end

  local controls = package_controls()
  table.insert(controls, ui.button({ text = tr("actions.launch"), glyph = "external-link", variant = "outline", controlSize = "sm", onClick = "onLaunch" }))
  table.insert(controls, ui.button({ text = tr("actions.refresh"), glyph = "refresh", variant = "outline", controlSize = "sm", onClick = "onRefresh" }))
  return notice_banner(key, guidance, "tertiary", button_grid(controls))
end

local function action_notice_opacity()
  if action.status ~= "success" then return nil end
  local completed_at = tonumber(action.completedAt)
  if completed_at == nil then return 1 end
  local remaining = completed_at + ACTION_NOTICE_HOLD_MS + ACTION_NOTICE_FADE_MS - noctalia.nowMs()
  if remaining <= 0 then return 0 end
  return math.min(1, remaining / ACTION_NOTICE_FADE_MS)
end

local function sync_action_notice_animation()
  if not panel.setNeedsFrameTick then return end
  local opacity = action_notice_opacity()
  panel.setNeedsFrameTick(panel_open and opacity ~= nil and opacity > 0)
end

local function action_banner()
  if action.status == "idle" or action.status == "working" then return nil end
  local opacity = action_notice_opacity()
  if opacity ~= nil and opacity <= 0 then return nil end
  local color = action.status == "success" and "primary"
    or action.status == "unknown" and "tertiary" or "error"
  local text
  if action.status == "success" then
    text = tr("action.success." .. tostring(action.type or "default"))
  elseif action.status == "unknown" then
    text = tr("error.rest_outcome_unknown")
  else
    text = action.error or tr("error.command_failed")
  end
  return ui.label({ text = text, color = color, fontSize = 11, maxLines = 3, opacity = opacity or 1 })
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
    local unavailable = snapshot.status ~= "ready"
    local rest_error = type(snapshot.restError) == "string" and snapshot.restError or ""
    local hint = unavailable and (rest_error ~= "" and rest_error or tr("task.unavailable_hint"))
      or tr("task.none_due_hint")
    return ui.column({ gap = 8, padding = 18, align = "center", radius = 10, fill = "surface_variant/0.45" }, {
      ui.glyph({ name = unavailable and "alert-triangle" or "circle-check", size = 28, color = unavailable and "error" or "primary" }),
      ui.label({ text = unavailable and tr("task.unavailable") or tr("task.none_due"), fontWeight = "bold" }),
      ui.label({ text = hint, color = "on_surface_variant", fontSize = 11, maxLines = 4 }),
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
    table.insert(details, ui.label({ text = task.notes, maxWidth = 420 }))
  end

  table.insert(details, ui.separator({}))
  local primary_actions = {
    ui.button({
      text = busy and tr("actions.working") or tr("actions.complete"),
      glyph = "check",
      variant = "primary",
      flexGrow = 1.2,
      enabled = not busy,
      onClick = "onComplete",
    }),
    ui.button({
      text = tr("actions.open"),
      glyph = "external-link",
      variant = "outline",
      flexGrow = 1.5,
      enabled = not busy,
      onClick = "onOpenTask",
    }),
  }
  if noctalia.getConfig("show_timer_controls") ~= false then
    table.insert(primary_actions, ui.button({
      text = tracked and tr("actions.stop_timer") or tr("actions.start_timer"),
      glyph = tracked and "player-stop-filled" or "player-play-filled",
      variant = "outline",
      flexGrow = 1.3,
      enabled = not busy,
      onClick = "onTimerToggle",
    }))
  end
  table.insert(details, ui.row({ gap = 7 }, primary_actions))

  table.insert(details, ui.label({ text = tr("snooze.title"), color = "on_surface_variant", fontSize = 10, fontWeight = "bold" }))
  table.insert(details, ui.row({ gap = 6 }, {
    ui.button({ text = tr("snooze.hour"), variant = "ghost", controlSize = "sm", enabled = not busy, onClick = "onSnoozeHour" }),
    ui.button({ text = tr("snooze.tomorrow"), variant = "ghost", controlSize = "sm", enabled = not busy, onClick = "onSnoozeTomorrow" }),
    ui.button({ text = tr("snooze.week"), variant = "ghost", controlSize = "sm", enabled = not busy, onClick = "onSnoozeWeek" }),
  }))

  return ui.column({ gap = 10, padding = 13, radius = 10, fill = "surface_variant/0.45", border = overdue and "error/0.35" or "outline/0.35", borderWidth = 1 }, details)
end

local function capture_card()
  local busy = action.status == "working"
  local adding = busy and action.type == "add"
  return ui.column({ gap = 7, padding = 11, radius = 9, fill = "surface_variant/0.25" }, {
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
      ui.button({ text = adding and tr("actions.adding") or tr("actions.add"), glyph = "plus", enabled = not busy and common.trim(draft) ~= "", onClick = "onCaptureAdd" }),
    }),
  })
end

local function diagnostics_card()
  if not show_diagnostics then return nil end
  local rest_error = nonempty_text(snapshot.restError)
  local bridge_error = nonempty_text(snapshot.bridgeError)
  local hook_error = nonempty_text(snapshot.hookError)
  local package_error = nonempty_text(snapshot.packageError)
  local groups = {
    {
      { label = tr("diagnostics.status"), value = overall_status_text(snapshot.status) },
      { label = tr("diagnostics.tasks"), value = tostring(snapshot.counts and snapshot.counts.active or 0) },
      { label = tr("diagnostics.due"), value = tostring(snapshot.counts and snapshot.counts.due or 0) },
      { label = tr("diagnostics.overdue"), value = tostring(snapshot.counts and snapshot.counts.overdue or 0) },
    },
    {
      { label = tr("diagnostics.app"), value = snapshot.appRunning and tr("diagnostics.running") or tr("diagnostics.not_running") },
      { label = tr("diagnostics.launch_method"), value = nonempty_text(snapshot.launchMethod) or "—" },
    },
    {
      { label = tr("diagnostics.rest_status"), value = connection_status_text(snapshot.restStatus) },
      { label = tr("diagnostics.rest_error"), value = rest_error or "—" },
    },
    {
      { label = tr("diagnostics.bridge_status"), value = connection_status_text(snapshot.bridgeStatus) },
      { label = tr("diagnostics.bridge_error"), value = bridge_error or "—" },
      { label = tr("diagnostics.bridge_dir"), value = nonempty_text(snapshot.bridgeDir) or "—", stacked = true },
      { label = tr("diagnostics.hook_status"), value = connection_status_text(snapshot.hookStatus) },
      { label = tr("diagnostics.hook_error"), value = hook_error or "—" },
    },
    {
      { label = tr("diagnostics.package"), value = tr("package.status." .. tostring(snapshot.packageStatus or "missing")) },
      { label = tr("diagnostics.package_error"), value = package_error or "—", color = package_error and "error" or nil },
      { label = tr("diagnostics.package_path"), value = nonempty_text(snapshot.packagePath) or "—", stacked = true },
      { label = tr("diagnostics.companion"), value = nonempty_text(snapshot.companionVersion) or "—" },
      { label = tr("diagnostics.required_companion"), value = nonempty_text(snapshot.requiredCompanionVersion) or "—" },
      { label = tr("diagnostics.protocol"), value = tostring(snapshot.protocolVersion or "—") },
    },
  }
  local last_error = nonempty_text(snapshot.lastError)
  if last_error ~= nil and last_error ~= rest_error and last_error ~= bridge_error
    and last_error ~= hook_error and last_error ~= package_error then
    table.insert(groups, {
      { label = tr("diagnostics.last_error"), value = last_error, color = "error" },
    })
  end

  local children = { ui.label({ text = tr("diagnostics.title"), fontWeight = "bold" }) }
  for group_index, group in ipairs(groups) do
    if group_index > 1 then table.insert(children, ui.separator({})) end
    for _, row in ipairs(group) do
      if row.stacked then
        table.insert(children, ui.label({ text = row.label, color = "on_surface_variant", fontSize = 10 }))
        table.insert(children, ui.label({ text = row.value, color = row.color, fontSize = 10, maxLines = 3 }))
      else
        table.insert(children, ui.row({ gap = 8 }, {
          ui.label({ text = row.label, color = "on_surface_variant", fontSize = 11, width = 130 }),
          ui.label({ text = row.value, color = row.color, fontSize = 11, flexGrow = 1, maxLines = 3 }),
        }))
      end
    end
  end
  table.insert(children, button_grid(package_controls()))
  table.insert(children, button_grid({
    ui.button({ text = tr("actions.copy_path"), glyph = "copy", variant = "outline", controlSize = "sm", onClick = "onCopyBridgePath" }),
    ui.button({ text = tr("actions.settings"), glyph = "settings", variant = "outline", controlSize = "sm", onClick = "onSettings" }),
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

  local rest_banner = rest_status_banner()
  if rest_banner then table.insert(content, rest_banner) end
  local bridge_banner = bridge_status_banner()
  if bridge_banner then table.insert(content, bridge_banner) end
  local undo = undo_card()
  if undo then table.insert(content, undo) end
  local result = action_banner()
  if result then table.insert(content, result) end

  local view = snapshot.status == "ready" and snapshot.view or nil
  if type(view) == "table" and (view.count or 0) > 1 then
    table.insert(content, ui.row({ gap = 7, align = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", controlSize = "sm", onClick = "onPrevious" }),
      ui.label({ text = tr("task.position", { index = view.index or 1, count = view.count or 1 }), color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
      ui.button({ glyph = "chevron-right", variant = "ghost", controlSize = "sm", onClick = "onNext" }),
    }))
  end

  table.insert(content, task_card(displayed_task()))
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
  elseif submitted_request_id ~= nil and action.rejectedRequestId == submitted_request_id then
    submitted_request_id = nil
  elseif is_submitted_capture and common.terminal_action(action) then
    submitted_request_id = nil
  end
  sync_action_notice_animation()
  render_panel()
end)

function onOpen()
  panel_open = true
  sync_action_notice_animation()
  render_panel()
end

function onClose()
  panel_open = false
  sync_action_notice_animation()
end

function onFrameTick()
  local opacity = action_notice_opacity()
  if opacity == nil then
    sync_action_notice_animation()
    return
  end
  if opacity < 1 then render_panel() end
  if opacity <= 0 then sync_action_notice_animation() end
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
  local task = displayed_task()
  if type(task) == "table" then common.send_intent("complete", { taskId = task.id }) end
end

function onOpenTask()
  local task = displayed_task()
  if type(task) == "table" then common.send_intent("open", { taskId = task.id }) end
end

function onTimerToggle()
  local task = displayed_task()
  if type(task) == "table" then common.send_intent("timer_toggle", { taskId = task.id }) end
end

local function snooze(mode)
  local task = displayed_task()
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
  common.send_intent("add", { input = text, source = "panel" }, function(request_id)
    submitted_request_id = request_id
  end)
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
