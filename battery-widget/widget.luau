noctalia.setUpdateInterval(noctalia.getConfig("refresh_interval") * 1000)

local glyph = "battery"
local percent = "Loading..."
local status

local path = "/sys/class/power_supply/"
local batName

local function getBatName()
    local config = noctalia.getConfig("battery")

    if config == "bat0" then
        return "BAT0"
    elseif config == "custom" then
        return noctalia.getConfig("battery_name")
    end

    local folders = noctalia.listDir(path)

    if folders then
        for _, name in ipairs(folders) do
            if name:match("^BAT") then
                return name
            end
        end
    end
    return nil
end

local function getGlyph()
    if status == "Charging" then
        glyph = "battery-charging"
    elseif status == "Full" then
        glyph = "battery-plugged"
    elseif status == "Unknown" then
        glyph = "battery-exclamation"
    else
        glyph = percent >= 85 and "battery-4"
        or percent >= 55 and "battery-3"
        or percent >= 30 and "battery-2"
        or percent >= 10 and "battery-1"
        or "battery-0"
    end
end

local function render()
    if (noctalia.getConfig("hide_plugged") and status == "Charging") 
        or (noctalia.getConfig("hide_full") and status == "Full") then
        desktopWidget.render(ui.row())
        return
    end

    local content = {
        noctalia.getConfig("show_glyph") and ui.glyph({ name = glyph }),
        noctalia.getConfig("show_label") and ui.label({ text = percent .. "%" }),
    }

    local layout = noctalia.getConfig("layout") == "vertical" and ui.column or ui.row

    desktopWidget.render(layout({ gap = 4, align = "center" }, content))
end

local function refreshBattery()
    noctalia.runAsync(
        "cat "
            .. path .. batName .. "/capacity "
            .. path .. batName .. "/status",
        function(result)
            if result.exitCode ~= 0 then
                noctalia.log("battery-widget: failed to read battery: " .. result.stderr)
                return
            end

            local lines = {}
            for line in result.stdout:gmatch("[^\r\n]+") do
                table.insert(lines, line)
            end

            if not lines[1] or not lines[2] then
                noctalia.log("battery-widget: invalid battery output")
                return
            end

            percent = tonumber(noctalia.string.trim(lines[1]))
            status = noctalia.string.trim(lines[2])

            getGlyph()
            render()
        end
    )
end

batName = getBatName()
if not batName then
    noctalia.log("battery-widget: battery not found")
end

render()
function update()
    refreshBattery()
end
