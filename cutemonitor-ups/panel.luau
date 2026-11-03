--!nonstrict
-- Detail panel: header, big numbers, a live graph with a hover readout, the
-- full readout, the protection policy, the event log and actions. Each
-- section has a switch in the plugin's settings. Opens from the bar item.

local shared = require("./shared.luau")

local KEYS = shared.KEYS
local W = 352 -- 380 px panel minus Noctalia's 14 px panel padding on each side
local H = 572 -- 600 px panel minus the same padding
local CARD_PAD = 12
-- Nothing inside the scroll area gets a fixed width, because the scrollbar
-- takes 14 px once the content overflows. The big-number cells are the
-- exception, sized for that narrower case.
local SCROLLBAR_GUTTER = 14
local HERO_CELL = math.floor((W - SCROLLBAR_GUTTER - CARD_PAD * 2) / 3)
local BODY = 14
local CAPTION = 13
local SMALL = 12
local HERO = 26
local DIM = 0.45
local PENDING_TIMEOUT_SEC = 15 -- the service answers within its 4 s command timeout
local COLORS = { warning = "tertiary", alert = "error" }
local SPANS = { "2m", "10m", "1h" }

local EVENT_COLORS = {
  power_failure = "tertiary",
  blackout = "tertiary",
  over_voltage = "tertiary",
  under_voltage = "tertiary",
  boost_on = "tertiary",
  buck_on = "tertiary",
  comm_lost = "tertiary",
  power_restored = "secondary",
  comm_restored = "secondary",
  test_passed = "secondary",
  low_battery = "error",
  overload = "error",
  fault = "error",
  replace_battery = "error",
  test_failed = "error",
  test_low_battery = "error",
}

local show = {
  hero = noctalia.getConfig("panel_hero") ~= false,
  graph = noctalia.getConfig("panel_graph") ~= false,
  readout = noctalia.getConfig("panel_readout") ~= false,
  protection = noctalia.getConfig("panel_protection") == true,
  events = noctalia.getConfig("panel_events") == true,
  actions = noctalia.getConfig("panel_actions") ~= false,
}
local highLoad = tonumber(noctalia.getConfig("high_load")) or 80
local dateStyle = noctalia.getConfig("date_style") or "short"

local snap = noctalia.state.get(KEYS.snapshot)
local link = noctalia.state.get(KEYS.link)
local events = noctalia.state.get(KEYS.events) or {}
local test = noctalia.state.get(KEYS.test)
local policy = noctalia.state.get(KEYS.policy)
local series = {}
for _, span in SPANS do
  series[span] = noctalia.state.get(shared.seriesKey(span))
end

local isOpen = false
local span = "2m"
local hoverIndex = nil
local confirmingTest = false
local pendingId = nil
local pendingSince = 0
local reply = nil
-- Event rows are rebuilt only when the log changes, or once a minute when
-- dates are relative; the log can hold 200 entries.
local eventRows = nil
local eventRowsMinute = -1

-- Builders

local function label(text: string, size: number, color: string, extra)
  local props = { text = text, fontSize = size, color = color }
  if extra then
    for key, value in extra do
      props[key] = value
    end
  end
  return ui.label(props)
end

local function card(title: string?, children, right, opacity: number?)
  local content = {}
  if title ~= nil then
    local head = { label(title, BODY, "on_surface", { fontWeight = "medium" }) }
    if right ~= nil then
      table.insert(head, right)
    end
    table.insert(content, ui.row({ align = "center", justify = "space_between" }, head))
  end
  for _, child in children do
    table.insert(content, child)
  end
  return ui.column({
    gap = 8,
    padding = CARD_PAD,
    radius = 12,
    fill = "surface_container/0.45",
    opacity = opacity,
  }, content)
end

local function keyValue(key: string, value: string, color: string?)
  return ui.row({ gap = 12, align = "start" }, {
    label(key, CAPTION, "on_surface_variant"),
    label(value, CAPTION, color or "on_surface", { flexGrow = 1, textAlign = "end", maxLines = 2, fontWeight = "medium" }),
  })
end

local function statColor(statKey: string, base: string): string
  return shared.statColor(statKey, snap, base, COLORS, highLoad)
end

-- Header

local function sourceName(): string
  if link == nil or link.source == nil then
    return ""
  elseif link.source == "pwrstat" then
    return "pwrstat"
  end
  return if link.ups then `NUT · {link.ups}` else "NUT"
end

local function header(level: string, now: number)
  local title = if snap and snap.model then snap.model else noctalia.tr("panel.title")
  local subtitle = ""
  if link and link.lastOkAt then
    local age = now - link.lastOkAt
    subtitle = if age < 2
      then noctalia.tr("panel.updated_now", { source = sourceName() })
      else noctalia.tr("panel.updated", { source = sourceName(), age = shared.formatRuntime(age) })
  end

  local stateColor = shared.levelColor(level, "secondary", COLORS)
  local stateIcon, stateText
  if level == "none" then
    stateIcon = "plug-off"
    stateText = noctalia.tr("status.none")
  elseif level == "lost" then
    stateIcon = "plug-x"
    stateText = shared.lostText(link, now)
  else
    stateIcon = if level == "normal" then "circle-check" else "alert-triangle"
    local source = shared.sourceText(snap)
    stateText = if source then `{shared.statusText(snap)} · {source}` else shared.statusText(snap)
  end

  local titles = { label(title, BODY + 1, "on_surface", { fontWeight = "medium", maxLines = 1 }) }
  if subtitle ~= "" then
    table.insert(titles, label(subtitle, SMALL, "on_surface_variant", { maxLines = 1 }))
  end

  return ui.column({ width = W, gap = 8 }, {
    ui.row({ width = W, gap = 10, align = "center" }, {
      ui.glyph({ name = shared.powerIcon(snap, level), size = 24, color = shared.levelColor(level, "primary", COLORS) }),
      ui.column({ flexGrow = 1, gap = 0 }, titles),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
    }),
    ui.row({ width = W, gap = 6, align = "center" }, {
      ui.glyph({ name = stateIcon, size = 16, color = stateColor }),
      label(stateText, CAPTION, stateColor, { fontWeight = "medium", flexGrow = 1, maxLines = 2 }),
    }),
  })
end

-- Sections

local function noUpsCard()
  local reason = if link and link.message and link.message ~= "" then link.message else noctalia.tr("status.starting")
  return card(nil, {
    ui.row({ gap = 12, align = "center" }, {
      ui.glyph({ name = "plug-off", size = 30, color = "outline_variant" }),
      label(reason, CAPTION, "on_surface_variant", { flexGrow = 1, maxLines = 4 }),
    }),
  })
end

local function heroCard(lost: boolean)
  local function cell(statKey: string, color: string, caption: string)
    local number, unit = shared.heroParts(statKey, snap)
    local parts = { label(number, HERO, color, { fontWeight = "bold" }) }
    if unit ~= "" then
      -- Nudged up onto the number's baseline, like lift() in desktop.luau.
      table.insert(parts, ui.column({ gap = 0 }, { label(unit, BODY, color), ui.spacer({ height = 3, flexGrow = 0 }) }))
    end
    return ui.column({ width = HERO_CELL, gap = 0, align = "center" }, {
      ui.row({ gap = 3, align = "end" }, parts),
      label(caption, SMALL, "on_surface_variant", { textAlign = "center" }),
    })
  end
  local loadCaption = if snap.loadW
    then noctalia.tr("panel.load_caption", { watts = shared.formatStat("load_w", snap) })
    else noctalia.tr("caption.load_pct")
  return card(nil, {
    ui.row({ justify = "center" }, {
      cell("battery_pct", statColor("battery_pct", "on_surface"), noctalia.tr("caption.battery_pct")),
      cell("load_pct", statColor("load_pct", "secondary"), loadCaption),
      cell("runtime", statColor("runtime", "on_surface"), noctalia.tr("caption.runtime")),
    }),
  }, nil, if lost then DIM else nil)
end

local function normalized(statKey: string, values)
  if values == nil then
    return {}
  end
  local lo, hi = shared.graphRange(statKey, values, snap)
  return shared.normalize(values, lo, hi)
end

local function graphCard(now: number, lost: boolean)
  local current = series[span] or {}
  local load, volts = current.load_w, current.input_v
  local loadColor = statColor("load_w", "primary")
  local voltColor = "secondary"

  local chips = {}
  for _, s in SPANS do
    table.insert(chips, ui.button({
      key = `span-{s}`,
      text = noctalia.tr("panel.span." .. s),
      variant = "ghost",
      controlSize = "sm",
      fontSize = SMALL,
      selected = s == span,
      onClick = function()
        span = s
        hoverIndex = nil
        render()
      end,
    }))
  end

  local readout
  if hoverIndex ~= nil and load ~= nil then
    local seconds = shared.SPAN_SECONDS[span]
    local bucket = seconds / shared.GRAPH_POINTS
    local at = now - seconds + math.floor((hoverIndex - 0.5) * bucket)
    readout = noctalia.tr("panel.hover", {
      time = noctalia.formatTime(noctalia.timeFormat(), at),
      load = shared.formatStat("load_w", { loadW = load[hoverIndex] }),
      volts = if volts then shared.formatStat("input_v", { inputV = volts[hoverIndex] }) else "—",
    })
  else
    readout = noctalia.tr("panel.hover", {
      time = noctalia.tr("panel.now"),
      load = shared.formatStat("load_w", snap),
      volts = shared.formatStat("input_v", snap),
    })
  end

  return card(noctalia.tr("panel.section.graph"), {
    ui.graph({
      height = 84,
      values = normalized("load_w", load),
      values2 = normalized("input_v", volts),
      color = loadColor,
      color2 = voltColor,
      lineWidth = 0.75,
      fillOpacity = 0.2,
      onPointerMove = "onGraphMove",
      onPointerLeave = "onGraphLeave",
    }),
    label(readout, SMALL, "on_surface_variant"),
  }, ui.row({ gap = 2 }, chips), if lost then DIM else nil)
end

local function readoutCard(level: string, ctx, lost: boolean)
  local rows = {}
  for _, row in shared.ROWS do
    local value = shared.rowValue(row.key, snap, ctx)
    if value ~= nil then
      local color = if row.key == "state" then shared.levelColor(level, "secondary", COLORS) else nil
      table.insert(rows, keyValue(noctalia.tr("rows." .. row.key), value, color))
    end
  end
  return card(noctalia.tr("panel.section.readout"), rows, nil, if lost then DIM else nil)
end

local function lowBatteryText(pct: number?, seconds: number?, shutsDown: boolean?): string?
  if pct == nil and seconds == nil then
    return nil
  end
  local text = noctalia.tr("protection.low_value", {
    pct = if pct then tostring(pct) else "—",
    time = shared.formatRuntime(seconds),
  })
  return if shutsDown then `{text} · {noctalia.tr("protection.shuts_down")}` else text
end

local function protectionCard()
  local rows = {}
  local config = policy and policy.config
  if policy and policy.source == "pwrstat" and config then
    local fail = config.powerFail or {}
    table.insert(rows, keyValue(
      noctalia.tr("protection.power_failure"),
      if fail.shutdown
        then noctalia.tr("protection.shutdown_after", { time = shared.formatRuntime(fail.delaySec or 0) })
        else noctalia.tr("protection.no_shutdown")
    ))
    local low = config.lowBattery or {}
    local lowText = lowBatteryText(low.capacityPct, low.runtimeSec, low.shutdown)
    if lowText then
      table.insert(rows, keyValue(noctalia.tr("protection.low_battery"), lowText))
    end
    if config.alarm ~= nil then
      table.insert(rows, keyValue(noctalia.tr("protection.alarm"), noctalia.tr(if config.alarm then "protection.on" else "protection.off")))
    end
  elseif snap and snap.source == "nut" then
    table.insert(rows, keyValue(noctalia.tr("protection.power_failure"), noctalia.tr("protection.nut_upsmon")))
    local lowText = lowBatteryText(snap.lowBatteryChargePct, snap.lowBatteryRuntimeSec, nil)
    if lowText then
      table.insert(rows, keyValue(noctalia.tr("protection.low_battery"), lowText))
    end
    local beeper = shared.rowValue("beeper", snap, {})
    if beeper then
      table.insert(rows, keyValue(noctalia.tr("protection.alarm"), beeper))
    end
  end
  if #rows == 0 then
    table.insert(rows, label(noctalia.tr("protection.unknown"), CAPTION, "on_surface_variant"))
  end
  return card(noctalia.tr("panel.section.protection"), rows)
end

local function buildEventRows(now: number)
  local rows = {}
  for i, event in events do
    local details = {}
    if event.at then
      table.insert(details, shared.formatDate(event.at, dateStyle, now))
    end
    if event.durationSec then
      table.insert(details, shared.formatRuntime(event.durationSec))
    end
    table.insert(rows, ui.row({ key = `event-{i}`, gap = 8, align = "start" }, {
      label(shared.eventText({ key = event.key, text = event.text }, dateStyle, now) or "", CAPTION, EVENT_COLORS[event.key] or "on_surface"),
      label(table.concat(details, " · "), SMALL, "on_surface_variant", { flexGrow = 1, textAlign = "end" }),
    }))
  end
  if #rows == 0 then
    table.insert(rows, label(noctalia.tr("panel.events_empty"), CAPTION, "on_surface_variant"))
  end
  return rows
end

local function eventsCard(now: number)
  local minute = if dateStyle == "relative" then now // 60 else 0
  if eventRows == nil or minute ~= eventRowsMinute then
    eventRows = buildEventRows(now)
    eventRowsMinute = minute
  end
  local kept = label(noctalia.tr("panel.events_kept", { count = #events }), SMALL, "on_surface_variant")
  return card(noctalia.tr("panel.section.events"), eventRows, kept)
end

-- Actions

local function request(action: string)
  pendingId = tostring(noctalia.nowMs())
  pendingSince = os.time()
  reply = nil
  noctalia.state.set(KEYS.request, { id = pendingId, action = action })
  render()
end

-- Whether the UPS alarm is currently on, when known.
local function alarmOn(): boolean?
  if policy and policy.source == "pwrstat" and policy.config then
    return policy.config.alarm
  elseif snap and snap.beeper then
    return snap.beeper ~= "disabled"
  end
  return nil
end

local function actionsBar()
  if confirmingTest then
    return ui.column({ width = W, gap = 8 }, {
      label(noctalia.tr("actions.confirm_test"), CAPTION, "on_surface", { width = W, maxLines = 3 }),
      ui.row({ width = W, gap = 8 }, {
        ui.button({
          text = noctalia.tr("actions.cancel"),
          variant = "ghost",
          flexGrow = 1,
          onClick = function()
            confirmingTest = false
            render()
          end,
        }),
        ui.button({
          text = noctalia.tr("actions.run"),
          variant = "primary",
          flexGrow = 1,
          onClick = function()
            confirmingTest = false
            request("test")
          end,
        }),
      }),
    })
  end

  local idle = pendingId == nil
  local on = alarmOn()
  local children = {
    ui.row({ width = W, gap = 8 }, {
      ui.button({
        glyph = "activity",
        text = noctalia.tr("actions.test"),
        tooltip = noctalia.tr("actions.test_tip"),
        flexGrow = 1,
        controlSize = "sm",
        enabled = idle,
        onClick = function()
          confirmingTest = true
          render()
        end,
      }),
      ui.button({
        glyph = "bell-off",
        text = noctalia.tr("actions.mute"),
        tooltip = noctalia.tr("actions.mute_tip"),
        flexGrow = 1,
        controlSize = "sm",
        enabled = idle,
        onClick = function()
          request("mute")
        end,
      }),
      ui.button({
        glyph = if on == false then "bell" else "bell-off",
        text = noctalia.tr(if on == false then "actions.alarm_on" else "actions.alarm_off"),
        tooltip = noctalia.tr(if on == false then "actions.alarm_on_tip" else "actions.alarm_off_tip"),
        flexGrow = 1,
        controlSize = "sm",
        enabled = idle,
        onClick = function()
          request(if on == false then "alarm_on" else "alarm_off")
        end,
      }),
    }),
  }
  if reply ~= nil then
    table.insert(children, label(reply.message or "", SMALL, if reply.ok then "on_surface_variant" else "error", {
      width = W,
      maxLines = 3,
    }))
  end
  return ui.column({ width = W, gap = 6 }, children)
end

-- Render

function render()
  if not isOpen then
    return
  end
  local now = os.time()
  -- No answer (the service restarted or is stuck): stop waiting so the
  -- buttons work again.
  if pendingId ~= nil and now - pendingSince > PENDING_TIMEOUT_SEC then
    pendingId = nil
    reply = { ok = false, message = noctalia.tr("actions.no_answer") }
  end
  local level = shared.level(snap, link)
  local lost = level == "lost"
  local ctx = { style = dateStyle, now = now, test = test, lastEvent = shared.lastPowerEvent(events) }

  local body = {}
  if level == "none" then
    table.insert(body, noUpsCard())
  else
    if show.hero then
      table.insert(body, heroCard(lost))
    end
    if show.graph then
      table.insert(body, graphCard(now, lost))
    end
    if show.readout then
      table.insert(body, readoutCard(level, ctx, lost))
    end
    if show.protection then
      table.insert(body, protectionCard())
    end
  end
  if show.events then
    table.insert(body, eventsCard(now))
  end

  local children = {
    header(level, now),
    ui.scroll({ width = W, flexGrow = 1, gap = 10 }, body),
  }
  if show.actions and level ~= "none" then
    table.insert(children, actionsBar())
  end
  panel.render(ui.column({ width = W, height = H, gap = 10 }, children))
end

-- Wiring

local function watch(key: string, apply: (any) -> ())
  noctalia.state.watch(key, function(value)
    apply(value)
    render()
  end)
end

-- The link always arrives right after the snapshot, so it does the rendering.
noctalia.state.watch(KEYS.snapshot, function(value)
  snap = value
end)
watch(KEYS.link, function(value)
  link = value
end)
watch(KEYS.events, function(value)
  events = value or {}
  eventRows = nil
end)
watch(KEYS.test, function(value)
  test = value
end)
watch(KEYS.policy, function(value)
  policy = value
end)
for _, s in SPANS do
  watch(shared.seriesKey(s), function(value)
    series[s] = value
  end)
end
watch(KEYS.reply, function(value)
  if type(value) == "table" and value.id == pendingId then
    pendingId = nil
    reply = value
  end
end)

-- Pointer position over the graph, 0..1 across its width (named handlers so a
-- leave still arrives after a re-render).
function onGraphMove(normX, _normY)
  hoverIndex = math.clamp(math.floor(tonumber(normX) * shared.GRAPH_POINTS) + 1, 1, shared.GRAPH_POINTS)
  render()
end

function onGraphLeave()
  hoverIndex = nil
  render()
end

function onOpen(_context)
  isOpen = true
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
  confirmingTest = false
  hoverIndex = nil
  reply = nil
end

function update()
  render()
end
