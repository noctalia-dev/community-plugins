--!nonstrict
-- Bar widget: category-coloured markers for the next events plus the title of
-- the very next one. Click opens the calendar panel.

local store = require("./store.luau")

local PANEL_ID = "notoxus/vietnamese-lunar-calendar:calendar"

local data = noctalia.state.get("calendar")

local function whenLabel(ev, today, tomorrow)
    local time = ev.allDay and noctalia.tr("upcoming.all_day") or store.fmtTime(ev.start)
    if ev.date == today then
        return time
    end
    if ev.date == tomorrow then
        return noctalia.tr("upcoming.tomorrow") .. time
    end
    return string.sub(ev.date, 9, 10) .. "/" .. string.sub(ev.date, 6, 7) .. " " .. time
end

local function render()
    local maxItems = math.max(1, math.floor(tonumber(noctalia.getConfig("max_items")) or 3))
    local showTitle = noctalia.getConfig("show_title") ~= false
    local today = noctalia.formatTime("%Y-%m-%d")
    local tomorrow = noctalia.formatTime("%Y-%m-%d", (tonumber(noctalia.formatTime("%s")) or 0) + 86400)
    local nowMinutes = store.parseTime(noctalia.formatTime("%H:%M")) or 0

    local list = store.upcoming(data, 8, today, nowMinutes)

    if #list == 0 then
        barWidget.render(ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "calendar-event", size = 16, color = "on_surface/0.6" }),
        }))
        barWidget.setTooltip({ { key = noctalia.tr("upcoming.calendar"), value = noctalia.tr("upcoming.no_events") } })
        return
    end

    local markers = {}
    for i = 1, math.min(maxItems, #list) do
        table.insert(markers, ui.box({
            key = "m-" .. tostring(i),
            width = 8,
            height = 8,
            radius = 4,
            fill = list[i].color,
        }))
    end

    local nodes = {}
    if barWidget.isVertical() then
        table.insert(nodes, ui.column({ gap = 4, align = "center" }, markers))
    else
        table.insert(nodes, ui.row({ gap = 4, align = "center" }, markers))
        if showTitle then
            local nextEvent = list[1]
            table.insert(nodes, ui.label({
                text = whenLabel(nextEvent, today, tomorrow) .. "  " .. nextEvent.title,
                fontSize = 12,
                maxLines = 1,
                maxWidth = 220,
            }))
        end
    end

    local root = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(root({ gap = 6, align = "center" }, nodes))

    local tooltip = {}
    for _, ev in ipairs(list) do
        table.insert(tooltip, {
            key = whenLabel(ev, today, tomorrow),
            value = ev.title .. " · " .. ev.category,
        })
    end
    barWidget.setTooltip(tooltip)
end

noctalia.state.watch("calendar", function(value)
    data = value
    render()
end)

function update()
    noctalia.setUpdateInterval(30000)
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end


