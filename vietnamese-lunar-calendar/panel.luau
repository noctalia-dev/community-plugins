--!nonstrict
local lunar = require("./lunar.luau")
local store = require("./store.luau")

local WEEKDAYS = {
    noctalia.tr("weekdays.t2"), noctalia.tr("weekdays.t3"), noctalia.tr("weekdays.t4"),
    noctalia.tr("weekdays.t5"), noctalia.tr("weekdays.t6"), noctalia.tr("weekdays.t7"),
    noctalia.tr("weekdays.cn")
}
local MONTH_NAMES = {
    noctalia.tr("months.m1"), noctalia.tr("months.m2"), noctalia.tr("months.m3"), noctalia.tr("months.m4"),
    noctalia.tr("months.m5"), noctalia.tr("months.m6"), noctalia.tr("months.m7"), noctalia.tr("months.m8"),
    noctalia.tr("months.m9"), noctalia.tr("months.m10"), noctalia.tr("months.m11"), noctalia.tr("months.m12")
}

local viewMonth = tonumber(noctalia.formatTime("%m"))
local viewYear = tonumber(noctalia.formatTime("%Y"))
local selectedDay = nil
local selectedMonth = nil
local selectedYear = nil

local mode = "agenda"

local formTitle = ""
local formStart = "09:00"
local formDuration = "60"
local formAllDay = false
local formCategory = 0
local formSerial = 0

local pendingNames = {}
local newCategoryName = ""
local newCategorySerial = 0
local colorEditing = nil

local commandSerial = 0
local render

-- Text size multiplier (Settings -> Plugins -> Vietnamese Lunar Calendar).
local function fs(size)
    local scale = tonumber(noctalia.getConfig("font_scale")) or 1.0
    return math.floor(size * scale + 0.5)
end

local function today()
    return tonumber(noctalia.formatTime("%d")),
        tonumber(noctalia.formatTime("%m")),
        tonumber(noctalia.formatTime("%Y"))
end

local function categories()
    if type(data) == "table" and type(data.categories) == "table" then
        return data.categories
    end
    return {}
end

local function send(action)
    commandSerial += 1
    action.nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(commandSerial)
    noctalia.state.set("command", action)
end

local function selectedKey()
    return store.dateKey(selectedYear, selectedMonth, selectedDay)
end

local function goMonth(delta)
    viewMonth = viewMonth + delta
    if viewMonth < 1 then
        viewMonth = 12
        viewYear = viewYear - 1
    elseif viewMonth > 12 then
        viewMonth = 1
        viewYear = viewYear + 1
    end
    if selectedDay ~= nil then
        selectedDay = math.min(selectedDay, lunar.daysInSolarMonth(viewMonth, viewYear))
        selectedMonth = viewMonth
        selectedYear = viewYear
    end
end

local function lunarText(l)
    if l.day == 1 then
        return string.format("%d/%d%s", l.day, l.month, l.leap and "N" or "")
    end
    return tostring(l.day)
end

local function dotsFor(list, cats)
    local dots = {}
    if list == nil then return dots end
    local seen = {}
    for _, ev in ipairs(list) do seen[ev.cat] = true end
    for _, cat in ipairs(cats) do
        if seen[cat.id] then
            table.insert(dots, ui.box({
                key = "dot-" .. cat.id,
                width = 6, height = 6, radius = 3,
                fill = cat.color or store.DEFAULT_COLOR,
            }))
            if #dots >= 4 then break end
        end
    end
    return dots
end

local function addEvent()
    local cats = categories()
    local cat = cats[formCategory + 1]
    if cat == nil then
        noctalia.notifyError("Calendar", noctalia.tr("agenda.errors.create_cat_first"))
        return
    end
    local title = store.trim(formTitle)
    if title == "" then
        noctalia.notifyError("Calendar", noctalia.tr("agenda.errors.enter_name"))
        return
    end

    local start, duration = 0, 0
    if not formAllDay then
        start = store.parseTime(formStart)
        if start == nil then
            noctalia.notifyError("Calendar", noctalia.tr("agenda.errors.time_format"))
            return
        end
        duration = tonumber(formDuration)
        if duration == nil or duration < 1 or duration > 1440 then
            noctalia.notifyError("Calendar", noctalia.tr("agenda.errors.duration_range"))
            return
        end
        duration = math.floor(duration)
    end

    send({
        action = "add_event",
        title = title,
        date = selectedKey(),
        start = start,
        duration = duration,
        allDay = formAllDay,
        cat = cat.id,
    })
    formTitle = ""
    formSerial += 1
    mode = "agenda"
    render()
end

local function commitRename(cat)
    local name = pendingNames[cat.id]
    if name ~= nil and store.trim(name) ~= "" then
        send({ action = "rename_category", id = cat.id, name = name })
    end
    pendingNames[cat.id] = nil
end

local function addCategory()
    if store.trim(newCategoryName) == "" then return end
    send({ action = "add_category", name = newCategoryName })
    newCategoryName = ""
    newCategorySerial += 1
    render()
end

local function headerSection(children)
    table.insert(children, ui.row({ align = "center", justify = "space_between" }, {
        ui.button({
            glyph = "chevron-left",
            variant = "ghost",
            tooltip = noctalia.tr("ui.prev_month"),
            onClick = function() goMonth(-1); render() end,
        }),
        ui.label({
            text = MONTH_NAMES[viewMonth] .. "  ·  " .. tostring(viewYear),
            fontSize = fs(19),
            fontWeight = "bold",
        }),
        ui.button({
            glyph = "chevron-right",
            variant = "ghost",
            tooltip = noctalia.tr("ui.next_month"),
            onClick = function() goMonth(1); render() end,
        }),
    }))
end

local function gridSection(children, cats, byDate)
    local todayDay, todayMonth, todayYear = today()
    local showFestivals = noctalia.getConfig("show_festivals") ~= false
    local accentWeekends = noctalia.getConfig("accent_weekends") ~= false

    local weekdayNodes = {}
    for i, name in ipairs(WEEKDAYS) do
        table.insert(weekdayNodes, ui.label({
            key = "weekday-" .. tostring(i),
            text = name,
            fontSize = fs(12),
            fontWeight = "bold",
            textAlign = "center",
            flexGrow = 1,
            color = accentWeekends and i >= 6 and "primary" or "on_surface/0.7",
        }))
    end
    table.insert(children, ui.row({ gap = 4 }, weekdayNodes))

    local firstWeekday = lunar.weekdayMondayFirst(1, viewMonth, viewYear)
    local days = lunar.daysInSolarMonth(viewMonth, viewYear)
    local cell = 1

    for week = 1, 6 do
        local row = {}
        for weekday = 1, 7 do
            local day = cell - firstWeekday + 1
            if day < 1 or day > days then
                table.insert(row, ui.column({ key = "blank-" .. week .. "-" .. weekday, minHeight = 50, flexGrow = 1 }, {}))
            else
                local l = lunar.solarToLunar(day, viewMonth, viewYear, 7)
                local festival = showFestivals and lunar.festival(l) or nil
                local isToday = day == todayDay and viewMonth == todayMonth and viewYear == todayYear
                local isSelected = day == selectedDay and viewMonth == selectedMonth and viewYear == selectedYear
                local key = store.dateKey(viewYear, viewMonth, day)

                table.insert(row, ui.column({
                    key = "day-" .. day,
                    gap = 1, padding = 3, minHeight = 50, flexGrow = 1, radius = 8,
                    fill = isSelected and "primary/0.18" or festival and "surface_container/0.40" or "surface/0",
                    border = (isSelected or isToday) and "primary" or "outline_variant/0",
                    borderWidth = (isSelected or isToday) and 1 or 0,
                    align = "center", justify = "center",
                    onClick = function()
                        selectedDay = day; selectedMonth = viewMonth; selectedYear = viewYear; render()
                    end,
                }, {
                    ui.label({
                        text = tostring(day), fontSize = fs(15),
                        fontWeight = (isToday or isSelected) and "bold" or "medium",
                        textAlign = "center",
                        color = (isToday or isSelected) and "primary" or accentWeekends and weekday >= 6 and "primary/0.85" or "on_surface",
                    }),
                    ui.label({ text = lunarText(l), fontSize = fs(10), textAlign = "center", color = festival and "primary" or "on_surface/0.55" }),
                    ui.row({ gap = 3, align = "center", justify = "center", minHeight = 6 }, dotsFor(byDate[key], cats)),
                }))
            end
            cell = cell + 1
        end
        table.insert(children, ui.row({ gap = 4 }, row))
        if cell - firstWeekday > days then break end
    end
end

local function dayHeaderSection(children)
    local todayDay, todayMonth, todayYear = today()
    local showFestivals = noctalia.getConfig("show_festivals") ~= false
    local showCanChi = noctalia.getConfig("show_can_chi") ~= false

    local l = lunar.solarToLunar(selectedDay, selectedMonth, selectedYear, 7)
    local festival = showFestivals and lunar.festival(l) or nil
    local details = string.format("%02d/%02d%s %s", l.day, l.month, l.leap and " " .. noctalia.tr("ui.leap") or "", noctalia.tr("ui.lunar_date_suffix"))
    if showCanChi then details = details .. " · " .. noctalia.tr("ui.year") .. " " .. lunar.yearCanChi(l.year) end
    if festival then details = details .. " · " .. festival end

    table.insert(children, ui.separator({ spacing = 2 }))
    table.insert(children, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = string.format("%02d tháng %02d, %d", selectedDay, selectedMonth, selectedYear), fontSize = fs(13), fontWeight = "medium" }),
            ui.label({ text = details, fontSize = fs(12), color = "on_surface/0.65" }),
        }),
        ui.button({
            glyph = mode == "manage" and "calendar" or "settings",
            variant = mode == "manage" and "primary" or "outline",
            tooltip = mode == "manage" and noctalia.tr("agenda.agenda_tab") or noctalia.tr("agenda.manage_tooltip"),
            onClick = function() mode = mode == "manage" and "agenda" or "manage"; colorEditing = nil; render() end,
        }),
        ui.button({
            text = noctalia.tr("ui.today"), glyph = "calendar-event", variant = "secondary",
            onClick = function() viewMonth, viewYear = todayMonth, todayYear; selectedDay, selectedMonth, selectedYear = todayDay, todayMonth, todayYear; render() end,
        }),
    }))
end

local function agendaSection(cats, byDate)
    local list = byDate[selectedKey()] or {}
    local nodes = {}

    for _, cat in ipairs(cats) do
        local group = {}
        for _, ev in ipairs(list) do
            if ev.cat == cat.id then table.insert(group, ev) end
        end
        if #group > 0 then
            table.insert(nodes, ui.row({ key = "grp-" .. cat.id, gap = 8, align = "center" }, {
                ui.box({ width = 4, height = 16, radius = 2, fill = cat.color or store.DEFAULT_COLOR }),
                ui.label({ text = cat.name, fontSize = fs(13), fontWeight = "bold" }),
                ui.label({ text = tostring(#group), fontSize = fs(11), color = "on_surface/0.5" }),
            }))
            for _, ev in ipairs(group) do
                local when = noctalia.tr("agenda.all_day")
                if not ev.allDay then
                    when = store.fmtTime(ev.start) .. " – " .. store.fmtTime((ev.start or 0) + (ev.duration or 0))
                end
                table.insert(nodes, ui.row({ key = "ev-" .. ev.id, gap = 8, align = "center", paddingH = 12 }, {
                    ui.label({ text = when, fontSize = fs(12), color = "on_surface/0.7", width = 104 }),
                    ui.label({ text = ev.title, fontSize = fs(13), flexGrow = 1, maxLines = 1 }),
                    ui.button({
                        glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("agenda.delete"),
                        onClick = function() send({ action = "delete_event", id = ev.id }) end,
                    }),
                }))
            end
        end
    end

    if #nodes == 0 then
        table.insert(nodes, ui.label({ text = noctalia.tr("agenda.no_events"), fontSize = fs(12), color = "on_surface/0.55", textAlign = "center" }))
    end

    return ui.scroll({ flexGrow = 1, minHeight = 110, gap = 6 }, nodes)
end

local function addForm(cats)
    local names = {}
    for _, cat in ipairs(cats) do table.insert(names, cat.name) end
    if formCategory >= #names then formCategory = 0 end

    return ui.column({ gap = 8 }, {
        ui.label({ text = noctalia.tr("agenda.new_event"), fontSize = fs(14), fontWeight = "bold" }),
        ui.input({
            key = "ev-title-" .. formSerial, placeholder = noctalia.tr("agenda.event_name_placeholder"),
            onChange = function(text) formTitle = tostring(text) end,
            onSubmit = function() addEvent() end,
        }),
        ui.select({
            options = names, selectedIndex = formCategory,
            onChange = function(index) formCategory = tonumber(index) or 0; render() end,
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.input({
                key = "ev-start", value = formStart, placeholder = "HH:MM", flexGrow = 1,
                enabled = not formAllDay, onChange = function(text) formStart = tostring(text) end,
            }),
            ui.input({
                key = "ev-duration", value = formDuration, placeholder = "min", flexGrow = 1,
                enabled = not formAllDay, onChange = function(text) formDuration = tostring(text) end,
            }),
            ui.toggle({
                checked = formAllDay,
                onChange = function(value) formAllDay = value == "true" or value == true; render() end,
            }),
            ui.label({ text = noctalia.tr("agenda.all_day"), fontSize = fs(12), color = "on_surface/0.7" }),
        }),
        ui.button({
            text = noctalia.tr("agenda.add_btn"), glyph = "plus", variant = "primary",
            onClick = function() addEvent() end,
        }),
    })
end

local function categoriesSection(cats)
    local nodes = {}

    for _, cat in ipairs(cats) do
        local color = cat.color or store.DEFAULT_COLOR
        table.insert(nodes, ui.row({ key = "cat-" .. cat.id, gap = 8, align = "center" }, {
            ui.column({
                width = 24, height = 24, radius = 6, fill = color, border = "on_surface/0.35", borderWidth = 1,
                onClick = function() colorEditing = colorEditing ~= cat.id and cat.id or nil; render() end,
            }, {}),
            ui.input({
                key = "catname-" .. cat.id, value = cat.name, controlSize = "sm", flexGrow = 1,
                onChange = function(text) pendingNames[cat.id] = tostring(text) end,
                onSubmit = function() commitRename(cat) end,
            }),
            ui.button({
                glyph = "check", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("agenda.save_name"),
                onClick = function() commitRename(cat) end,
            }),
            ui.toggle({
                checked = cat.visible ~= false,
                onChange = function(value) send({ action = "set_visible", id = cat.id, visible = value == "true" or value == true }) end,
            }),
            ui.button({
                glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("agenda.delete_cat_tooltip"),
                enabled = #cats > 1,
                onClick = function() send({ action = "delete_category", id = cat.id }) end,
            }),
        }))

        if colorEditing == cat.id then
            local swatches = {}
            for i, hex in ipairs(store.PALETTE) do
                local current = string.lower(hex) == string.lower(color)
                table.insert(swatches, ui.column({
                    key = "swatch-" .. i, width = 24, height = 24, radius = 6, fill = hex,
                    border = "on_surface", borderWidth = current and 2 or 0,
                    onClick = function() send({ action = "set_color", id = cat.id, color = hex }); colorEditing = nil end,
                }, {}))
            end
            table.insert(nodes, ui.row({ key = "palette-" .. cat.id, gap = 6, paddingH = 32 }, swatches))
        end
    end

    table.insert(nodes, ui.separator({ spacing = 2 }))
    table.insert(nodes, ui.row({ gap = 8, align = "center" }, {
        ui.input({
            key = "newcat-" .. newCategorySerial, placeholder = noctalia.tr("agenda.new_cat_placeholder"),
            controlSize = "sm", flexGrow = 1,
            onChange = function(text) newCategoryName = tostring(text) end,
            onSubmit = function() addCategory() end,
        }),
        ui.button({
            text = noctalia.tr("agenda.add_category_btn"), glyph = "plus", variant = "secondary", controlSize = "sm",
            onClick = function() addCategory() end,
        }),
    }))

    return ui.column({ gap = 8 }, nodes)
end

local function manageSection(cats)
    return ui.scroll({ flexGrow = 1, minHeight = 110, gap = 12 }, {
        addForm(cats),
        ui.separator({ spacing = 2 }),
        ui.label({ text = noctalia.tr("agenda.categories_tab"), fontSize = fs(14), fontWeight = "bold" }),
        categoriesSection(cats),
    })
end

render = function()
    if selectedDay == nil then selectedDay, selectedMonth, selectedYear = today() end
    local cats = categories()
    local byDate = store.eventsByDate(data)
    local children = {}

    headerSection(children)
    gridSection(children, cats, byDate)
    dayHeaderSection(children)

    if mode == "manage" then
        table.insert(children, manageSection(cats))
    else
        table.insert(children, agendaSection(cats, byDate))
    end

    panel.render(ui.column({ gap = 8, padding = 16 }, children))
end

noctalia.state.watch("calendar", function(value)
    data = value
    if panelIsOpen then render() end
end)

function onOpen(context)
    panelIsOpen = true
    data = noctalia.state.get("calendar")
    local d, m, y = today()
    viewMonth, viewYear = m, y
    selectedDay, selectedMonth, selectedYear = d, m, y
    mode = "agenda"
    colorEditing = nil
    render()
end

function onClose()
    panelIsOpen = false
end
