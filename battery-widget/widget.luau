local glyph
local color
local percent
local status

local warning_threshold = 20

local path = "/sys/class/power_supply/"
local batName

local function notifyError()
    noctalia.notifyError("Battery widget", noctalia.tr("notify.error"))
end

for _, cmd in ipairs({ "dbus-monitor", "upower" }) do
    if not noctalia.commandExists(cmd) then
        noctalia.log("battery-widget: " .. cmd .. " not found.")
        notifyError()
        return
    end
end

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
    if status == "charging" then
        glyph = "battery-charging"
    elseif status == "fully-charged" or status == "pending-charge" then
        glyph = "battery-plugged"
    elseif status == "unknown" then
        glyph = "battery-exclamation"
    else
        glyph = percent >= 85 and "battery-4"
        or percent >= 55 and "battery-3"
        or percent >= 30 and "battery-2"
        or percent >= 10 and "battery-1"
        or "battery-0"
    end
end

local function getWarningThreshold()
    noctalia.runAsync(
        "grep warning_threshold ~/.local/state/noctalia/settings.toml | awk '{print $3}'",
        function(result)
            if result.exitCode ~= 0 then
                noctalia.log("battery-widget: failed to get warning_threshold: " .. result.stderr)
                notifyError()
                return
            end

            local res = result.stdout

            if not res then
                noctalia.log("battery-widget: invalid warning_threshold: " .. res)
                notifyError()
                return
            end

            warning_threshold = tonumber(noctalia.string.trim(res))
        end
    )
end

local function getColor()
    if status == "charging" or status == "fully-charged" or status == "pending-charge" then
        color = noctalia.getConfig("charging_color")
        return
    end
    if percent <= warning_threshold then
        color = noctalia.getConfig("warning_color")
        return
    end
    color = noctalia.getConfig("color")
end

local function render()
    if (noctalia.getConfig("hide_plugged") and (status == "charging" or status == "pending-charge"))
        or (noctalia.getConfig("hide_full") and status == "fully-charged") then
        desktopWidget.render(ui.row())
        return
    end

    local content = {}
    if noctalia.getConfig("show_glyph") then
        table.insert(content, ui.glyph({ name = glyph, color = color }))
    end
    if noctalia.getConfig("show_label") then
        table.insert(content, ui.label({ text = percent .. "%", color = color }))
    end

    local vertical = noctalia.getConfig("layout") == "vertical"

    local layout = vertical and ui.column or ui.row

    desktopWidget.render(
        layout({
            gap = vertical and 0 or 4,
            align = "center"
        }, content)
    )
end

local function shellEscape(raw)
    return "'" .. raw:gsub("'", "'\\''") .. "'"
end

local function refreshBattery()
    noctalia.runAsync(
        "upower -i /org/freedesktop/UPower/devices/battery_"
        .. batName,
        function(result)
            if result.exitCode ~= 0 then
                noctalia.log("battery-widget: failed to read battery: " .. result.stderr)
                notifyError()
                return
            end

            local output = result.stdout

            percent = tonumber(output:match("percentage:%s*(%d+)%%"))
            status = output:match("state:%s*(%S+)")

            getGlyph()
            getColor()
            render()
        end
    )
end

batName = getBatName()
if not batName then
    noctalia.log("battery-widget: battery not found")
    notifyError()
    return
end

getWarningThreshold()

local function watchBattery()
    local cmd = string.format(
        "dbus-monitor --system \"type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/freedesktop/UPower/devices/battery_%s'\"",
        batName
    )
    noctalia.runStream(cmd,
        function(line)
            if line:find("Percentage") or line:find("State") then
                refreshBattery()
            end
        end
    )
end

refreshBattery()
watchBattery()
