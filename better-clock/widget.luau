--!nonstrict
-- Minimal digital clock desktop widget.

local timeFormat = noctalia.getConfig("time_format") or "{:%H:%M}"
local dateFormat = noctalia.getConfig("date_format") or "{:%A, %B %d}"
local showDate = noctalia.getConfig("show_date")
if showDate == nil then showDate = true end

function update()
    noctalia.setUpdateInterval(30000)

    local children = {
        ui.label({
            text = noctalia.formatTime(timeFormat),
            fontSize = 32,
            fontWeight = "bold",
            color = "on_surface",
            textAlign = "center",
        }),
    }

    if showDate then
        table.insert(children, ui.label({
            text = noctalia.formatTime(dateFormat),
            fontSize = 13,
            color = "on_surface_variant",
            textAlign = "center",
        }))
    end

    desktopWidget.render(ui.column({
        align = "center",
        justify = "center",
    }, children))
end
