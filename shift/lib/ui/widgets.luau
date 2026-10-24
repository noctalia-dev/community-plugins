--!nonstrict
-- Small components shared by the dashboard views (spec §7.4): section titles, compact
-- buttons, page headers, status chips and a day stepper, plus the context every view
-- receives.

local Time = require("../time.luau")
local Types = require("../types.luau")

-- What a dashboard view needs from the panel.
export type View = {
  host: Types.Host,
  snap: Types.Snapshot,
  live: Types.Live,
  nowS: number,
  send: (cmd: { [string]: any }) -> (),
  render: () -> (),
  trackingStart: string?, -- from `shift.balance`, nil until it arrives
  openEditor: (dateKey: string) -> (),
  closeEditor: () -> (),
}

local Widgets = {}

local EDIT_SIZE = 24

function Widgets.sectionTitle(text: string): UiNode
  return ui.label({ text = text, fontWeight = "medium" })
end

function Widgets.smallButton(text: string, variant: string, onClick: () -> (), enabled: boolean?): UiNode
  return ui.button({ text = text, variant = variant, controlSize = "sm", onClick = onClick, enabled = enabled ~= false })
end

-- A small pencil button, for rows that open an editor.
function Widgets.editButton(tooltip: string, onClick: () -> ()): UiNode
  return ui.button({
    glyph = "pencil",
    glyphSize = 14,
    variant = "ghost",
    width = EDIT_SIZE,
    height = EDIT_SIZE,
    tooltip = tooltip,
    onClick = onClick,
  })
end

-- Title row of a page that replaces the panel body, with its back button.
function Widgets.pageHeader(host: Types.Host, title: string, onBack: () -> ()): UiNode
  return ui.row({ align = "center", gap = 4 }, {
    ui.button({
      glyph = "chevron-left",
      variant = "ghost",
      controlSize = "sm",
      tooltip = host.tr("panel.day.back"),
      onClick = onBack,
    }),
    ui.label({ text = title, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
  })
end

-- A rounded label with an optional glyph, for day statuses.
function Widgets.chip(text: string, glyph: string?, color: string?): UiNode
  local children = {}
  if glyph then
    table.insert(children, ui.glyph({ name = glyph, size = 12, color = color or "on_surface_variant" }))
  end
  table.insert(children, ui.label({ text = text, fontSize = 12, color = color }))
  return ui.row({ align = "center", gap = 4, paddingH = 8, paddingV = 2, radius = 999, fill = "surface_variant" }, children)
end

-- Noon on a date: formatting it never lands on the neighbouring day.
local function dateEpoch(dateKey: string): number
  local year, month, day = Time.parseDate(dateKey)
  return Time.localToEpoch(year :: number, month :: number, day :: number, 12, 0)
end

-- Formatted dates by pattern and date key: the history views format dozens per render.
-- They live as long as the entry, so a change of locale shows after a reload.
local formatted: { [string]: { [string]: string } } = {}

-- A date in a strftime pattern ("%a %d %b"), in the user's locale.
function Widgets.date(host: Types.Host, dateKey: string, pattern: string): string
  local byDate = formatted[pattern]
  if not byDate then
    byDate = {}
    formatted[pattern] = byDate
  end
  local text = byDate[dateKey]
  if not text then
    text = host.formatTime("{:" .. pattern .. "}", dateEpoch(dateKey))
    byDate[dateKey] = text
  end
  return text
end

-- ‹ date › stepper, one day per click, bounded by `min`/`max` when given.
function Widgets.dateStepper(host: Types.Host, dateKey: string, onChange: (dateKey: string) -> (), min: string?, max: string?): UiNode
  return ui.row({ align = "center", gap = 2 }, {
    ui.button({
      glyph = "chevron-left",
      variant = "ghost",
      controlSize = "sm",
      enabled = min == nil or dateKey > min,
      tooltip = host.tr("panel.date.previous"),
      onClick = function()
        onChange(Time.addDays(dateKey, -1))
      end,
    }),
    ui.label({ text = Widgets.date(host, dateKey, "%a %d %b %Y"), fontSize = 13, textAlign = "center", width = 120 }),
    ui.button({
      glyph = "chevron-right",
      variant = "ghost",
      controlSize = "sm",
      enabled = max == nil or dateKey < max,
      tooltip = host.tr("panel.date.next"),
      onClick = function()
        onChange(Time.addDays(dateKey, 1))
      end,
    }),
  })
end

return Widgets
