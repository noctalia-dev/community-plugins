--!nonstrict
-- Bar widget for Habitica: pending dailies and todos, plus a rich tooltip.

local STATE_KEY = "habitica_snapshot"
local REV_KEY = "habitica_rev"
local COMMAND_KEY = "habitica_command"
local PANEL_ID = "vasqs/habitica:panel"

local snapshot = noctalia.state.get(STATE_KEY) or {
  configured = false,
  available = false,
  loading = true,
  error = "",
  displayName = "Habitica",
  level = 0,
  className = "",
  stats = {},
  dueDailiesCount = 0,
  openTodosCount = 0,
  pendingCount = 0,
  updatedAt = 0,
}

local function cfgString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
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

local function colorOr(role, fallback)
  if role == nil or role == "" or role == "none" then
    return fallback
  end
  return role
end

local function stats()
  return type(snapshot.stats) == "table" and snapshot.stats or {}
end

local function hpText()
  local hp = math.max(0, math.floor((tonumber(stats().hp) or 0) + 0.5))
  return noctalia.tr("widget.hp", { hp = hp })
end

local function xpText()
  local exp = math.floor(tonumber(stats().exp) or 0)
  local nextLevel = math.floor(tonumber(stats().toNextLevel) or 0)
  if nextLevel > 0 then
    return noctalia.tr("widget.xp", { exp = exp, next = nextLevel })
  end
  return noctalia.tr("widget.xp_total", { exp = exp })
end

local function goldText()
  return noctalia.tr("widget.gold", { gold = math.floor(tonumber(stats().gp) or 0) })
end

local function levelText()
  local level = tonumber(snapshot.level) or 0
  if level <= 0 then
    return noctalia.tr("widget.level_unknown")
  end
  return noctalia.tr("widget.level", { level = level })
end

local function updatedText()
  local updated = tonumber(snapshot.updatedAt) or 0
  if updated <= 0 then
    return ""
  end
  local seconds = math.max(0, os.time() - updated)
  local minutes = math.floor(seconds / 60)
  if minutes < 1 then
    return noctalia.tr("widget.updated_now")
  end
  if minutes < 60 then
    return noctalia.tr("widget.updated_mins", { n = minutes })
  end
  return noctalia.tr("widget.updated_hours", { n = math.floor(minutes / 60) })
end

local function tooltipText()
  if not snapshot.configured then
    return noctalia.tr("widget.configure")
  end
  if snapshot.available ~= true then
    local message = snapshot.error ~= "" and snapshot.error or "unknown error"
    return noctalia.tr("widget.error", { error = message })
  end
  if snapshot.loading == true and (tonumber(snapshot.pendingCount) or 0) == 0 then
    return noctalia.tr("widget.loading")
  end

  local name = snapshot.displayName ~= "" and snapshot.displayName or noctalia.tr("widget.player")
  local class = snapshot.className ~= "" and (" " .. snapshot.className) or ""
  local lines = {
    "Habitica - " .. name,
    levelText() .. class,
    hpText() .. " · " .. xpText() .. " · " .. goldText(),
    noctalia.tr("widget.summary", {
      dailies = tonumber(snapshot.dueDailiesCount) or 0,
      todos = tonumber(snapshot.openTodosCount) or 0,
    }),
  }
  local updated = updatedText()
  if updated ~= "" then
    table.insert(lines, updated)
  end
  table.insert(lines, "")
  table.insert(lines, noctalia.tr("widget.actions_hint"))
  return table.concat(lines, "\n")
end

local function render()
  local configured = snapshot.configured == true
  local available = snapshot.available == true
  local pending = math.max(0, tonumber(snapshot.pendingCount) or 0)
  local colorization = cfgBool("colorization_enabled", false)

  local iconColor = "on_surface"
  if not configured then
    iconColor = "on_surface_variant"
  elseif not available then
    iconColor = "error"
  elseif colorization then
    iconColor = colorOr(cfgString("colorization_icon", "primary"), "on_surface")
  end

  local children = {
    ui.glyph({ name = "sword", size = 16, color = iconColor }),
  }

  local showBadge = cfgBool("show_notification_badge", true)
  if configured and available and showBadge and pending > 0 then
    local badgeColor = colorization
      and colorOr(cfgString("colorization_badge", "error"), "error")
      or "error"
    local badgeTextColor = colorization
      and colorOr(cfgString("colorization_badge_text", "on_error"), "on_error")
      or "on_error"
    local count = pending > 99 and "99+" or tostring(pending)
    table.insert(children, ui.row({
      fill = badgeColor,
      radius = 8,
      paddingH = 5,
      align = "center",
      justify = "center",
    }, {
      ui.label({
        text = count,
        fontSize = 10,
        fontWeight = "bold",
        color = badgeTextColor,
      }),
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(tooltipText())
end

local function replaceSnapshot(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end

noctalia.state.watch(REV_KEY, function()
  replaceSnapshot(noctalia.state.get(STATE_KEY))
end)

noctalia.state.watch(STATE_KEY, replaceSnapshot)

noctalia.setUpdateInterval(30000)
render()

function update()
  render()
end

function onClick()
  if not snapshot.configured then
    noctalia.notify("Habitica", noctalia.tr("toast.configure"))
    return
  end
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.state.set(COMMAND_KEY, { action = "refresh" })
  noctalia.notify("Habitica", noctalia.tr("toast.refreshing"))
end
