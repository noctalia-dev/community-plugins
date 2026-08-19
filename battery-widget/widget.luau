local glyph
local color
local data = { percent = 0, status = "unknown" }

local function getConf(key, default)
    local value = noctalia.getConfig(key)
    if value == nil then
        return default
    else
        return value
    end
end

local config = {
    warning_threshold = noctalia.getSetting("battery.warning_threshold") or 10,
    layout = getConf("layout", "horizontal"),
    show_glyph = getConf("show_glyph", true),
    show_label = getConf("show_label", true),
    label_content = getConf("label_content", "percent"),
    hide_plugged = getConf("hide_plugged", false),
    hide_full = getConf("hide_full", false),
    color = getConf("color", "on_surface"),
    warning_color = getConf("warning_color", "error"),
    charging_color = getConf("charging_color", "on_surface"),
}

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
    local percent = output:match("'Percentage':%s*<([%d%.]+)>")
    if percent then
        data.percent = tonumber(percent) or 0
    end

    local state = output:match("'State':%s*<uint32%s+(%d+)>")
    if state then
        data.status = stateMap[tonumber(state)] or "unknown"
    end

    if config.label_content == "time" then
        local timeToEmpty = output:match("'TimeToEmpty':%s*<int64%s+(%-?%d+)>")
        if timeToEmpty then
            data.timeToEmpty = tonumber(timeToEmpty)
        end

        local timeToFull = output:match("'TimeToFull':%s*<int64%s+(%-?%d+)>")
        if timeToFull then
            data.timeToFull = tonumber(timeToFull)
        end
    elseif config.label_content == "rate" then
        local rate = output:match("'EnergyRate':%s*<([%-%d%.]+)>")
        if rate then
            data.rate = tonumber(rate)
        end
    end

    return data
end

local function getBatName()
    local config = noctalia.getConfig("battery") or "auto"

    if config == "bat0" then
        return "BAT0"
    elseif config == "custom" then
        return noctalia.getConfig("battery_name") or "BAT0"
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

local function getColor()
    if data.status == "charging" or data.status == "fully-charged" or data.status == "pending-charge" then
        color = config.charging_color
        return
    end
    if data.percent <= config.warning_threshold then
        color = config.warning_color
        return
    end
    color = config.color
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
    if config.label_content == "time" then
        local connected = data.status == "charging" or data.status == "fully-charged" or data.status == "pending-charge"
        local seconds = connected and data.timeToFull or data.timeToEmpty
        return formatTime(seconds) or formatPercent()
    elseif config.label_content == "rate" then
        return formatRate(data.rate) or formatPercent()
    end

    return formatPercent()
end

local function render()
    if (config.hide_plugged and (data.status == "charging" or data.status == "pending-charge"))
        or (config.hide_full and data.status == "fully-charged") then
        desktopWidget.render(ui.row())
        return
    end

    local content = {}
    if config.show_glyph then
        table.insert(content, ui.glyph({ name = glyph, color = color }))
    end
    if config.show_label then
        table.insert(content, ui.label({ text = getLabelText(), color = color }))
    end

    local vertical = config.layout == "vertical"

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
                notifyError()
                return
            end

            if not result.stdout then
                noctalia.log("battery-widget: invalid battery output")
                notifyError()
                return
            end

            refreshBattery(result.stdout)
        end
    )
end

local function watchBattery()
    local patterns = { "Percentage", "State" }
    if config.label_content == "time" then
        table.insert(patterns, "TimeToEmpty")
        table.insert(patterns, "TimeToFull")
    elseif config.label_content == "rate" then
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

initData()
watchBattery()
