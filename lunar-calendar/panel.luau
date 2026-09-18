--!nonstrict
-- [[panel]] panel - a month calendar with the Gregorian grid, the Chinese lunar
-- day in every cell, the 24 solar terms, traditional festivals and the online
-- statutory-holiday data (休 / 班).
--
-- Open it with: noctalia msg panel-toggle cwhirly/lunar-calendar:panel
-- Or by left-clicking the bar widget.

local lunar = require("./lib/lunar.luau")
local fmt = require("./lib/format.luau")
local holiday = require("./lib/holiday.luau")

-- Weekday names, date titles and countdowns follow the shell language; the
-- calendar's own vocabulary stays Chinese whatever the locale is.
local locale = require("./lib/locale.luau")
fmt.set_locale(locale.chinese() and "zh" or "en")

local function config(key, fallback)
    local value = noctalia.getConfig(key)
    if value == nil then
        return fallback
    end
    return value
end

local WEEK_STARTS = { monday = 1, sunday = 7, saturday = 6 }
local weekStart = WEEK_STARTS[config("week_start", "monday")] or 1

local CELL_W = 52
local CELL_H = 52
local CELL_GAP = 2
local WEEKDAY_H = 18

-- Fully transparent, for props that must be present in every render but should
-- draw nothing.
local NONE = "#00000000"
local COLOR_BY_KIND = { term = "primary", lunar = "tertiary", solar = "secondary" }

local viewYear, viewMonth
local today
local selected
local holidayDays = {}
local holidayStatus = "loading"
local ready = false
local render

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function today_parts()
    local t = os.date("*t")
    return {
        y = t.year,
        m = t.month,
        d = t.day,
        number = lunar.days_from_civil(t.year, t.month, t.day),
    }
end

-- Literal translation keys, so the manifest validator can check every one of
-- them against translations/ (a key built by concatenation would hide from it).
local STATUS_KEYS = {
    ok = "status.ok",
    cached = "status.cached",
    offline = "status.offline",
    disabled = "status.disabled",
    loading = "status.loading",
    nodata = "status.nodata",
}

local function status_text()
    return noctalia.tr(STATUS_KEYS[holidayStatus] or "status.loading")
end

-- ---------------------------------------------------------------------------
-- Cell rendering
-- ---------------------------------------------------------------------------

--- Small label under the day number, plus its colour.
local function cell_sub(cell, monthHolidays)
    if not cell.in_month then
        return cell.lunar and fmt.lunar_day(cell.lunar.day) or "", "on_surface_variant"
    end
    local entry = monthHolidays[cell.d]
    if entry then
        if entry.off then
            return entry.name, "error"
        end
        return noctalia.tr("panel.work"), "on_surface_variant"
    end
    if cell.term then
        return cell.term, "primary"
    end
    for _, festival in ipairs(cell.festivals) do
        if festival.kind == "lunar" then
            return festival.name, "tertiary"
        end
    end
    for _, festival in ipairs(cell.festivals) do
        if festival.kind == "solar" then
            return festival.name, "secondary"
        end
    end
    if cell.lunar then
        if cell.lunar.day == 1 then
            return fmt.lunar_month(cell.lunar.month), "on_surface_variant"
        end
        return fmt.lunar_day(cell.lunar.day), "on_surface_variant"
    end
    return "", "on_surface_variant"
end

local function cell_node(cell, monthHolidays)
    local sub, subColor = cell_sub(cell, monthHolidays)
    local isToday = today and cell.day_number == today.number
    local isSelected = cell.day_number == selected

    local dayColor = "on_surface"
    if not cell.in_month or cell.weekday >= 6 then
        dayColor = "on_surface_variant"
    end
    if isToday then
        dayColor = "primary"
    end

    local children = {
        ui.label({
            text = tostring(cell.d),
            fontSize = 15,
            fontWeight = (isToday or isSelected) and "bold" or "medium",
            color = dayColor,
        }),
    }
    if sub ~= "" then
        children[#children + 1] = ui.label({
            text = sub,
            fontSize = 9,
            color = subColor,
            maxWidth = CELL_W - 2,
            maxLines = 1,
            textAlign = "center",
        })
    end

    -- Every state-dependent prop is sent on *every* render, including the
    -- "nothing to draw" case: the host's declarative reconciler only applies the
    -- props a render contains, so a prop that is dropped keeps its previous
    -- value on the retained native control (a selection border that never goes
    -- away). NONE is a fully transparent hex colour.
    local fill = NONE
    if isToday then
        fill = "primary/0.18"
    elseif isSelected then
        fill = "secondary/0.22"
    end

    return ui.column({
        key = fmt.date_key(cell.y, cell.m, cell.d),
        width = CELL_W,
        height = CELL_H,
        gap = 1,
        radius = 8,
        align = "center",
        justify = "center",
        fill = fill,
        border = isSelected and "primary" or NONE,
        borderWidth = isSelected and 1 or 0,
        opacity = cell.in_month and 1 or 0.4,
        onClick = function()
            if not cell.in_month then
                -- Step into the neighbouring month so the details match the grid.
                viewYear, viewMonth = cell.y, cell.m
            end
            selected = cell.day_number
            render()
        end,
    }, children)
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

local function shift_months(delta)
    local index = viewYear * 12 + (viewMonth - 1) + delta
    local year = math.floor(index / 12)
    local month = index % 12 + 1
    if year < lunar.MIN_YEAR then
        year, month = lunar.MIN_YEAR, 1
    elseif year > lunar.MAX_YEAR then
        year, month = lunar.MAX_YEAR, 12
    end
    viewYear, viewMonth = year, month
    render()
end

local function goto_today()
    today = today_parts()
    viewYear, viewMonth = today.y, today.m
    selected = today.number
    render()
end

local function header()
    return ui.row({ align = "center", gap = 4 }, {
        ui.label({
            text = fmt.month_title(viewYear, viewMonth),
            fontSize = 16,
            fontWeight = "bold",
            flexGrow = 1,
        }),
        ui.button({ glyph = "chevrons-left", variant = "ghost", tooltip = noctalia.tr("panel.prev_year"), onClick = function()
            shift_months(-12)
        end }),
        ui.button({ glyph = "chevron-left", variant = "ghost", tooltip = noctalia.tr("panel.prev_month"), onClick = function()
            shift_months(-1)
        end }),
        ui.button({ text = noctalia.tr("panel.today"), variant = "ghost", onClick = goto_today }),
        ui.button({ glyph = "chevron-right", variant = "ghost", tooltip = noctalia.tr("panel.next_month"), onClick = function()
            shift_months(1)
        end }),
        ui.button({ glyph = "chevrons-right", variant = "ghost", tooltip = noctalia.tr("panel.next_year"), onClick = function()
            shift_months(12)
        end }),
        ui.button({ glyph = "close", variant = "ghost", onClick = function()
            panel.close()
        end }),
    })
end

local function weekday_header()
    local nodes = {}
    for i = 0, 6 do
        local iso = ((weekStart - 1 + i) % 7) + 1
        -- A `ui.label` sizes itself to its text and ignores `width`, so each
        -- weekday glyph lives in the same fixed-width container the day cells
        -- use; that is what lines the header up with the columns below it.
        nodes[#nodes + 1] = ui.column({
            key = "weekday-" .. iso,
            width = CELL_W,
            height = WEEKDAY_H,
            align = "center",
            justify = "center",
        }, {
            ui.label({
                text = fmt.weekday_initial(iso),
                fontSize = 11,
                textAlign = "center",
                color = iso >= 6 and "error" or "on_surface_variant",
            }),
        })
    end
    return ui.row({ gap = CELL_GAP }, nodes)
end

local function grid()
    local cells = lunar.month_grid(viewYear, viewMonth, weekStart)
    local monthHolidays = holiday.for_month(holidayDays, viewYear, viewMonth)
    local rows = { weekday_header() }
    for i = 1, #cells, 7 do
        local nodes = {}
        for j = i, math.min(i + 6, #cells) do
            nodes[#nodes + 1] = cell_node(cells[j], monthHolidays)
        end
        rows[#rows + 1] = ui.row({ gap = CELL_GAP }, nodes)
    end
    return ui.column({ gap = CELL_GAP }, rows)
end

-- Detail rows are label/value pairs. `ui.label` ignores `width`, so a label
-- goes into a fixed-width column that keeps values aligned, and `share` makes a
-- pair take half of a two-column row.
local PAIR_LABEL_W = 44   -- 农历 / 干支 / 节气 / 节日
local ROW_LABEL_W = 56    -- 下个假期, wide enough to stay on one line

local function detail_cell(label, value, color, share, label_w)
    local props = { gap = 6, align = "start" }
    if share then
        props.flexGrow = 1
    end
    return ui.row(props, {
        ui.column({ width = label_w or PAIR_LABEL_W }, {
            ui.label({ text = label, fontSize = 12, color = "on_surface_variant" }),
        }),
        ui.label({
            text = value,
            fontSize = 12,
            color = color or "on_surface",
            flexGrow = 1,
            maxLines = 2,
        }),
    })
end

--- A full-width label/value row (its label gets the wider column).
local function detail_row(label, value, color)
    return detail_cell(label, value, color, false, ROW_LABEL_W)
end

--- Two label/value pairs side by side, which halves the block's height.
local function detail_pair(left_label, left_value, left_color, right_label, right_value, right_color)
    return ui.row({ gap = 14, align = "start" }, {
        detail_cell(left_label, left_value, left_color, true),
        detail_cell(right_label, right_value, right_color, true),
    })
end

--- Details for the selected day.
local function details()
    local number = selected or (today and today.number)
    if not number then
        return ui.label({ text = "" })
    end
    local year, month, day = lunar.civil_from_days(number)
    local weekday = lunar.weekday_from_days(number)
    local lunarDate = lunar.solar_to_lunar(year, month, day)
    local term = lunar.solar_term(year, month, day)
    local festivals = lunar.festival_list(year, month, day)
    local entry = holidayDays[fmt.date_key(year, month, day)]

    local rows = {}

    -- Headline: the Gregorian date, the weekday, the holiday-data state, and a
    -- 休 / 班 badge pushed to the right when the day has one.
    local headline = {
        ui.label({
            text = fmt.solar_ymd(year, month, day) .. " " .. fmt.weekday(weekday),
            fontSize = 15,
            fontWeight = "bold",
        }),
        ui.label({ text = status_text(), fontSize = 11, color = "on_surface_variant" }),
    }
    if entry then
        headline[#headline + 1] = ui.spacer({ flexGrow = 1 })
        headline[#headline + 1] = ui.label({
            text = entry.off
                and (entry.name .. " · " .. noctalia.tr("panel.off"))
                or (entry.name .. " · " .. noctalia.tr("panel.work")),
            fontSize = 12,
            color = entry.off and "error" or "on_surface_variant",
        })
    end
    rows[#rows + 1] = ui.row({ align = "center", gap = 8 }, headline)

    -- 节气 and 节日 always render a row so the block keeps a constant height;
    -- an empty field reads "none" instead of vanishing.
    local none = noctalia.tr("panel.none")
    local festival_names = {}
    for _, festival in ipairs(festivals) do
        festival_names[#festival_names + 1] = festival.name
    end
    local has_festivals = #festival_names > 0

    -- Lunar date, the sexagenary year with its zodiac, and the day's own
    -- sexagenary name - one aligned row each.
    if lunarDate then
        -- 干支 + 生肖 + 年 ("丙午马年"), never "丙午年马". Two pairs per row keep
        -- the block half as tall as one field per row would.
        rows[#rows + 1] = detail_pair(
            noctalia.tr("panel.lunar"),
            fmt.lunar_month_day(lunarDate.month, lunarDate.day, lunarDate.is_leap),
            nil,
            noctalia.tr("panel.ganzhi"),
            lunarDate.ganzhi_year .. lunarDate.zodiac .. "年 · " .. lunar.ganzhi_day(number) .. "日",
            nil
        )
    end

    rows[#rows + 1] = detail_pair(
        noctalia.tr("panel.term"),
        term or none,
        term and "primary" or "on_surface_variant",
        noctalia.tr("panel.festival"),
        has_festivals and table.concat(festival_names, " · ") or none,
        has_festivals and (COLOR_BY_KIND[festivals[1].kind] or "on_surface") or "on_surface_variant"
    )

    -- Only the next day off is listed: the grid already marks every holiday in
    -- the month, so a "this month" line would just repeat it.
    -- "none" when the data is loaded and there is nothing, "unknown" when the
    -- holiday data has not arrived - either way the row is present.
    local has_holiday_data = next(holidayDays) ~= nil

    local nextOff = holiday.next_off(holidayDays, today and today.number or number)
    local next_value, next_color
    if nextOff then
        local year2, month2, day2 = lunar.civil_from_days(nextOff.day_number)
        next_value = string.format(
            "%s %d月%d日 · %s",
            nextOff.name, month2, day2, fmt.days_phrase(nextOff.in_days)
        )
        next_color = "primary"
    else
        next_value = has_holiday_data and none or noctalia.tr("panel.unknown")
        next_color = "on_surface_variant"
    end
    rows[#rows + 1] = detail_row(noctalia.tr("panel.next_holiday"), next_value, next_color)

    return ui.column({ gap = 7 }, rows)
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

function render()
    if not ready then
        return
    end
    panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
        header(),
        grid(),
        ui.separator({ spacing = 2 }),
        details(),
    }))
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function onOpen(_context)
    ready = true
    goto_today()
end

-- Keep "today" honest when the panel is left open across midnight.
function update()
    local now = today_parts()
    if today and now.number ~= today.number then
        today = now
        render()
    end
end

noctalia.state.watch("holidays", function(value)
    if type(value) == "table" then
        holidayDays = type(value.days) == "table" and value.days or {}
        holidayStatus = value.status or "ok"
    end
    render()
end)

local initial = noctalia.state.get("holidays")
if type(initial) == "table" then
    holidayDays = type(initial.days) == "table" and initial.days or {}
    holidayStatus = initial.status or "ok"
end

function onIpc(event, _payload)
    if event == "refresh" then
        noctalia.state.set("holiday-command", { action = "refresh", at = os.time() })
        render()
    elseif event == "today" then
        goto_today()
    end
end
