local glyph
local color
local data

local warning_threshold = 20

local path = "/sys/class/power_supply/"
local batName

local stateMap = {
    [0] = "unknown",
    [1] = "charging",
    [2] = "discharging",
    [3] = "empty",
    [4] = "fully-charged",
    [5] = "pending-charge",
    [6] = "pending-discharge",
}

local function shellEscape(raw)
    return "'" .. raw:gsub("'", "'\\''") .. "'"
end

local function notifyError()
    noctalia.notifyError("Battery widget", noctalia.tr("notify.error"))
end

for _, cmd in ipairs({ "gdbus", "upower" }) do
    if not noctalia.commandExists(cmd) then
        noctalia.log("battery-widget: " .. cmd .. " not found.")
        notifyError()
        return
    end
end

local function parse(output)
    data = data or {}

    local percent = output:match("'Percentage':%s*<([%d%.]+)>")
    if percent then
        data.percent = tonumber(percent)
    end

    local state = output:match("'State':%s*<uint32%s+(%d+)>")
    if state then
        data.status = stateMap[tonumber(state)] or "unknown"
    end

    return data
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
    if data.status == "charging" then
        glyph = "battery-charging"
    elseif data.status == "fully-charged" or data.status == "pending-charge" then
        glyph = "battery-plugged"
    elseif data.status == "unknown" then
        glyph = "battery-exclamation"
    else
        glyph = data.percent >= 85 and "battery-4"
        or data.percent >= 55 and "battery-3"
        or data.percent >= 30 and "battery-2"
        or data.percent >= 10 and "battery-1"
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
                noctalia.log("battery-widget: invalid warning_threshold")
                notifyError()
                return
            end

            warning_threshold = tonumber(noctalia.string.trim(res))
        end
    )
end

local function getColor()
    if data.status == "charging" or data.status == "fully-charged" or data.status == "pending-charge" then
        color = noctalia.getConfig("charging_color")
        return
    end
    if data.percent <= warning_threshold then
        color = noctalia.getConfig("warning_color")
        return
    end
    color = noctalia.getConfig("color")
end

local function render()
    if (noctalia.getConfig("hide_plugged") and (data.status == "charging" or data.status == "pending-charge"))
        or (noctalia.getConfig("hide_full") and data.status == "fully-charged") then
        desktopWidget.render(ui.row())
        return
    end

    local content = {}
    if noctalia.getConfig("show_glyph") then
        table.insert(content, ui.glyph({ name = glyph, color = color }))
    end
    if noctalia.getConfig("show_label") then
        table.insert(content, ui.label({ text = data.percent .. "%", color = color }))
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

local function refreshBattery(output)
    parse(output)
    getGlyph()
    getColor()
    render()
end

local function initData()
    local cmd = string.format(
        "gdbus call --system --dest org.freedesktop.UPower --object-path %s --method org.freedesktop.DBus.Properties.GetAll org.freedesktop.UPower.Device",
        shellEscape("/org/freedesktop/UPower/devices/battery_" .. batName)
    )
    noctalia.runAsync(cmd,
        function(result)
            if result.exitCode ~= 0 then
                noctalia.log("battery-widget: failed to read battery: " .. result.stderr)
                return
            end

            if not result.stdout then
                noctalia.log("battery-widget: invalid battery output")
                return
            end

            refreshBattery(result.stdout)
        end
    )
end

local function watchBattery()
    local cmd = string.format(
        "gdbus monitor --system --dest org.freedesktop.UPower --object-path %s",
        shellEscape("/org/freedesktop/UPower/devices/battery_" .. batName)
    )
    noctalia.runStream(cmd,
        function(line)
            for _, pattern in ipairs({ "Percentage", "State" }) do
                if line:find(pattern) then
                    refreshBattery(line)
                    break
                end
            end
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

initData()
watchBattery()
