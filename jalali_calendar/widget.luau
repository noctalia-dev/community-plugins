--!nonstrict
-- Bar widget: today's Jalali date. Clicking opens the calendar panel.

local host = require("./host.luau")
local calendar = require("./calendar.luau")
local fmt = require("./fmt.luau")
local jalali = require("./jalali.luau")

local opts = host.normalize({
  language = noctalia.getConfig("language"),
  digits = noctalia.getConfig("digits"),
  week_start = noctalia.getConfig("week_start"),
  show_hijri = noctalia.getConfig("show_hijri"),
  show_gregorian = noctalia.getConfig("show_gregorian"),
  show_holidays = noctalia.getConfig("show_holidays"),
  events_national = noctalia.getConfig("events_national"),
  events_ancient = noctalia.getConfig("events_ancient"),
  events_religious = noctalia.getConfig("events_religious"),
  events_afghan = noctalia.getConfig("events_afghan"),
  scale = noctalia.getConfig("scale"),
})
local template = noctalia.getConfig("format") or "{weekday} {day} {month}"
-- 0 means "inherit the bar's font size", which is what keeps the widget
-- consistent with its neighbours by default.
local fontSize = tonumber(noctalia.getConfig("font_size")) or 0
local showGlyph = noctalia.getConfig("show_glyph") ~= false
local glyph = noctalia.getConfig("glyph") or "calendar"

-- Bundled Vazirmatn. The bar's configured font frequently has no Persian
-- glyphs, which is what makes this worth forcing rather than inheriting.
local FONT = host.font()
if FONT ~= nil then
  barWidget.setFont(FONT)
end

local lastJDN = -1

local function render(today)
  opts.todayJDN = today.jdn

  local parts = {
    day = fmt.digits(today.jd, opts.digits),
    month = fmt.monthName(today.jm, opts.lang),
    year = fmt.digits(today.jy, opts.digits),
    weekday = fmt.weekdayName(jalali.dayOfWeek(today.jdn), opts.lang, false),
  }

  local text = fmt.formatTemplate(template, parts)

  if fontSize > 0 then
    -- An explicit size needs the declarative path: setText has no size of its
    -- own, so the tree replaces the built-in glyph/text row.
    local children = {}
    if showGlyph then
      table.insert(children, ui.glyph({ name = glyph, size = fontSize }))
    end
    table.insert(children, ui.label({ text = text, fontSize = fontSize, fontFamily = FONT }))
    barWidget.render(ui.row({ gap = math.max(2, math.floor(fontSize / 3)), align = "center" }, children))
  else
    if showGlyph then
      barWidget.setGlyph(glyph)
    end
    barWidget.setText(text)
  end

  local model = calendar.buildMonth(today.jy, today.jm, opts)
  local cell
  for _, week in model.weeks do
    for i = 1, 7 do
      if week[i] and week[i].jd == today.jd then
        cell = week[i]
      end
    end
  end

  local lines = { `{parts.weekday} {parts.day} {parts.month} {parts.year}` }
  if cell then
    if opts.showGregorian then
      table.insert(
        lines,
        `{fmt.text("gregorian", opts.lang)}: {cell.greg.y}-{cell.greg.m}-{cell.greg.d}`
      )
    end
    if opts.showHijri then
      table.insert(
        lines,
        `{fmt.text("hijri", opts.lang)}: {cell.hijri.y}-{cell.hijri.m}-{cell.hijri.d}`
      )
    end
    for _, title in host.occasionTitles(cell) do
      table.insert(lines, title)
    end
  end
  barWidget.setTooltip(table.concat(lines, "\n"))
end

function update()
  -- A minute tick is cheap; repainting only when the day actually rolls over
  -- keeps the bar from being rebuilt 1440 times a day.
  noctalia.setUpdateInterval(60000)
  local today = host.today()
  if today.jdn ~= lastJDN then
    lastJDN = today.jdn
    render(today)
  end
end

function onClick()
  noctalia.togglePanel(host.PANEL_ID)
end
