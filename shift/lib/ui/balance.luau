--!nonstrict
-- Balance tab (spec §6.6, §7.4.5): the settled balance and its breakdown, the latest
-- adjustments, and the tracking start and initial balance. Adding an adjustment, the full
-- ledger and the tracking settings are pages that replace the panel body; the tracking
-- settings ask for confirmation since they change the balance.

local Format = require("../format.luau")
local Time = require("../time.luau")
local Types = require("../types.luau")
local Widgets = require("./widgets.luau")

type View = Widgets.View
type Adjustment = Types.Adjustment

type BalanceInfo = Types.BalanceInfo

export type BalancePage = "add" | "all" | "settings"

export type BalanceState = {
  page: BalancePage?, -- nil: the tab
  listPage: number, -- page of the full ledger, from 1
  amount: string,
  note: string,
  date: string?, -- nil: today
  form: number, -- bumped to clear the form's inputs
  trackingStart: string?, -- edits not saved yet; nil: unchanged
  initial: string?,
  confirm: boolean,
}

local Balance = {}

local MINUTE_MS = 60000
-- Adjustments on the tab, and per page of the full ledger.
local LATEST = 3
local PAGE_SIZE = 8
local ROW_HEIGHT = 28

function Balance.new(): BalanceState
  return { page = nil, listPage = 1, amount = "", note = "", date = nil, form = 1, trackingStart = nil, initial = nil, confirm = false }
end

local function open(view: View, state: BalanceState, page: BalancePage?)
  state.page = page
  view.render()
end

local function signedColor(ms: number): string?
  return ms >= MINUTE_MS and "tertiary" or nil
end

local function breakdown(view: View, info: BalanceInfo): UiNode
  local host, fmt = view.host, view.snap.display.durationFormat
  local today = view.live.workedMs - view.live.targetMs
  return ui.column({ gap = 4, align = "center" }, {
    ui.label({ text = Format.signed(info.settledMs, fmt), fontSize = 32, fontWeight = "bold", color = signedColor(info.settledMs) }),
    ui.label({ text = host.tr("panel.balance.today", { delta = Format.signed(today, fmt) }), fontSize = 13, color = "on_surface_variant" }),
    ui.label({
      text = host.tr("panel.balance.breakdown", {
        initial = Format.signed(info.initialMs, fmt),
        days = Format.signed(info.deltaMs, fmt),
        adjustments = Format.signed(info.adjustmentsMs, fmt),
      }),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 2,
      textAlign = "center",
    }),
  })
end

-- Most recent first.
local function sorted(info: BalanceInfo): { Adjustment }
  local list = table.clone(info.adjustments)
  table.sort(list, function(a, b)
    return a.date > b.date or (a.date == b.date and a.id > b.id)
  end)
  return list
end

local function adjustmentRow(view: View, adjustment: Adjustment): UiNode
  local host, fmt = view.host, view.snap.display.durationFormat
  local ms = adjustment.minutes * MINUTE_MS
  return ui.row({ key = "adjustment:" .. adjustment.id, align = "center", gap = 8, height = ROW_HEIGHT }, {
    ui.label({ text = Widgets.date(host, adjustment.date, "%d %b %Y"), fontSize = 13, color = "on_surface_variant", width = 92 }),
    ui.label({ text = Format.signed(ms, fmt), fontWeight = "bold", width = 64, color = signedColor(ms) }),
    ui.label({ text = adjustment.note, flexGrow = 1, maxLines = 1, fontSize = 13 }),
    ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      tooltip = host.tr("panel.balance.delete"),
      onClick = function()
        view.send({ type = "adjust.remove", id = adjustment.id })
      end,
    }),
  })
end

-- The tab's latest adjustments, with the way to the others.
local function latest(view: View, state: BalanceState, info: BalanceInfo): UiNode
  local host = view.host
  local list = sorted(info)
  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = host.tr("panel.balance.adjustments"), fontWeight = "medium", flexGrow = 1 }),
      ui.button({
        text = host.tr("panel.balance.add"),
        glyph = "plus",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          open(view, state, "add")
        end,
      }),
    }),
  }
  for index = 1, math.min(LATEST, #list) do
    table.insert(rows, adjustmentRow(view, list[index]))
  end
  if #list == 0 then
    table.insert(rows, ui.label({ text = host.tr("panel.balance.no_adjustments"), fontSize = 12, color = "on_surface_variant" }))
  elseif #list > LATEST then
    table.insert(rows, ui.row({}, {
      Widgets.smallButton(host.tr("panel.balance.show_all", { count = #list }), "ghost", function()
        state.listPage = 1
        open(view, state, "all")
      end),
    }))
  end
  return ui.column({ gap = 2 }, rows)
end

-- "Tracking since 5 Oct 2026 · initial +0:30", with a button to the tracking settings.
local function trackingRow(view: View, state: BalanceState, info: BalanceInfo): UiNode
  local host = view.host
  local text = host.tr("panel.balance.tracking_summary", {
    date = Widgets.date(host, info.trackingStart, "%d %b %Y"),
    initial = Format.signed(info.initialBalanceMin * MINUTE_MS, view.snap.display.durationFormat),
  })
  return ui.row({ align = "center", gap = 8, paddingH = 10, paddingV = 6, radius = 12, fill = "surface_variant" }, {
    ui.glyph({ name = "calendar-cog", size = 14, color = "on_surface_variant" }),
    ui.label({ text = text, flexGrow = 1, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    Widgets.editButton(host.tr("panel.balance.edit_tracking"), function()
      open(view, state, "settings")
    end),
  })
end

local function addPage(view: View, state: BalanceState): { UiNode }
  local host = view.host
  local today = view.snap.today.date
  local minutes = Time.parseDuration(state.amount)
  local valid = minutes ~= nil and minutes ~= 0
  local error = (state.amount ~= "" and not valid) and host.tr("panel.balance.invalid_amount") or ""
  -- Back and Cancel both drop the draft, like the tracking settings.
  local function close()
    state.amount, state.note, state.date = "", "", nil
    state.form += 1
    open(view, state, nil)
  end
  return {
    Widgets.pageHeader(host, host.tr("panel.balance.add_title"), close),
    ui.label({ text = host.tr("panel.balance.add_hint"), fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "amount:" .. state.form,
        value = state.amount,
        placeholder = host.tr("panel.balance.amount_placeholder"),
        width = 96,
        controlSize = "sm",
        onChange = function(value)
          state.amount = value
          view.render()
        end,
      }),
      ui.input({
        key = "note:" .. state.form,
        value = state.note,
        placeholder = host.tr("panel.balance.note_placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = function(value)
          state.note = value
        end,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = host.tr("panel.balance.date"), flexGrow = 1 }),
      Widgets.dateStepper(host, state.date or today, function(date)
        state.date = date
        view.render()
      end),
    }),
    ui.label({ text = error, color = "error", fontSize = 12 }),
    ui.row({ gap = 8, justify = "end" }, {
      Widgets.smallButton(host.tr("panel.day.cancel"), "ghost", close),
      Widgets.smallButton(host.tr("panel.balance.add"), "primary", function()
        if not valid then
          return
        end
        view.send({
          type = "adjust.add",
          id = string.format("j_%x%04x", host.nowMs(), math.random(0, 0xffff)),
          date = state.date or today,
          minutes = minutes,
          note = state.note,
        })
        close()
      end, valid),
    }),
  }
end

-- Every adjustment, a page at a time.
local function allPage(view: View, state: BalanceState, info: BalanceInfo): { UiNode }
  local host = view.host
  local list = sorted(info)
  local pages = math.max(1, math.ceil(#list / PAGE_SIZE))
  state.listPage = math.clamp(state.listPage, 1, pages)
  local children = {
    Widgets.pageHeader(host, host.tr("panel.balance.adjustments"), function()
      open(view, state, nil)
    end),
  }
  local rows = {}
  local first = (state.listPage - 1) * PAGE_SIZE + 1
  for index = first, math.min(#list, first + PAGE_SIZE - 1) do
    table.insert(rows, adjustmentRow(view, list[index]))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = host.tr("panel.balance.no_adjustments"), fontSize = 12, color = "on_surface_variant" }))
  end
  table.insert(children, ui.column({ gap = 2 }, rows))
  if pages > 1 then
    local function step(delta: number, glyph: string, enabled: boolean, tooltip: string): UiNode
      return ui.button({
        glyph = glyph,
        tooltip = tooltip,
        variant = "ghost",
        controlSize = "sm",
        enabled = enabled,
        onClick = function()
          state.listPage += delta
          view.render()
        end,
      })
    end
    table.insert(children, ui.row({ align = "center", justify = "center", gap = 8 }, {
      step(-1, "chevron-left", state.listPage > 1, host.tr("panel.balance.previous_page")),
      ui.label({ text = host.tr("panel.balance.page", { page = state.listPage, pages = pages }), fontSize = 12, color = "on_surface_variant" }),
      step(1, "chevron-right", state.listPage < pages, host.tr("panel.balance.next_page")),
    }))
  end
  return children
end

local function settingsPage(view: View, state: BalanceState, info: BalanceInfo): { UiNode }
  local host = view.host
  local today = view.snap.today.date
  local trackingStart = state.trackingStart or info.trackingStart
  local initialText = state.initial or Format.signed(info.initialBalanceMin * MINUTE_MS, "colon")
  local initial = Time.parseDuration(initialText)
  local changed = trackingStart ~= info.trackingStart or (initial ~= nil and initial ~= info.initialBalanceMin)
  local message, color = "", "error"
  if initial == nil then
    message = host.tr("panel.balance.invalid_amount")
  elseif state.confirm then
    message = host.tr(trackingStart < info.trackingStart and "panel.balance.confirm_earlier" or "panel.balance.confirm")
    color = "secondary"
  end
  local function back()
    state.trackingStart, state.initial, state.confirm = nil, nil, false
    state.form += 1
    open(view, state, nil)
  end
  return {
    Widgets.pageHeader(host, host.tr("panel.balance.settings"), back),
    ui.label({ text = host.tr("panel.balance.settings_hint"), fontSize = 12, color = "on_surface_variant", maxLines = 3 }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = host.tr("panel.balance.tracking_since"), flexGrow = 1 }),
      Widgets.dateStepper(host, trackingStart, function(date)
        state.trackingStart = date
        state.confirm = false
        view.render()
      end, nil, today),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = host.tr("panel.balance.initial"), flexGrow = 1 }),
      ui.input({
        key = "initial:" .. state.form,
        value = initialText,
        width = 96,
        controlSize = "sm",
        onChange = function(value)
          state.initial = value
          state.confirm = false
          view.render()
        end,
      }),
    }),
    ui.label({ text = message, color = color, fontSize = 12, maxLines = 3 }),
    ui.row({ gap = 8, justify = "end" }, {
      Widgets.smallButton(host.tr("panel.day.cancel"), "ghost", back),
      Widgets.smallButton(host.tr(state.confirm and "panel.day.confirm" or "panel.day.save"), "primary", function()
        if not state.confirm then
          state.confirm = true
          view.render()
          return
        end
        view.send({ type = "balance.meta", trackingStart = trackingStart, initialBalanceMin = initial })
        back()
      end, changed and initial ~= nil),
    }),
  }
end

local function loading(view: View): UiNode
  return ui.label({ text = view.host.tr("panel.history.loading"), color = "on_surface_variant", fontSize = 12 })
end

-- The tab's content; `info` is the latest `shift.balance` value, nil before the first.
function Balance.render(view: View, state: BalanceState, info: BalanceInfo?): UiNode
  if not info then
    return loading(view)
  end
  return ui.column({ gap = 12 }, { breakdown(view, info), latest(view, state, info), trackingRow(view, state, info) })
end

-- The open page, replacing the panel body.
function Balance.page(view: View, state: BalanceState, info: BalanceInfo?): { UiNode }
  if not info then
    return {
      Widgets.pageHeader(view.host, view.host.tr("panel.balance.adjustments"), function()
        open(view, state, nil)
      end),
      loading(view),
    }
  elseif state.page == "add" then
    return addPage(view, state)
  elseif state.page == "all" then
    return allPage(view, state, info)
  end
  return settingsPage(view, state, info)
end

return Balance
