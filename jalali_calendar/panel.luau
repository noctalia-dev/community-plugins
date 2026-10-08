--!nonstrict
-- Calendar panel: a Jalali month grid with tri-calendar cells.
--
-- Cells arrive from calendar.buildMonth already ordered for the configured
-- direction, so nothing here branches on RTL.
--
-- Two host details shape this file:
--
--   * ui.box is a leaf node and takes no children, and neither ui.button nor
--     ui.input accepts a fontFamily -- only ui.label does. So every piece of
--     text, buttons included, is a ui.label inside a clickable ui.column.
--     Glyph-only buttons stay as real ui.buttons: a glyph is unaffected by the
--     text font, and that is also why the year picker is a grid rather than a
--     text field.
--   * The host retains native controls across renders and does not reset a
--     prop that goes from a value to nil. Selection borders and fills are
--     therefore always passed explicitly, transparent when off, rather than
--     omitted -- otherwise every day ever clicked keeps its border.
--
-- Panel size is host-owned and fixed in the manifest, so it cannot grow with
-- the scale setting. The grid and occasion list therefore sit inside a
-- ui.scroll: at large scales the content scrolls instead of being clipped.

local host = require("./host.luau")
local calendar = require("./calendar.luau")
local fmt = require("./fmt.luau")

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

-- Bundled Vazirmatn, or nil to inherit the host font if it could not load.
local FONT = host.font()
local SCALE = opts.scale or 1.0

-- Every size below is written at scale 1.0 and passed through sz().
local function sz(n: number): number
  return math.max(1, math.floor(n * SCALE + 0.5))
end

local CELL_HEIGHT = sz(48)

-- Passed wherever a border or fill is off, so the host overwrites the previous
-- value instead of keeping it.
local TRANSPARENT = "#00000000"

-- A translucent accent, so hovering anything clickable reads as interactive.
-- A palette role with alpha resolves live against the active theme.
local HOVER_FILL = "primary/0.18"

-- The Jalali conversion is only defined over this range.
local MIN_YEAR, MAX_YEAR = 1178, 1633
local YEARS_PER_PAGE = 12

local today = nil
local viewYear = 0
local viewMonth = 0
local selectedDay = nil
-- "days" is the month grid, "months" the month picker reached by clicking the
-- title, "years" the year picker reached by clicking the year. Reaching a
-- distant date is two clicks rather than a chevron marathon.
local mode = "days"
local yearAnchor = 0
-- Key of the node the pointer is over, or nil. Hover repaints the whole tree,
-- which is only affordable because the month model is cached below.
local hoveredKey = nil

-- Rebuilding the month model on every hover event would burn the host's
-- per-callback CPU budget, so it is memoised until the month or today changes.
local cachedModel = nil
local cachedKey = ""

local function currentModel()
  -- Every option buildMonth reads belongs in the key. Settings changes reload
  -- the VM in practice, so a stale entry is hard to provoke, but keying on
  -- only half the inputs is the kind of cache that eventually lies.
  local key = table.concat({
    viewYear,
    viewMonth,
    opts.todayJDN,
    tostring(opts.showHolidays),
    tostring(opts.showHijri),
    tostring(opts.showGregorian),
    opts.digits,
    opts.lang,
    opts.weekStart,
  }, ":")
  if cachedKey ~= key then
    cachedModel = calendar.buildMonth(viewYear, viewMonth, opts)
    cachedKey = key
  end
  return cachedModel
end

local render

local function label(props)
  props.fontFamily = FONT
  return ui.label(props)
end

-- A text button: a clickable column wrapping a label, so the text carries the
-- bundled font.
local function textButton(key: string, text: string, selected: boolean, onClick, grow: number?)
  local fill = TRANSPARENT
  if selected then
    fill = "primary"
  elseif hoveredKey == key then
    fill = HOVER_FILL
  end

  return ui.column({
    key = key,
    flexGrow = grow,
    justify = "center",
    paddingV = sz(7),
    paddingH = sz(10),
    radius = sz(6),
    fill = fill,
    onClick = onClick,
    onHover = "onHoverNode",
  }, {
    label({
      text = text,
      fontSize = sz(13),
      color = if selected then "on_primary" else "on_surface",
      textAlign = "center",
    }),
  })
end

local function cellNode(cell)
  if cell == nil then
    return ui.column({ flexGrow = 1, height = CELL_HEIGHT })
  end

  local key = `day-{cell.jd}`
  local fill, dayColor = TRANSPARENT, "on_surface"
  if cell.isToday then
    fill, dayColor = "primary", "on_primary"
  elseif cell.isHoliday or cell.isFriday then
    dayColor = "error"
  end
  if not cell.isToday and hoveredKey == key then
    fill = HOVER_FILL
  end

  local selected = cell.jd == selectedDay and not cell.isToday

  local children = {
    label({
      text = cell.label,
      fontSize = sz(17),
      fontWeight = if cell.isToday then "bold" else "normal",
      color = dayColor,
      textAlign = "center",
    }),
  }

  local secondary = {}
  if opts.showGregorian and cell.gregLabel ~= "" then
    table.insert(secondary, cell.gregLabel)
  end
  if opts.showHijri and cell.hijriLabel ~= "" then
    table.insert(secondary, cell.hijriLabel)
  end
  if #secondary > 0 then
    table.insert(children, label({
      text = table.concat(secondary, " · "),
      fontSize = sz(10),
      color = if cell.isToday then "on_primary" else "on_surface_variant",
      textAlign = "center",
    }))
  end

  return ui.column({
    key = key,
    flexGrow = 1,
    height = CELL_HEIGHT,
    gap = 0,
    justify = "center",
    radius = sz(9),
    fill = fill,
    border = if selected then "outline" else TRANSPARENT,
    borderWidth = 1,
    onClick = function()
      selectedDay = cell.jd
      render()
    end,
    onHover = "onHoverNode",
  }, children)
end

local function findCell(model, jd)
  if jd == nil then
    return nil
  end
  for _, week in model.weeks do
    for i = 1, 7 do
      if week[i] and week[i].jd == jd then
        return week[i]
      end
    end
  end
  return nil
end

local function occasionList(model)
  if not opts.showHolidays then
    return ui.spacer({ height = 1 })
  end

  local day = selectedDay
  if day == nil and viewYear == today.jy and viewMonth == today.jm then
    day = today.jd
  end

  local cell = findCell(model, day)
  if cell == nil then
    return ui.spacer({ height = 1 })
  end

  local rtl = opts.lang == "persian"

  local jalaliLabel = label({
    text = `{fmt.digits(cell.jd, opts.digits)} {fmt.monthName(viewMonth, opts.lang)} {fmt.digits(viewYear, opts.digits)}`,
    fontSize = sz(14),
    fontWeight = "medium",
    color = "on_surface",
  })

  -- The other two calendars, spelled out. The grid can only fit bare numbers,
  -- so this is the one place the reader gets a full Gregorian or Hijri date.
  --
  -- Each is its own label rather than one joined string: a single Persian
  -- string is laid out right to left, which silently reverses Gregorian and
  -- Hijri relative to the order they were written in. Separate labels in a row
  -- put them exactly where they are placed.
  local function secondary(text: string)
    return label({ text = text, fontSize = sz(11), color = "on_surface_variant" })
  end

  local alternates = {}
  if opts.showGregorian then
    table.insert(alternates, secondary(
      `{fmt.digits(cell.greg.d, opts.digits)} {fmt.gregorianMonthName(cell.greg.m, opts.lang)} {fmt.digits(cell.greg.y, opts.digits)}`
    ))
  end
  if opts.showHijri then
    table.insert(alternates, secondary(
      `{fmt.digits(cell.hijri.d, opts.digits)} {fmt.hijriMonthName(cell.hijri.m, opts.lang)} {fmt.digits(cell.hijri.y, opts.digits)}`
    ))
  end

  local header = jalaliLabel
  if #alternates > 0 then
    -- Laid out left to right: Jalali first so it sits hard against the left
    -- edge, then Gregorian, then Hijri. Latin mode is the mirror, so the row
    -- is reversed and packed right.
    local parts = { jalaliLabel }
    for _, node in alternates do
      table.insert(parts, node)
    end
    if not rtl then
      local reversed = {}
      for i = #parts, 1, -1 do
        table.insert(reversed, parts[i])
      end
      parts = reversed
    end

    header = ui.row({
      align = "center",
      justify = if rtl then "start" else "end",
      gap = sz(10),
    }, parts)
  end

  local children = { header }

  -- Titles hang off the edge the language reads from: right for Persian, left
  -- for Latin. Labels stretch to the full width, so this is textAlign rather
  -- than a justify on the column.
  local textAlign = if rtl then "end" else "start"

  if #cell.occasions == 0 then
    table.insert(children, label({
      text = fmt.text("no_occasion", opts.lang),
      color = "on_surface_variant",
      fontSize = sz(13),
      textAlign = textAlign,
    }))
  else
    for _, occasion in cell.occasions do
      table.insert(children, label({
        text = occasion.title,
        color = if occasion.holiday then "error" else "on_surface_variant",
        fontSize = sz(13),
        maxLines = 3,
        textAlign = textAlign,
      }))
    end
  end

  return ui.column({ gap = sz(4), align = "stretch" }, children)
end

-- Lays twelve entries out as three rows of four, mirrored for Persian so they
-- read right to left like the day grid.
local function pickerGrid(entries)
  local rows = {}
  for row = 0, 2 do
    local cells = {}
    for col = 1, 4 do
      local slot = if opts.lang == "persian" then 5 - col else col
      cells[slot] = entries[row * 4 + col]
    end
    table.insert(rows, ui.row({ gap = sz(4), align = "stretch" }, cells))
  end
  return ui.column({ gap = sz(4), align = "stretch" }, rows)
end

local function monthPicker()
  local entries = {}
  for jm = 1, 12 do
    entries[jm] = textButton(`mon-{jm}`, fmt.monthName(jm, opts.lang), jm == viewMonth, function()
      viewMonth = jm
      selectedDay = nil
      mode = "days"
      storeViewAndRender()
    end, 1)
  end
  return pickerGrid(entries)
end

local function yearPicker()
  local entries = {}
  for i = 0, YEARS_PER_PAGE - 1 do
    local year = yearAnchor + i
    if year >= MIN_YEAR and year <= MAX_YEAR then
      entries[i + 1] = textButton(`yr-{year}`, fmt.digits(year, opts.digits), year == viewYear, function()
        viewYear = year
        selectedDay = nil
        mode = "months"
        storeViewAndRender()
      end, 1)
    else
      entries[i + 1] = ui.column({ flexGrow = 1 })
    end
  end
  return pickerGrid(entries)
end

function render()
  local model = currentModel()

  local heading, prevAction, nextAction, onHeadingClick
  if mode == "years" then
    local last = math.min(yearAnchor + YEARS_PER_PAGE - 1, MAX_YEAR)
    heading = `{fmt.digits(yearAnchor, opts.digits)} - {fmt.digits(last, opts.digits)}`
    prevAction, nextAction = "onPrevYearPage", "onNextYearPage"
    onHeadingClick = "onToggleMode"
  elseif mode == "months" then
    heading = fmt.digits(viewYear, opts.digits)
    prevAction, nextAction = "onPrevYear", "onNextYear"
    onHeadingClick = "onOpenYears"
  else
    heading = model.title
    prevAction, nextAction = "onPrevMonth", "onNextMonth"
    onHeadingClick = "onToggleMode"
  end

  local titleRow = ui.row({ align = "center", justify = "space_between", gap = sz(6) }, {
    ui.button({ glyph = "chevron-left", variant = "ghost", onClick = prevAction }),
    ui.column({
      key = "heading",
      flexGrow = 1,
      paddingV = sz(4),
      radius = sz(6),
      fill = if hoveredKey == "heading" then HOVER_FILL else TRANSPARENT,
      onClick = onHeadingClick,
      onHover = "onHoverNode",
    }, {
      label({
        text = heading,
        fontSize = sz(17),
        fontWeight = "bold",
        color = "on_surface",
        textAlign = "center",
      }),
    }),
    ui.button({ glyph = "chevron-right", variant = "ghost", onClick = nextAction }),
  })

  local toolbar = ui.row({ align = "center", justify = "space_between", gap = sz(6) }, {
    textButton("today-btn", fmt.text("today", opts.lang), false, "onToday"),
    ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onClosePanel" }),
  })

  if mode ~= "days" then
    local body = if mode == "years" then yearPicker() else monthPicker()
    panel.render(ui.column({ flexGrow = 1, gap = sz(8), align = "stretch" }, {
      titleRow,
      toolbar,
      body,
      ui.spacer({ flexGrow = 1 }),
    }))
    return
  end

  local headerCells = {}
  for i = 1, 7 do
    table.insert(headerCells, label({
      text = model.weekdayHeaders[i] or "",
      fontSize = sz(12),
      color = "on_surface_variant",
      textAlign = "center",
      flexGrow = 1,
    }))
  end

  local weekRows = {}
  for _, week in model.weeks do
    local cells = {}
    for i = 1, 7 do
      table.insert(cells, cellNode(week[i]))
    end
    table.insert(weekRows, ui.row({ gap = sz(2), align = "stretch" }, cells))
  end

  panel.render(ui.column({ flexGrow = 1, gap = sz(8), align = "stretch" }, {
    titleRow,
    toolbar,
    ui.row({ gap = sz(2), align = "stretch" }, headerCells),
    -- The grid sits outside the scroll deliberately. When it shared one with
    -- the occasion list, selecting a day made the list overflow, the scrollbar
    -- appeared, and its width came out of the day columns -- the grid visibly
    -- squeezed on every first selection.
    ui.column({ gap = sz(2), align = "stretch" }, weekRows),
    ui.separator({}),
    ui.scroll({ flexGrow = 1, gap = sz(4), align = "stretch" }, { occasionList(model) }),
  }))
end

function storeViewAndRender()
  noctalia.state.set("view", `{viewYear}:{viewMonth}`)
  render()
end

function onOpen(_context)
  today = host.today()
  opts.todayJDN = today.jdn
  mode = "days"

  -- Resume the month the user was last looking at, so opening from the tile
  -- after browsing from the bar widget lands in the same place.
  local stored = noctalia.state.get("view")
  if type(stored) == "string" then
    local y, m = stored:match("^(%d+):(%d+)$")
    if y then
      viewYear, viewMonth = tonumber(y), tonumber(m)
    end
  end
  if viewYear == 0 then
    viewYear, viewMonth = today.jy, today.jm
  end
  render()
end


local function moveMonth(delta: number)
  viewYear, viewMonth = calendar.step(viewYear, viewMonth, delta)
  selectedDay = nil
  storeViewAndRender()
end

function onPrevMonth()
  moveMonth(-1)
end

function onNextMonth()
  moveMonth(1)
end

local function setYear(year: number)
  viewYear = math.max(MIN_YEAR, math.min(MAX_YEAR, year))
  selectedDay = nil
  storeViewAndRender()
end

function onPrevYear()
  setYear(viewYear - 1)
end

function onNextYear()
  setYear(viewYear + 1)
end

function onPrevYearPage()
  yearAnchor = math.max(MIN_YEAR, yearAnchor - YEARS_PER_PAGE)
  render()
end

function onNextYearPage()
  if yearAnchor + YEARS_PER_PAGE <= MAX_YEAR then
    yearAnchor += YEARS_PER_PAGE
  end
  render()
end

function onOpenYears()
  -- Align the page so the current year sits on it.
  yearAnchor = math.max(MIN_YEAR, viewYear - (viewYear % YEARS_PER_PAGE))
  mode = "years"
  render()
end

-- One handler for every hoverable node: the host reports only the innermost
-- one, and every "true" is matched by a "false".
function onHoverNode(state, key)
  local next_ = if state == "true" then key else nil
  if next_ == nil and hoveredKey ~= key then
    -- A leave for a node we already stopped tracking; ignore it.
    return
  end
  if hoveredKey == next_ then
    return
  end
  hoveredKey = next_
  render()
end

function onToggleMode()
  mode = if mode == "days" then "months" else "days"
  render()
end

function onToday()
  today = host.today()
  opts.todayJDN = today.jdn
  viewYear, viewMonth = today.jy, today.jm
  selectedDay = today.jd
  mode = "days"
  storeViewAndRender()
end

function onClosePanel()
  panel.close()
end
