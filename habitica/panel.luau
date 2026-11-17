--!nonstrict
-- Habitica panel: player stats, due dailies, open todos, optional habits and
-- checklist scoring. Every mutation is sent to the service over state.

local STATE_KEY = "habitica_snapshot"
local REV_KEY = "habitica_rev"
local COMMAND_KEY = "habitica_command"

local snapshot = noctalia.state.get(STATE_KEY) or {
  configured = false,
  available = false,
  loading = true,
  scoring = false,
  scoringTaskId = "",
  error = "",
  updatedAt = 0,
  displayName = "Habitica",
  level = 0,
  className = "",
  stats = {},
  dailies = {},
  todos = {},
  habits = {},
  tags = {},
  dueDailiesCount = 0,
  openTodosCount = 0,
  pendingCount = 0,
  avatarPath = "",
}

local opened = false
local requestCounter = 0
local tickAccum = 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function cfgBool(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "string" then
    return value == "true"
  end
  return fallback and true or false
end

local function cfgString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
end

local function send(action, values)
  requestCounter += 1
  local command = { action = action, requestId = "panel-" .. tostring(requestCounter) }
  if type(values) == "table" then
    for key, value in pairs(values) do
      command[key] = value
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
end

local function stats()
  return type(snapshot.stats) == "table" and snapshot.stats or {}
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function ratio(value, maximum)
  local maxValue = tonumber(maximum) or 0
  if maxValue <= 0 then
    return 0
  end
  return clamp((tonumber(value) or 0) / maxValue, 0, 1)
end

local function hpRatio()
  return ratio(stats().hp, stats().maxHealth or 50)
end

local function xpRatio()
  return ratio(stats().exp, stats().toNextLevel or 1)
end

local function mpRatio()
  return ratio(stats().mp, stats().maxMP or 1)
end

local function hpValue()
  return tr("widget.hp", { hp = math.max(0, math.floor((tonumber(stats().hp) or 0) + 0.5)) })
end

local function xpValue()
  local exp = math.floor(tonumber(stats().exp) or 0)
  local nextLevel = math.floor(tonumber(stats().toNextLevel) or 0)
  if nextLevel > 0 then
    return tr("widget.xp", { exp = exp, next = nextLevel })
  end
  return tr("widget.xp_total", { exp = exp })
end

local function mpValue()
  if stats().mp == nil then
    return "-- MP"
  end
  return tostring(math.max(0, math.floor((tonumber(stats().mp) or 0) + 0.5))) .. " MP"
end

local function levelValue()
  local level = tonumber(snapshot.level) or 0
  if level <= 0 then
    return tr("widget.level_unknown")
  end
  return tr("widget.level", { level = level })
end

local function goldValue()
  return tostring(math.floor(tonumber(stats().gp) or 0))
end

local function updatedValue()
  local updated = tonumber(snapshot.updatedAt) or 0
  if updated <= 0 then
    return ""
  end
  local seconds = math.max(0, os.time() - updated)
  local minutes = math.floor(seconds / 60)
  if minutes < 1 then
    return tr("widget.updated_now")
  end
  if minutes < 60 then
    return tr("widget.updated_mins", { n = minutes })
  end
  return tr("widget.updated_hours", { n = math.floor(minutes / 60) })
end

local function toneColor(task)
  if task.type == "todo" then
    return "tertiary"
  end
  local value = tonumber(task.value) or 0
  if value < -10 then
    return "error"
  end
  if value < -1 then
    return "tertiary"
  end
  if value < 1 then
    return "secondary"
  end
  return "primary"
end

local function toneLabel(task)
  local value = tonumber(task.value) or 0
  if value < -10 then
    return tr("task.tone_high_risk")
  end
  if value < -1 then
    return tr("task.tone_weak")
  end
  if value < 1 then
    return tr("task.tone_neutral")
  end
  if value < 5 then
    return tr("task.tone_steady")
  end
  return tr("task.tone_strong")
end

local function taskSummary(task)
  local parts = {}
  if (tonumber(task.priority) or 0) > 0 then
    table.insert(parts, tr("task.difficulty", { n = task.priority }))
  end
  if (tonumber(task.streak) or 0) ~= 0 then
    table.insert(parts, tr("task.streak", { n = math.floor(task.streak) }))
  end
  if task.value ~= nil then
    table.insert(parts, tr("task.value", { n = math.floor((tonumber(task.value) or 0) * 10 + 0.5) / 10 }))
  end
  return table.concat(parts, " · ")
end

local function tagName()
  local wanted = cfgString("selected_tag_id", "")
  if wanted == "" then
    return ""
  end
  for _, tag in ipairs(snapshot.tags or {}) do
    if tostring(tag.id) == wanted then
      return tostring(tag.name or "")
    end
  end
  return ""
end

local function scoring()
  return snapshot.scoring == true
end

local function statBar(label, value, progress, fill)
  return ui.column({ gap = 3, flexGrow = 1, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = value, fontSize = 11, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    }),
    ui.progress({
      progress = progress,
      height = 6,
      radius = 3,
      fill = fill,
      track = "surface_container_high",
    }),
  })
end

local function checklistRows(task)
  if not cfgBool("show_checklist_items", false) then
    return nil
  end
  if task.type == "habit" then
    return nil
  end
  local items = task.checklist or {}
  if #items == 0 then
    return nil
  end
  local rows = {}
  for _, item in ipairs(items) do
    table.insert(rows, ui.row({
      key = "check-" .. tostring(task.id) .. "-" .. tostring(item.id),
      gap = 6,
      align = "center",
    }, {
      ui.button({
        glyph = item.completed and "checkbox" or "square",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.toggle_checklist"),
        enabled = not scoring(),
        onClick = function()
          send("score_checklist", { taskId = task.id, itemId = item.id })
        end,
      }),
      ui.label({
        text = item.text ~= "" and item.text or tr("panel.untitled"),
        fontSize = 11,
        flexGrow = 1,
        maxLines = 1,
        color = item.completed and "on_surface_variant" or "on_surface",
      }),
    }))
  end
  return ui.column({ gap = 3, align = "stretch" }, rows)
end

local function taskCard(task, kind)
  local tone = toneColor(task)
  local controls = {}

  if kind == "habit" then
    table.insert(controls, ui.button({
      glyph = "plus",
      variant = "outline",
      controlSize = "sm",
      tooltip = task.up ~= false and tr("panel.score_up") or tr("panel.score_up_disabled"),
      enabled = task.up ~= false and not scoring(),
      onClick = function()
        send("score_task", { taskId = task.id, direction = "up" })
      end,
    }))
    table.insert(controls, ui.button({
      glyph = "minus",
      variant = "outline",
      controlSize = "sm",
      tooltip = task.down ~= false and tr("panel.score_down") or tr("panel.score_down_disabled"),
      enabled = task.down ~= false and not scoring(),
      onClick = function()
        send("score_task", { taskId = task.id, direction = "down" })
      end,
    }))
  else
    table.insert(controls, ui.button({
      glyph = task.completed and "check" or "check",
      variant = "primary",
      controlSize = "sm",
      tooltip = tr("panel.complete"),
      enabled = not scoring(),
      onClick = function()
        send("score_task", { taskId = task.id, direction = "up" })
      end,
    }))
  end

  local summary = taskSummary(task)
  local detail = summary ~= "" and summary or task.notes
  local body = {
    ui.label({
      text = task.text ~= "" and task.text or tr("panel.untitled"),
      fontSize = 12,
      fontWeight = "medium",
      maxLines = 3,
      flexGrow = 1,
    }),
  }
  if detail ~= nil and detail ~= "" then
    table.insert(body, ui.label({
      text = detail,
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    }))
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.row({ gap = 3, align = "center" }, controls),
      ui.column({ gap = 2, flexGrow = 1, align = "stretch" }, body),
      ui.row({
        fill = tone .. "/0.14",
        radius = 9,
        paddingH = 6,
        align = "center",
        justify = "center",
      }, {
        ui.label({ text = toneLabel(task), fontSize = 9, color = tone }),
      }),
    }),
  }

  local checks = checklistRows(task)
  if checks ~= nil then
    table.insert(children, checks)
  end

  return ui.column({
    key = "task-" .. tostring(task.id),
    gap = 6,
    padding = 8,
    radius = 8,
    align = "stretch",
    fill = "surface_container_low",
    border = tone .. "/0.28",
    borderWidth = 1,
  }, children)
end

local function sectionHeader(title, count)
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = title, fontSize = 12, fontWeight = "bold", color = "secondary", flexGrow = 1 }),
    ui.row({
      fill = "secondary/0.14",
      radius = 8,
      paddingH = 6,
      align = "center",
      justify = "center",
    }, {
      ui.label({ text = tostring(count), fontSize = 10, fontWeight = "bold", color = "secondary" }),
    }),
  })
end

local function section(title, tasks, kind, emptyText)
  local rows = {}
  for _, task in ipairs(tasks or {}) do
    table.insert(rows, taskCard(task, kind))
  end
  local children = { sectionHeader(title, #(tasks or {})) }
  if #rows == 0 then
    table.insert(children, ui.column({
      fill = "surface_container_low",
      radius = 8,
      padding = 10,
      align = "stretch",
    }, {
      ui.label({ text = emptyText, color = "on_surface_variant", fontSize = 11 }),
    }))
  else
    table.insert(children, ui.column({ gap = 6, align = "stretch" }, rows))
  end
  return ui.column({ gap = 6, align = "stretch" }, children)
end

local function avatar()
  if snapshot.avatarPath ~= "" then
    return ui.image({
      path = snapshot.avatarPath,
      width = 96,
      height = 100,
      fit = "contain",
      radius = 10,
      border = "primary",
      borderWidth = 1,
    })
  end
  return ui.column({
    width = 96,
    height = 100,
    fill = "surface_container",
    radius = 10,
    border = "primary/0.4",
    borderWidth = 1,
    align = "center",
    justify = "center",
    gap = 4,
  }, {
    ui.glyph({ name = "sword", size = 34, color = "primary" }),
    ui.label({ text = "Habitica", fontSize = 10, color = "on_surface_variant" }),
  })
end

local function header()
  local class = snapshot.className ~= "" and (" " .. snapshot.className) or ""
  local right = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = snapshot.displayName ~= "" and snapshot.displayName or tr("widget.player"),
        fontSize = 18,
        fontWeight = "bold",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.refresh"),
        enabled = not snapshot.loading and not scoring(),
        onClick = function()
          send("refresh")
          noctalia.notify("Habitica", tr("toast.refreshing"))
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.close"),
        onClick = function()
          panel.close()
        end,
      }),
    }),
    statBar(tr("panel.health"), hpValue(), hpRatio(), "error"),
    statBar(tr("panel.experience"), xpValue(), xpRatio(), "primary"),
  }

  if stats().mp ~= nil then
    table.insert(right, statBar(tr("panel.mana"), mpValue(), mpRatio(), "secondary"))
  end

  table.insert(right, ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = "coin", size = 13, color = "tertiary" }),
    ui.label({ text = goldValue(), fontSize = 11, fontWeight = "bold", color = "tertiary" }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ text = updatedValue(), fontSize = 10, color = "on_surface_variant" }),
  }))

  local tag = tagName()
  if cfgBool("enable_tag_filter", false) and cfgString("selected_tag_id", "") ~= "" then
    table.insert(right, ui.label({
      text = tr("panel.tag_filtered", { tag = tag ~= "" and tag or tr("panel.unknown_tag") }),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end

  return ui.row({ gap = 14, align = "center" }, {
    ui.column({ gap = 6, width = 96, align = "stretch" }, {
      avatar(),
      ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = "sword", size = 12, color = "primary" }),
        ui.label({
          text = levelValue() .. class,
          fontSize = 10,
          fontWeight = "bold",
          maxLines = 1,
          flexGrow = 1,
        }),
      }),
    }),
    ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, right),
  })
end

local function errorBanner()
  if snapshot.error == nil or snapshot.error == "" then
    return nil
  end
  return ui.column({
    fill = "error_container",
    radius = 8,
    padding = 8,
    align = "stretch",
  }, {
    ui.label({ text = snapshot.error, fontSize = 11, color = "on_error_container", maxLines = 3 }),
  })
end

local function notConfigured()
  return ui.column({
    gap = 8,
    padding = 20,
    radius = 10,
    fill = "surface_container_low",
    align = "center",
    justify = "center",
    flexGrow = 1,
  }, {
    ui.glyph({ name = "user-circle", size = 38, color = "on_surface_variant" }),
    ui.label({ text = tr("panel.credentials_required"), fontSize = 15, fontWeight = "bold" }),
    ui.label({
      text = tr("panel.credentials_description"),
      fontSize = 11,
      color = "on_surface_variant",
      textAlign = "center",
      maxLines = 4,
    }),
    ui.button({
      text = tr("panel.open_settings"),
      glyph = "settings",
      variant = "primary",
      onClick = function()
        noctalia.openSettings()
      end,
    }),
  })
end

local function loadingState()
  return ui.column({
    gap = 8,
    padding = 24,
    flexGrow = 1,
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = "loader", size = 34, color = "on_surface_variant" }),
    ui.label({ text = tr("panel.loading"), fontSize = 13, fontWeight = "bold" }),
    ui.label({
      text = tr("panel.loading_description"),
      fontSize = 11,
      color = "on_surface_variant",
      textAlign = "center",
    }),
  })
end

local function body()
  if not snapshot.configured then
    return notConfigured()
  end
  if snapshot.loading == true
    and #(snapshot.dailies or {}) == 0
    and #(snapshot.todos or {}) == 0 then
    return loadingState()
  end

  local children = {}
  local banner = errorBanner()
  if banner ~= nil then
    table.insert(children, banner)
  end
  table.insert(children, section(tr("panel.today"), snapshot.dailies or {}, "daily", tr("panel.no_dailies")))
  table.insert(children, section(tr("panel.todos"), snapshot.todos or {}, "todo", tr("panel.no_todos")))
  if cfgBool("show_habits", false) then
    table.insert(children, section(tr("panel.habits"), snapshot.habits or {}, "habit", tr("panel.no_habits")))
  end
  return ui.scroll({ flexGrow = 1, gap = 14, align = "stretch" }, children)
end

local function render()
  if not opened then
    return
  end
  panel.render(ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
    header(),
    body(),
  }))
end

local function replaceSnapshot(value)
  if type(value) ~= "table" then
    return
  end
  snapshot = value
  if opened then
    render()
  end
end

noctalia.state.watch(REV_KEY, function()
  replaceSnapshot(noctalia.state.get(STATE_KEY))
end)

noctalia.state.watch(STATE_KEY, replaceSnapshot)

function onOpen(_context)
  opened = true
  snapshot = noctalia.state.get(STATE_KEY) or snapshot
  tickAccum = 0
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  opened = false
  panel.setWantsSecondTicks(false)
end

function onFrameTick(deltaMs)
  if not opened then
    return
  end
  tickAccum += tonumber(deltaMs) or 0
  if tickAccum >= 30000 then
    tickAccum = 0
    render()
  end
end
