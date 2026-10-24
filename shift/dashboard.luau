--!nonstrict
-- Shift dashboard panel (spec §7.4): header with the status and undo, the Today / History /
-- Balance tabs, attention cards, first-run card, hero ring with the live counter and the
-- check in/out button (or its compact line), stat tiles, the tab's content, pages (day
-- editor, balance forms, automation details), and the automation footer. It renders the
-- core snapshot every second while open and sends actions as commands.

local BalanceView = require("./lib/ui/balance.luau")
local Commands = require("./lib/commands.luau")
local Editor = require("./lib/ui/editor.luau")
local Format = require("./lib/format.luau")
local History = require("./lib/ui/history.luau")
local Host = require("./lib/host.luau")
local Model = require("./lib/model.luau")
local Overlay = require("./lib/ui/overlay.luau")
local Ring = require("./lib/ring.luau")
local Time = require("./lib/time.luau")
local Types = require("./lib/types.luau")
local Widgets = require("./lib/ui/widgets.luau")

type Snapshot = Types.Snapshot
type Live = Types.Live

local HERO_RING = 168
local HERO_STROKE = 11
-- Space between the ring and the check-in button.
local HERO_BUTTON_GAP = 14
local COMPACT_RING = 40
local COMPACT_STROKE = 5
local COUNTER_SIZE = 36
local COUNTER_MIN = 22
-- Width the counter may take inside the ring. The lines below it lift it above the
-- center, where the ring is narrower.
local COUNTER_ROOM = HERO_RING - 2 * HERO_STROKE - 24
local UNIT_SCALE = 0.55 -- unit letters next to the counter's numbers
local SECONDS_SIZE = 16
local COUNTER_GAP = 2
-- A label's text baseline sits this many font sizes above the bottom of its box (half of
-- line height minus cap height, DejaVu-like metrics), so a small label next to a large one
-- in a bottom-aligned row is raised by this ratio of their size difference.
local BASELINE_RATIO = 0.22
local DETAIL_SIZE = 13
local RADIUS = 12
local ROW_HEIGHT = 22
local ROW_GAP = 6
-- Attention cards shown at once; the rest are counted.
local MAX_CARDS = 2
-- Sessions listed on the Today tab, most recent first.
local MAX_SESSIONS = 3
-- Rough heights (px) to tell whether the Today tab fits the panel with the full hero; it
-- takes the compact one otherwise. The body is the panel's height (plugin.toml) minus the
-- header, the tabs, the footer and the margins.
local BODY_HEIGHT = 686 - 146 - 50
local BODY_GAP = 12
local HERO_HEIGHT = HERO_RING + HERO_BUTTON_GAP + 44
local TILES_HEIGHT = 74
local CARD_HEIGHTS = { row = 52, column = 96, label = 18 } -- one action, two actions, "+N more"
local ERROR_HEIGHT = 28 -- the command error line, above the body
local EMPTY_HEIGHT = 16 -- "No sessions yet today."
local TIMELINE_HEIGHT = 30
local PREVIEW_LABEL = 32
local TREND_COLORS = { up = "#4caf50", flat = "#9e9e9e", down = "#e53935" }

local host = Host.new()
local snapshot: Snapshot? = host.state.get("shift.snapshot")
local history: Types.HistoryInfo? = host.state.get("shift.history") -- days the panel asked for
local balanceInfo: Types.BalanceInfo? = host.state.get("shift.balance")
local isOpen = false
local commandError: string? = nil -- shown inline until the next action
local detailsOpen = false -- the automation details replace the dashboard body
local tab = "today"
local historyState: History.HistoryState = { mode = "week", anchor = "" }
local balanceState = BalanceView.new()
local editor: Editor.EditorState? = nil -- the day editor replaces the dashboard body
local requested: string? = nil -- range of the last history request

local render -- forward declaration: commands re-render on failure

local sender = Commands.sender(host, "dashboard", function(cmd, err)
  host.log(string.format("dashboard: command %s failed: %s", tostring(cmd.type), tostring(err)))
  if err == "nothing_to_undo" then
    commandError = host.tr("panel.errors.undo_expired")
  elseif err == "timeout" then
    commandError = host.tr("panel.errors.command")
  else
    commandError = host.tr("panel.errors.rejected")
  end
  if isOpen then
    render()
  end
end)

local function send(cmd: { [string]: any })
  commandError = nil
  sender.send(cmd)
end

local function clock(epochS: number): string
  return Format.clock(host, epochS)
end

-- Header -----------------------------------------------------------------------

local function undoLabel(undo): string
  local date = undo.date and Widgets.date(host, undo.date, "%a %d %b") or ""
  return host.tr("panel.undo." .. undo.kind, { time = clock(undo.atS), date = date })
end

local DOT_COLORS = { working = "primary", away = "secondary", off = "on_surface_variant" }

-- "Working since 9:02 · Done at ~17:12": the status, with the estimated end of the day
-- while working.
local function statusText(snap: Snapshot, live: Live, nowS: number): string
  local status = snap.status
  local text
  if status == "away" and snap.since then
    local minutes = (nowS - snap.since) // 60
    if minutes < 60 then
      text = host.trp("panel.status.away_for", minutes)
    else
      text = host.tr("panel.status.away_since", { time = clock(snap.since) })
    end
  elseif status == "working" and snap.since then
    text = host.tr("panel.status.working_since", { time = clock(snap.since) })
  elseif snap.since then
    text = host.tr("panel.status.off_since", { time = clock(snap.since) })
  else
    text = host.tr("panel.status.off")
  end
  if live.etaS then
    text ..= " · " .. host.tr("panel.hero.done_at", { time = clock(live.etaS) })
  end
  return text
end

-- Title, with the status under it: it stays in sight on every tab and page.
local function header(snap: Snapshot, live: Live, nowS: number): UiNode
  local undo = snap.undo
  local canUndo = undo ~= nil and nowS - undo.atS < Model.UNDO_WINDOW_S
  return ui.row({ align = "center", gap = 4 }, {
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = host.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.row({ align = "center", gap = 6 }, {
        ui.box({ width = 8, height = 8, radius = 4, fill = DOT_COLORS[snap.status] }),
        ui.label({ text = statusText(snap, live, nowS), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
      }),
    }),
    ui.button({
      glyph = "history",
      variant = "ghost",
      visible = canUndo,
      tooltip = canUndo and undoLabel(undo) or nil,
      onClick = function()
        if snapshot and snapshot.undo then
          send({ type = "undo", id = snapshot.undo.id })
        end
      end,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = host.tr("panel.settings"),
      onClick = function()
        host.openSettings()
      end,
    }),
  })
end

-- Attention cards (spec §7.4.2) -------------------------------------------------------

local smallButton = Widgets.smallButton

local function card(glyph: string, text: string, actions: { UiNode }): UiNode
  local line = {
    ui.glyph({ name = glyph, color = "secondary" }),
    ui.label({ text = text, flexGrow = 1, maxLines = 2, fontSize = 13 }),
  }
  -- A single action fits on the text's line; two go under it.
  if #actions == 1 then
    table.insert(line, actions[1])
    return ui.row({ align = "center", gap = 10, paddingH = 12, paddingV = 8, radius = RADIUS, fill = "surface_variant" }, line)
  end
  local children = { ui.row({ align = "center", gap = 10 }, line) }
  if #actions > 0 then
    table.insert(children, ui.row({ gap = 8, justify = "end" }, actions))
  end
  return ui.column({ gap = 8, padding = 12, radius = RADIUS, fill = "surface_variant" }, children)
end

local openEditor -- forward declaration: cards open the day editor

-- Cards in priority order: a suggestion, pending absences (most recent first), invalid
-- settings, days to review, then one-time hints.
local function attentionCards(snap: Snapshot, nowS: number): { UiNode }
  local fmt = snap.display.durationFormat
  local cards = {}
  local suggestion = snap.suggestion
  if suggestion then
    local checkin = suggestion == "checkin"
    table.insert(cards, card(checkin and "clock-play" or "clock-pause", host.tr("panel.attention.suggest_" .. suggestion, { time = clock(nowS) }), {
      smallButton(host.tr("panel.attention.not_now"), "ghost", function()
        send({ type = "suggestion.dismiss", kind = suggestion })
      end),
      smallButton(host.tr(checkin and "panel.checkin" or "panel.checkout"), checkin and "primary" or "outline", function()
        send({ type = checkin and "checkin" or "checkout" })
      end),
    }))
  end
  for index = #snap.pending, 1, -1 do
    local absence = snap.pending[index]
    local text = host.tr("panel.attention.away", {
      from = clock(absence.startS),
      to = clock(absence.endS),
      duration = Format.short(host, (absence.endS - absence.startS) * 1000, fmt),
    }) .. " · " .. host.tr("panel.attention.signal." .. absence.signal)
    table.insert(cards, card("clock-exclamation", text, {
      smallButton(host.tr("panel.attention.remove"), "ghost", function()
        send({ type = "absence.resolve", id = absence.id, keep = false })
      end),
      smallButton(host.tr("panel.attention.keep"), "outline", function()
        send({ type = "absence.resolve", id = absence.id, keep = true })
      end),
    }))
  end
  local errors = #snap.automation.ruleErrors
  if errors > 0 then
    table.insert(cards, card("alert-triangle", host.trp("panel.attention.rule_errors", errors), {
      smallButton(host.tr("panel.attention.edit_settings"), "outline", function()
        host.openSettings()
      end),
    }))
  end
  for _, date in snap.flags.needsReview do
    table.insert(cards, card("alert-circle", host.tr("panel.attention.needs_review", { date = Widgets.date(host, date, "%a %d %b") }), {
      smallButton(host.tr("panel.attention.review"), "outline", function()
        openEditor(date)
      end),
    }))
  end
  local toReview = snap.balance and snap.balance.toReview or {}
  if #toReview > 0 then
    table.insert(cards, card("calendar-question", host.trp("panel.attention.to_review", #toReview), {
      smallButton(host.tr("panel.attention.review"), "outline", function()
        openEditor(toReview[1])
      end),
    }))
  end
  for _, hint in snap.automation.hints do
    table.insert(cards, card("info-circle", host.tr("panel.attention." .. hint), {
      smallButton(host.tr("panel.attention.dismiss"), "ghost", function()
        send({ type = "hint.dismiss", id = hint })
      end),
    }))
  end
  if #cards > MAX_CARDS then
    local more = #cards - MAX_CARDS
    cards = { table.unpack(cards, 1, MAX_CARDS) }
    table.insert(cards, ui.label({ text = host.trp("panel.attention.more", more), fontSize = 12, color = "on_surface_variant" }))
  end
  return cards
end

-- Estimated height of the cards, gaps included.
local function cardsHeight(cards: { UiNode }): number
  local height = 0
  for _, node in cards do
    height += (CARD_HEIGHTS[node.type] or CARD_HEIGHTS.column) + BODY_GAP
  end
  return height
end

-- First-run card (spec §6.10) ------------------------------------------------------

local function dayNames(): { string }
  local names = {}
  for _, key in { "mon", "tue", "wed", "thu", "fri", "sat", "sun" } do
    table.insert(names, host.tr("days.short." .. key))
  end
  return names
end

local openTab -- forward declaration: the welcome card opens the Balance tab

local function welcomeCard(snap: Snapshot): UiNode
  local contract = snap.contract
  local fmt = snap.display.durationFormat
  local summary = host.tr("panel.welcome.contract", {
    hours = Format.duration(contract.weeklyHours * 3600000, fmt),
    days = Format.workdays(contract.workdays, dayNames()),
    daily = Format.duration(contract.dailyTargetMs, fmt),
  })
  return ui.column({ gap = 10, padding = 14, radius = RADIUS, fill = "surface_variant" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "briefcase", color = "primary" }),
      ui.label({ text = host.tr("panel.welcome.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = host.tr("panel.welcome.dismiss"),
        onClick = function()
          send({ type = "onboarding.dismiss" })
        end,
      }),
    }),
    ui.label({ text = host.tr("panel.welcome.body"), maxLines = 3 }),
    ui.label({ text = summary, color = "on_surface_variant", fontSize = 12, maxLines = 2 }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = host.tr("panel.welcome.settings"),
        glyph = "settings",
        variant = "outline",
        onClick = function()
          host.openSettings()
        end,
      }),
      ui.button({
        text = host.tr("panel.welcome.balance"),
        variant = "ghost",
        onClick = function()
          openTab("balance", "settings")
        end,
      }),
    }),
  })
end

-- Hero (spec §7.4.3) ------------------------------------------------------------------

local function heroDetails(live: Live, fmt: Types.DurationFormat): { UiNode }
  if live.targetMs == 0 then
    return { ui.label({ text = host.tr("panel.hero.no_target"), fontSize = DETAIL_SIZE, color = "on_surface_variant" }) }
  end
  local details = {
    ui.label({
      text = host.tr("panel.hero.of_target", { target = Format.duration(live.targetMs, fmt) }),
      fontSize = DETAIL_SIZE,
      color = "on_surface_variant",
    }),
  }
  if live.overtimeMs > 0 then
    table.insert(details, ui.label({
      text = host.tr("panel.hero.over", { overtime = Format.duration(live.overtimeMs, fmt) }),
      fontSize = DETAIL_SIZE,
      color = "tertiary",
    }))
  else
    table.insert(details, ui.label({
      text = host.tr("panel.hero.left", { remaining = Format.duration(live.remainingMs, fmt) }),
      fontSize = DETAIL_SIZE,
      color = "on_surface_variant",
    }))
  end
  return details
end

-- Rough advance width in em of a bold UI font as wide as DejaVu Sans, to keep the
-- counter inside the ring.
local function ems(text: string): number
  local total = 0
  for char in string.gmatch(text, ".") do
    if string.match(char, "%d") then
      total += 0.7
    elseif char == "m" then
      total += 1.05
    elseif string.match(char, "%a") then
      total += 0.72
    else
      total += 0.4
    end
  end
  return total
end

-- The worked time in large numbers with smaller units ("7h 30m"), shrunk when it would
-- not fit inside the ring ("10:30"). Seconds tick discreetly after the colon format only:
-- the other formats are too wide for them.
local function counter(ms: number, fmt: Types.DurationFormat): (UiNode, number)
  local parts = Format.parts(Format.duration(ms, fmt))
  local seconds = fmt == "colon" and string.format(":%02d", ms // 1000 % 60) or nil
  local scaled, labels = 0, #parts
  -- The space between parts follows the unit, at its smaller size.
  local function unitText(index: number): string
    return parts[index].unit .. (index < #parts and " " or "")
  end
  for index, part in parts do
    scaled += ems(part.number) + ems(unitText(index)) * UNIT_SCALE
    labels += if part.unit ~= "" then 1 else 0
  end
  local fixed = 0
  if seconds then
    labels += 1
    fixed += ems(seconds) * SECONDS_SIZE * 0.9 -- regular weight: narrower
  end
  fixed += (labels - 1) * COUNTER_GAP
  local size = math.clamp(math.floor((COUNTER_ROOM - fixed) / scaled), COUNTER_MIN, COUNTER_SIZE)

  -- Labels share the large numbers' baseline: smaller ones stand on a spacer.
  local function small(props)
    local lift = math.round((size - props.fontSize) * BASELINE_RATIO)
    return ui.column({ gap = 0 }, { ui.label(props), ui.box({ height = lift, opacity = 0 }) })
  end
  local nodes = {}
  for index, part in parts do
    table.insert(nodes, ui.label({ text = part.number, fontSize = size, fontWeight = "bold" }))
    if part.unit ~= "" then
      table.insert(nodes, small({ text = unitText(index), fontSize = math.round(size * UNIT_SCALE), fontWeight = "bold" }))
    end
  end
  if seconds then
    table.insert(nodes, small({ text = seconds, fontSize = SECONDS_SIZE, color = "on_surface_variant" }))
  end
  return ui.row({ align = "end", gap = COUNTER_GAP }, nodes), size
end

local function checkButton(working: boolean, size: string, width: number?): UiNode
  return ui.button({
    text = host.tr(working and "panel.checkout" or "panel.checkin"),
    glyph = working and "logout" or "login-2",
    variant = working and "outline" or "primary",
    controlSize = size,
    width = width,
    onClick = function()
      send({ type = working and "checkout" or "checkin" })
    end,
  })
end

local function hero(snap: Snapshot, live: Live): UiNode
  local working = snap.status ~= "off"
  local fmt = snap.display.durationFormat
  local count, size = counter(live.workedMs, fmt)
  local details = heroDetails(live, fmt)
  local text = ui.column({ align = "center", gap = 0 }, { count, table.unpack(details) })
  local textHeight = size * 1.25 + #details * DETAIL_SIZE * 1.35

  -- Without a target the ring only frames the counter: an empty track.
  local progress = live.targetMs > 0 and live.workedMs / live.targetMs or 0
  local ringPath = Ring.path(host, HERO_RING, HERO_STROKE, progress, not working)
  local visual
  if ringPath then
    visual = Overlay.center(ui.image({ path = ringPath, width = HERO_RING, height = HERO_RING }), HERO_RING, text, textHeight)
  else
    visual = ui.column({ align = "center", gap = 8 }, {
      text,
      ui.progress({ progress = math.min(progress, 1), width = HERO_RING, height = 6, radius = 3 }),
    })
  end
  return ui.column({ align = "center", gap = HERO_BUTTON_GAP }, { visual, checkButton(working, "lg", 200) })
end

-- The hero on the History and Balance tabs, during onboarding, and on Today when the full
-- one would not fit: a small ring, the counter and the button on one line.
local function compactHero(snap: Snapshot, live: Live): UiNode
  local working = snap.status ~= "off"
  local fmt = snap.display.durationFormat
  local progress = live.targetMs > 0 and live.workedMs / live.targetMs or 0
  local children = {}
  local ringPath = Ring.path(host, COMPACT_RING, COMPACT_STROKE, progress, not working)
  if ringPath then
    table.insert(children, ui.image({ path = ringPath, width = COMPACT_RING, height = COMPACT_RING }))
  end
  local details = heroDetails(live, fmt)
  local line = {}
  for _, detail in details do
    table.insert(line, detail.props.text)
  end
  table.insert(children, ui.column({ flexGrow = 1, gap = 0 }, {
    ui.label({ text = Format.duration(live.workedMs, fmt), fontSize = 20, fontWeight = "bold" }),
    ui.label({ text = table.concat(line, " · "), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
  }))
  table.insert(children, checkButton(working, "md"))
  return ui.row({ align = "center", gap = 12 }, children)
end

-- Stat tiles (spec §7.4.4) --------------------------------------------------------------

local function tile(title: string, value: string, valueColor: string?, extra: UiNode?, tooltip: string?): UiNode
  local children = {
    ui.label({ text = title, fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 15, fontWeight = "bold", color = valueColor, maxLines = 1 }),
  }
  if extra then
    table.insert(children, extra)
  end
  return ui.column({ flexGrow = 1, gap = 4, padding = 10, radius = RADIUS, fill = "surface_variant", tooltip = tooltip }, children)
end

local function tiles(snap: Snapshot, live: Live): UiNode
  local fmt = snap.display.durationFormat
  local week = Format.duration(live.weekWorkedMs, fmt)
  local weekProgress
  if live.weekTargetMs > 0 then
    weekProgress = ui.progress({ progress = math.min(1, live.weekWorkedMs / live.weekTargetMs), height = 4, radius = 2 })
  end
  local delta = live.workedMs - live.targetMs
  -- Where today takes the balance if the day ended now: up, flat or down, in fixed colors
  -- that read the same with every theme. Without a balance yet (a long history at
  -- startup), the tile waits for it.
  local balanceTile
  if snap.balance then
    local settled = snap.balance.settledMs
    local glyph, color = "arrow-right", TREND_COLORS.flat
    if delta >= 60000 then
      glyph, color = "trending-up", TREND_COLORS.up
    elseif delta <= -60000 then
      glyph, color = "trending-down", TREND_COLORS.down
    end
    -- The value alone fits the tile with any format; the tooltip says what it is.
    local trend = ui.row({ align = "center", gap = 4 }, {
      ui.glyph({ name = glyph, size = 12, color = color }),
      ui.label({ text = Format.signed(settled + delta, fmt), fontSize = 12, color = color, maxLines = 1 }),
    })
    balanceTile = tile(
      host.tr("panel.stats.balance"),
      Format.signed(settled, fmt),
      settled >= 60000 and "tertiary" or nil,
      trend,
      host.tr("panel.stats.with_today")
    )
  else
    balanceTile = tile(host.tr("panel.stats.balance"), "…", "on_surface_variant", nil, host.tr("panel.stats.computing"))
  end
  return ui.row({ gap = 8 }, {
    tile(host.tr("panel.stats.week"), week, nil, weekProgress),
    balanceTile,
    tile(host.tr("panel.stats.today"), Format.signed(delta, fmt), delta >= 60000 and "tertiary" or nil, nil),
  })
end

-- Today (spec §7.4.5) ------------------------------------------------------------------

-- Sessions of the day, the open one ending now.
local function todaySessions(snap: Snapshot, nowS: number): { { startS: number, endS: number, open: boolean } }
  local list = {}
  for _, session in snap.today.sessions do
    table.insert(list, { startS = session.startS, endS = session.endS, open = false })
  end
  if snap.today.openStartMs then
    table.insert(list, { startS = snap.today.openStartMs // 1000, endS = nowS, open = true })
  end
  return list
end

-- Look of each kind of timeline segment (spec §7.4.5). Decided absences are not drawn:
-- kept time is work, removed time is a gap between sessions.
local SEGMENT_STYLES = {
  work = "primary",
  pending = "secondary/0.6",
  gap = "on_surface/0.08",
}

-- Splits the day into segments: gaps, worked time, and the pending absences inside sessions.
local function segmentsOf(sessions, absences, fromS: number, toS: number): { { kind: string, startS: number, endS: number } }
  local segments = {}
  local function push(kind: string, startS: number, endS: number)
    if endS > startS then
      table.insert(segments, { kind = kind, startS = startS, endS = endS })
    end
  end
  local cursor = fromS
  for _, session in sessions do
    push("gap", cursor, session.startS)
    local at = session.startS
    for _, absence in absences do
      local startS, endS = math.max(absence.startS, at), math.min(absence.endS, session.endS)
      if endS > startS then
        push("work", at, startS)
        push("pending", startS, endS)
        at = endS
      end
    end
    push("work", at, session.endS)
    cursor = math.max(cursor, session.endS)
  end
  push("gap", cursor, toS)
  return segments
end

-- Proportional bar from the first whole hour to the next one after now. Widths come from
-- flexGrow, proportional to durations.
local function timeline(sessions, absences, nowS: number): UiNode
  local first = sessions[1].startS
  local fromS = first - (first % 3600)
  local last = math.max(nowS, sessions[#sessions].endS)
  local toS = last - (last % 3600) + 3600
  local segments = {}
  for _, segment in segmentsOf(sessions, absences, fromS, toS) do
    table.insert(segments, ui.box({
      flexGrow = math.max(segment.endS - segment.startS, 60),
      height = 10,
      radius = 3,
      fill = SEGMENT_STYLES[segment.kind],
    }))
  end
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 2 }, segments),
    ui.row({ justify = "space_between" }, {
      ui.label({ text = clock(fromS), fontSize = 12, color = "on_surface_variant" }),
      ui.label({ text = clock(toS), fontSize = 12, color = "on_surface_variant" }),
    }),
  })
end

-- The Today tab and its estimated height.
local function today(snap: Snapshot, nowS: number): (UiNode, number)
  local fmt = snap.display.durationFormat
  local sessions = todaySessions(snap, nowS)
  local children = {}
  if #sessions == 0 then
    table.insert(children, ui.label({ text = host.tr("panel.today.empty"), color = "on_surface_variant", fontSize = 12 }))
    return ui.column({ gap = 8 }, children), EMPTY_HEIGHT
  end
  table.insert(children, timeline(sessions, snap.today.absences, nowS))
  -- Most recent first: the running session stays on top. Older ones are in the editor.
  local rows = {}
  for index = #sessions, math.max(1, #sessions - MAX_SESSIONS + 1), -1 do
    local session = sessions[index]
    local range = host.tr("panel.today.range", {
      from = clock(session.startS),
      to = session.open and host.tr("panel.today.now") or clock(session.endS),
    })
    -- The pencil is the only target: a button has the hover state, the pointer cursor, and
    -- its tooltip next to the cursor (the host anchors tooltips under their node).
    table.insert(rows, ui.row({ align = "center", gap = 8, height = ROW_HEIGHT }, {
      ui.label({ text = range, flexGrow = 1, color = session.open and "primary" or nil }),
      ui.label({ text = Format.duration((session.endS - session.startS) * 1000, fmt), fontWeight = "bold" }),
      Widgets.editButton(host.tr("panel.today.edit"), function()
        openEditor(snap.today.date)
      end),
    }))
  end
  local earlier = #sessions - MAX_SESSIONS
  if earlier > 0 then
    table.insert(rows, ui.row({ align = "center", height = ROW_HEIGHT }, {
      ui.label({ text = host.trp("panel.today.earlier", earlier), flexGrow = 1, fontSize = 12, color = "on_surface_variant" }),
      smallButton(host.tr("panel.today.edit"), "ghost", function()
        openEditor(snap.today.date)
      end),
    }))
  end
  table.insert(children, ui.column({ gap = ROW_GAP }, rows))
  return ui.column({ gap = 8 }, children), TIMELINE_HEIGHT + 8 + #rows * (ROW_HEIGHT + ROW_GAP)
end

-- Automation (spec §7.4.6) --------------------------------------------------------------

local function automationSummary(snap: Snapshot): string
  local automation = snap.automation
  if automation.preset == "manual" then
    return host.tr("panel.automation.manual_summary")
  end
  local parts = {
    host.tr("panel.automation.preset." .. automation.preset),
    host.tr("panel.automation.idle", { minutes = automation.idleMin }),
  }
  local window = automation.window
  if window.start ~= window["end"] then
    table.insert(parts, host.tr("panel.automation.window", {
      days = Format.workdays(snap.contract.workdays, dayNames()),
      from = window.start,
      to = window["end"],
    }))
  else
    table.insert(parts, host.tr("panel.automation.no_window"))
  end
  if window.extraRules > 0 then
    table.insert(parts, host.trp("panel.automation.rules", window.extraRules))
  end
  return table.concat(parts, " · ")
end

local function footer(snap: Snapshot): UiNode
  return ui.row({ align = "center", gap = 6 }, {
    ui.label({ text = automationSummary(snap), flexGrow = 1, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    ui.button({
      glyph = detailsOpen and "chevron-down" or "info-circle",
      variant = "ghost",
      controlSize = "sm",
      tooltip = host.tr("panel.automation.details"),
      onClick = function()
        detailsOpen = not detailsOpen
        render()
      end,
    }),
  })
end

local sectionTitle = Widgets.sectionTitle

local function backendRow(glyph: string, name: string, health: Types.BackendHealth): UiNode
  local failing = health == "error" or health == "unavailable"
  return ui.row({ align = "center", gap = 10, height = ROW_HEIGHT }, {
    ui.glyph({ name = glyph, color = "on_surface_variant" }),
    ui.label({ text = host.tr("panel.automation.backend." .. name), flexGrow = 1 }),
    ui.label({ text = host.tr("panel.automation.health." .. health), color = failing and "error" or "on_surface_variant" }),
  })
end

-- 7 × 24 strip of this week's window: one row per day, one cell per hour, filled by the
-- share of the hour inside the window.
local function previewStrip(snap: Snapshot): UiNode
  local names = dayNames()
  local rows = {}
  for day, hours in snap.automation.preview do
    local cells = {}
    for hour = 1, 24 do
      local quarters = tonumber(string.sub(hours, hour, hour)) or 0
      local fill = quarters == 0 and "on_surface/0.08" or string.format("primary/%.2f", quarters / 4)
      table.insert(cells, ui.box({ flexGrow = 1, height = 8, radius = 2, fill = fill }))
    end
    -- Labels take their text's width: a fixed-width column aligns the rows.
    table.insert(rows, ui.row({ align = "center", gap = 6 }, {
      ui.column({ width = PREVIEW_LABEL }, { ui.label({ text = names[day], fontSize = 12, color = "on_surface_variant" }) }),
      ui.row({ flexGrow = 1, gap = 1 }, cells),
    }))
  end
  local ticks = {}
  for _, hour in { "0", "6", "12", "18", "24" } do
    table.insert(ticks, ui.label({ text = hour, fontSize = 12, color = "on_surface_variant" }))
  end
  table.insert(rows, ui.row({ gap = 6 }, {
    ui.column({ width = PREVIEW_LABEL }, {}),
    ui.row({ flexGrow = 1, justify = "space_between" }, ticks),
  }))
  return ui.column({ gap = 3 }, rows)
end

local function errorLine(err: Types.RuleError): string
  local setting
  if err.setting == "extra_rules" then
    setting = host.tr("panel.automation.error_rule", { index = err.index })
  else
    setting = host.tr("settings." .. err.setting .. ".label")
  end
  return host.tr("panel.automation.error_line", {
    setting = setting,
    text = err.text,
    reason = host.tr("panel.automation.reason." .. err.reason),
  })
end

local function automationDetails(snap: Snapshot): { UiNode }
  local automation = snap.automation
  local children = {
    sectionTitle(host.tr("panel.automation.backends")),
    ui.column({ gap = ROW_GAP }, {
      backendRow("keyboard", "idle", automation.backends.idle),
      backendRow("lock", "logind", automation.backends.logind),
      backendRow("beach", "holidays", automation.backends.holidays),
    }),
    sectionTitle(host.tr("panel.automation.preview")),
    previewStrip(snap),
  }
  if #automation.ruleErrors > 0 then
    table.insert(children, sectionTitle(host.tr("panel.automation.errors")))
    for _, err in automation.ruleErrors do
      table.insert(children, ui.label({ text = errorLine(err), color = "error", fontSize = 12, maxLines = 3 }))
    end
  end
  table.insert(children, ui.row({ justify = "start" }, {
    ui.button({
      text = host.tr("panel.attention.edit_settings"),
      glyph = "settings",
      variant = "outline",
      onClick = function()
        host.openSettings()
      end,
    }),
  }))
  return children
end

-- Tabs (spec §7.4.5) and the day editor ---------------------------------------------------

local TABS = { "today", "history", "balance" }

-- Asks the core for the days a view shows, once per range.
local function requestHistory(from: string, to: string)
  local range = from .. ".." .. to
  if requested ~= range then
    requested = range
    sender.send({ type = "history.get", from = from, to = to })
  end
end

-- The day of `shift.history`, nil when it is not there yet.
local function historyDay(date: string): Types.DaySummary?
  if history then
    for _, day in history.days do
      if day.date == date then
        return day
      end
    end
  end
  return nil
end

function openEditor(date: string)
  editor = Editor.new(date)
  detailsOpen = false
  render()
end

-- Shows a tab, closing any page; `page` opens one of the Balance tab's pages.
function openTab(name: string, page: BalanceView.BalancePage?)
  if name == "history" and tab ~= "history" and snapshot then
    historyState.anchor = snapshot.today.date
  end
  tab = name
  editor = nil
  detailsOpen = false
  balanceState.page = page
  render()
end

-- Fixed under the header, on every tab and page: a tab closes the open page.
local function tabBar(): UiNode
  local buttons = {}
  for _, name in TABS do
    table.insert(buttons, ui.button({
      text = host.tr("panel.tabs." .. name),
      variant = tab == name and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        openTab(name)
      end,
    }))
  end
  return ui.row({ gap = 4, padding = 3, radius = RADIUS, fill = "surface_variant" }, buttons)
end

local function viewOf(snap: Snapshot, live: Live, nowS: number): Widgets.View
  return {
    host = host,
    snap = snap,
    live = live,
    nowS = nowS,
    send = send,
    render = render,
    trackingStart = balanceInfo and balanceInfo.trackingStart,
    openEditor = openEditor,
    closeEditor = function()
      editor = nil
      render()
    end,
  }
end

-- The tab's content, and its estimated height on the Today tab (0 on the others).
local function tabContent(view: Widgets.View): (UiNode, number)
  if tab == "history" then
    if historyState.anchor == "" then
      historyState.anchor = view.snap.today.date
    end
    requestHistory(History.range(historyState))
    return History.render(view, historyState, history), 0
  elseif tab == "balance" then
    return BalanceView.render(view, balanceState, balanceInfo), 0
  end
  return today(view.snap, view.nowS)
end

-- Panel ----------------------------------------------------------------------------------

-- The host does not re-flow siblings, nor resize a scroll, when the tree's structure
-- changes in an open panel (a card removed, a session added). Keying the root by its
-- structure (node types, child counts and keys) makes it build a fresh tree then, while
-- per-second updates and typing keep the same key. The key is a counter bumped when the
-- structure differs from the last render: every node's path includes it, so it stays
-- short, and Luau compares interned strings in constant time.
local function structureOf(node: UiNode, out: { string })
  table.insert(out, node.type)
  local key = node.props and node.props.key
  if key then
    table.insert(out, "#" .. tostring(key))
  end
  if node.props and node.props.visible == false then
    table.insert(out, "!")
  end
  local children = node.children or {}
  if #children > 0 then
    table.insert(out, "(")
    for _, child in children do
      structureOf(child, out)
    end
    table.insert(out, ")")
  end
end

local lastStructure: string? = nil
local structureCount = 0

local function structureKey(nodes: { UiNode }): string
  local out = {}
  for _, node in nodes do
    structureOf(node, out)
  end
  local structure = table.concat(out, " ")
  if structure ~= lastStructure then
    lastStructure = structure
    structureCount += 1
  end
  return tostring(structureCount)
end

function render()
  if not snapshot then
    panel.render(ui.column({ align = "center", gap = 8, padding = 24 }, {
      ui.glyph({ name = "briefcase-off", size = 32, color = "on_surface_variant" }),
      ui.label({ text = host.tr("panel.waiting"), color = "on_surface_variant" }),
    }))
    return
  end
  local snap = snapshot
  local nowMs = host.nowMs()
  local nowS = nowMs // 1000
  local live = Model.live(snap, nowMs)
  local view = viewOf(snap, live, nowS)

  local children = { header(snap, live, nowS), tabBar() }
  if commandError then
    table.insert(children, ui.label({ text = commandError, color = "error", fontSize = 12, maxLines = 2 }))
  end

  -- A page (the day editor, a balance form, the automation details) replaces the body;
  -- otherwise the cards, the hero and the tab, with the tiles on Today. Both are laid out
  -- to fit the panel: the scroll only takes over with unusual content (many sessions).
  local body
  if detailsOpen then
    body = automationDetails(snap)
  elseif editor then
    local day = historyDay(editor.date)
    if not day then
      local monday = Time.weekStart(editor.date)
      requestHistory(monday, Time.addDays(monday, 6))
    end
    body = Editor.render(view, editor, day)
  elseif tab == "balance" and balanceState.page then
    body = BalanceView.page(view, balanceState, balanceInfo)
  else
    body = attentionCards(snap, nowS)
    local content, contentHeight = tabContent(view)
    -- The full hero is for the Today tab, when it fits: the cards, the tiles and the
    -- sessions come first. The welcome card is tall: the compact hero leaves it room.
    local room = BODY_HEIGHT - cardsHeight(body) - (HERO_HEIGHT + BODY_GAP) - (TILES_HEIGHT + BODY_GAP) - contentHeight
    if commandError then
      room -= ERROR_HEIGHT
    end
    local full = tab == "today" and not snap.flags.firstRun and room >= 0
    if snap.flags.firstRun then
      table.insert(body, welcomeCard(snap))
    end
    table.insert(body, if full then hero(snap, live) else compactHero(snap, live))
    if tab == "today" then
      table.insert(body, tiles(snap, live))
    end
    table.insert(body, content)
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 12 }, body))
  table.insert(children, ui.separator({}))
  table.insert(children, footer(snap))

  panel.render(ui.column({ key = structureKey(children), gap = 12, flexGrow = 1 }, children))
end

host.state.watch("shift.snapshot", function(value)
  snapshot = value
  if isOpen then
    render()
  end
end)

host.state.watch("shift.history", function(value)
  history = value
  if isOpen then
    render()
  end
end)

host.state.watch("shift.balance", function(value)
  balanceInfo = value
  if isOpen then
    render()
  end
end)

function onOpen()
  isOpen = true
  -- Each open starts on Today, where the check-in button is.
  tab = "today"
  requested = nil -- the core may have restarted since the last request
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
  commandError = nil
  detailsOpen = false
  editor = nil
  balanceState.page = nil
end

function update()
  sender.tick()
  if isOpen then
    render()
  end
end

function onKey(chord, pressed)
  if chord == "ctrl+z" and pressed and snapshot and snapshot.undo then
    send({ type = "undo", id = snapshot.undo.id })
  end
end
