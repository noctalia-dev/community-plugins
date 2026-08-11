local glyph
local color
local data = { percent = 0, status = "unknown" }

local label_content = noctalia.getConfig("label_content")
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

if not noctalia.commandExists("gdbus") then
    noctalia.log("battery-widget: gdbus not found.")
    notifyError()
    return
end

local function parse(output)
    data = data or {}

    local percent = output:match("'Percentage':%s*<([%d%.]+)>")
    if percent then
        data.percent = tonumber(percent) or 0
    end

    local state = output:match("'State':%s*<uint32%s+(%d+)>")
    if state then
        data.status = stateMap[tonumber(state)] or "unknown"
    end

    if label_content == "time" then
        local timeToEmpty = output:match("'TimeToEmpty':%s*<int64%s+(%-?%d+)>")
        if timeToEmpty then
            data.timeToEmpty = tonumber(timeToEmpty)
        end

        local timeToFull = output:match("'TimeToFull':%s*<int64%s+(%-?%d+)>")
        if timeToFull then
            data.timeToFull = tonumber(timeToFull)
        end
    elseif label_content == "rate" then
        local rate = output:match("'EnergyRate':%s*<([%-%d%.]+)>")
        if rate then
            data.rate = tonumber(rate)
        end
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
                noctalia.log("battery-widget: invalid warning_threshold, keeping default")
                notifyError()
                return
            end

            local parsed = tonumber(noctalia.string.trim(res))
            if parsed then
                warning_threshold = parsed
            else
                noctalia.log("battery-widget: invalid warning_threshold, keeping default")
                notifyError()
            end
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

local function formatTime(seconds)
    if not seconds or seconds <= 0 then
        return nil
    end

    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)

    if hours > 0 and minutes > 0 then
        return string.format("%dh %dm", hours, minutes)
    elseif hours > 0 then
        return string.format("%dh", hours)
    else
        return string.format("%dm", minutes)
    end
end

local function formatRate(rate)
    if not rate or rate <= 0 then
        return nil
    end

    return string.format("%.1f W", rate)
end

local function formatPercent()
    return math.floor((data.percent or 0) + 0.5) .. "%"
end

local function getLabelText()
    if label_content == "time" then
        local connected = data.status == "charging" or data.status == "fully-charged" or data.status == "pending-charge"
        local seconds = connected and data.timeToFull or data.timeToEmpty
        return formatTime(seconds) or formatPercent()
    elseif label_content == "rate" then
        return formatRate(data.rate) or formatPercent()
    end

    return formatPercent()
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
        table.insert(content, ui.label({ text = getLabelText(), color = color }))
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
    local patterns = { "Percentage", "State" }
    if label_content == "time" then
        table.insert(patterns, "TimeToEmpty")
        table.insert(patterns, "TimeToFull")
    elseif label_content == "rate" then
        table.insert(patterns, "EnergyRate")
    end

    local cmd = string.format(
        "gdbus monitor --system --dest org.freedesktop.UPower --object-path %s",
        shellEscape("/org/freedesktop/UPower/devices/battery_" .. batName)
    )
    noctalia.runStream(cmd,
        function(line)
            for _, pattern in ipairs(patterns) do
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
