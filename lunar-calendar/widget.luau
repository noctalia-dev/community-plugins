--!nonstrict
-- [[widget]] calendar - bar widget showing the Gregorian date, the weekday, the
-- Chinese lunar date, solar terms, traditional festivals and (when the online
-- holiday data is available) statutory holidays.
--
-- Left click  : toggle the full month panel (cwhirly/lunar-calendar:panel)
-- Right click : copy today's full description to the clipboard
-- Middle click: the host's built-in "open this widget's settings" binding
--
-- IPC: noctalia msg plugin cwhirly/lunar-calendar:calendar focused refresh

local lunar = require("./lib/lunar.luau")
local fmt = require("./lib/format.luau")
local holiday = require("./lib/holiday.luau")
local plugin = require("./lib/plugin.luau")

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

local showGlyph = config("show_glyph", true) ~= false
local glyph = config("glyph", "calendar-event")
local primaryMode = config("primary", "solar")
local secondaryMode = config("secondary", "lunar_plus")
local showWeekday = config("show_weekday", true) ~= false

local holidayDays = {}
local holidayStatus = "loading"

local COLOR_BY_KIND = {
    term = "primary",
    lunar = "tertiary",
    solar = "secondary",
}

-- ---------------------------------------------------------------------------
-- Data assembly
-- ---------------------------------------------------------------------------

local function now_date()
    local t = os.date("*t")
    return t.year, t.month, t.day
end

local function describe(year, month, day)
    local number = lunar.days_from_civil(year, month, day)
    return {
        y = year,
        m = month,
        d = day,
        number = number,
        weekday = lunar.weekday_from_days(number),
        lunar = lunar.solar_to_lunar(year, month, day),
        term = lunar.solar_term(year, month, day),
        festivals = lunar.festivals(year, month, day),
        holiday = holidayDays[fmt.date_key(year, month, day)],
    }
end

local function lunar_text(info)
    if not info.lunar then
        return nil
    end
    return fmt.lunar_month_day(info.lunar.month, info.lunar.day, info.lunar.is_leap)
end

local function primary_text(info)
    if primaryMode == "lunar" then
        return lunar_text(info) or fmt.solar_month_day(info.m, info.d)
    end
    local text = fmt.solar_month_day(info.m, info.d)
    if showWeekday then
        text = text .. " " .. fmt.weekday_short(info.weekday)
    end
    if primaryMode == "both" then
        local extra = lunar_text(info)
        if extra then
            text = text .. " " .. extra
        end
    end
    return text
end

--- Up to two secondary labels: the lunar date and/or the notable event.
local function secondary_labels(info)
    if secondaryMode == "none" then
        return {}
    end

    local lunar_label
    local text = lunar_text(info)
    if text then
        lunar_label = { text = text, color = "on_surface_variant" }
    end

    local event
    if info.holiday then
        if info.holiday.off then
            event = { text = info.holiday.name, color = "error" }
        else
            event = { text = noctalia.tr("widget.workday_short"), color = "on_surface_variant" }
        end
    elseif info.festivals[1] then
        local first = info.festivals[1]
        event = { text = first.name, color = COLOR_BY_KIND[first.kind] or "on_surface_variant" }
    end

    if secondaryMode == "lunar" then
        return lunar_label and { lunar_label } or {}
    end
    if secondaryMode == "auto" then
        if event then
            return { event }
        end
        return lunar_label and { lunar_label } or {}
    end
    -- "lunar_plus": always the lunar date, with the event appended when there is one.
    local out = {}
    if lunar_label then
        out[#out + 1] = lunar_label
    end
    if event then
        if lunar_label and event.text == lunar_label.text then
            -- e.g. 正月初一 is already 春节; keep just the lunar label.
            out[1] = event
        else
            out[#out + 1] = event
        end
    end
    return out
end

--- One-line description used by the clipboard/IPC actions.
local function full_line(info)
    local parts = { fmt.solar_ymd(info.y, info.m, info.d) .. " " .. fmt.weekday(info.weekday) }
    local text = lunar_text(info)
    if text then
        parts[#parts + 1] = noctalia.tr("widget.lunar") .. text
    end
    if info.lunar then
        parts[#parts + 1] = info.lunar.ganzhi_year .. info.lunar.zodiac .. "年"
    end
    if info.term then
        parts[#parts + 1] = info.term
    end
    for _, festival in ipairs(info.festivals) do
        parts[#parts + 1] = festival.name
    end
    if info.holiday then
        parts[#parts + 1] = info.holiday.off
            and (info.holiday.name .. " " .. noctalia.tr("widget.on_leave"))
            or (info.holiday.name .. " " .. noctalia.tr("widget.working"))
    end
    return table.concat(parts, " · ")
end

local function tooltip_rows(info)
    local rows = {
        {
            key = noctalia.tr("widget.gregorian"),
            value = fmt.solar_ymd(info.y, info.m, info.d) .. " " .. fmt.weekday(info.weekday),
        },
    }
    local text = lunar_text(info)
    if text and info.lunar then
        rows[#rows + 1] = { key = noctalia.tr("widget.lunar"), value = text }
        rows[#rows + 1] = {
            key = noctalia.tr("widget.ganzhi"),
            value = string.format(
                "%s年 %s日 · %s年",
                info.lunar.ganzhi_year,
                lunar.ganzhi_day(info.number),
                info.lunar.zodiac
            ),
        }
    end
    if info.term then
        rows[#rows + 1] = { key = noctalia.tr("widget.term"), value = info.term }
    end
    local upcoming = lunar.next_solar_term(info.y, info.m, info.d)
    if upcoming then
        rows[#rows + 1] = {
            key = noctalia.tr("widget.next_term"),
            value = string.format(
                "%s %d月%d日 · %s",
                upcoming.name,
                upcoming.month,
                upcoming.day,
                fmt.days_phrase(upcoming.in_days)
            ),
        }
    end
    -- The 节气 row above already carries the day's term, so only list festivals.
    local festival_names = {}
    for _, festival in ipairs(lunar.festival_list(info.y, info.m, info.d)) do
        festival_names[#festival_names + 1] = festival.name
    end
    if #festival_names > 0 then
        rows[#rows + 1] = { key = noctalia.tr("widget.festival"), value = table.concat(festival_names, " · ") }
    end
    if info.holiday then
        rows[#rows + 1] = {
            key = info.holiday.off and noctalia.tr("widget.holiday") or noctalia.tr("widget.workday"),
            value = info.holiday.off
                and (info.holiday.name .. " " .. noctalia.tr("widget.on_leave"))
                or (info.holiday.name .. " " .. noctalia.tr("widget.working")),
        }
    end
    local next_off = holiday.next_off(holidayDays, info.number)
    if next_off then
        local year, month, day = lunar.civil_from_days(next_off.day_number)
        rows[#rows + 1] = {
            key = noctalia.tr("widget.next_holiday"),
            value = string.format("%s %d月%d日 · %s", next_off.name, month, day, fmt.days_phrase(next_off.in_days)),
        }
    end
    if holidayStatus == "loading" then
        rows[#rows + 1] = { key = noctalia.tr("widget.holidays"), value = noctalia.tr("widget.loading") }
    elseif holidayStatus == "offline" then
        rows[#rows + 1] = { key = noctalia.tr("widget.holidays"), value = noctalia.tr("widget.offline") }
    elseif holidayStatus == "disabled" then
        rows[#rows + 1] = { key = noctalia.tr("widget.holidays"), value = noctalia.tr("widget.disabled") }
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function render()
    local year, month, day = now_date()
    local info = describe(year, month, day)

    local labels = secondary_labels(info)
    local nodes = {}
    if showGlyph and glyph ~= "" then
        nodes[#nodes + 1] = ui.glyph({ name = glyph, size = 14 })
    end

    if barWidget.isVertical() then
        -- A side bar clips the capsule to the bar thickness, so stay one
        -- control tall and fold everything into a single label.
        local pieces = {}
        for _, label in ipairs(labels) do
            pieces[#pieces + 1] = label.text
        end
        nodes[#nodes + 1] = ui.label({ text = (#pieces > 0) and table.concat(pieces, " ") or tostring(day) })
        barWidget.render(ui.column({ gap = 2, align = "center" }, nodes))
    else
        nodes[#nodes + 1] = ui.label({ text = primary_text(info), fontWeight = "medium" })
        for _, label in ipairs(labels) do
            nodes[#nodes + 1] = ui.label({ text = label.text, color = label.color })
        end
        barWidget.render(ui.row({ gap = 6, align = "center" }, nodes))
    end

    barWidget.setTooltip(tooltip_rows(info))
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function apply_holidays(value)
    if type(value) ~= "table" then
        return
    end
    holidayDays = type(value.days) == "table" and value.days or {}
    holidayStatus = value.status or "ok"
end

apply_holidays(noctalia.state.get("holidays"))

noctalia.state.watch("holidays", function(value)
    apply_holidays(value)
    render()
end)

render()

function update()
    noctalia.setUpdateInterval(60000)
    render()
end

function onClick()
    noctalia.togglePanel(plugin.panel)
end

function onRightClick()
    local year, month, day = now_date()
    local text = full_line(describe(year, month, day))
    noctalia.copyToClipboard(text, "text/plain")
    noctalia.notify(noctalia.tr("notify.title"), text)
end

function onIpc(event, _payload)
    if event == "refresh" then
        -- Milliseconds, so two refreshes in the same second are still different
        -- values and the service's watcher fires again.
        noctalia.state.set("holiday-command", { action = "refresh", at = noctalia.nowMs() })
        noctalia.notify(noctalia.tr("notify.title"), noctalia.tr("widget.refreshing"))
    elseif event == "copy" then
        onRightClick()
    elseif event == "settings" then
        noctalia.openSettings()
    else
        render()
    end
end
