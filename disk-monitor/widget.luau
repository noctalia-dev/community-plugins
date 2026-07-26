-- widget.luau -- Monitor de Discos: bar widget

local diskData = {}
local loaded = false

local function tr(key, fallback)
    local v = noctalia.tr(key)
    if v == nil or v == key then return fallback or key end
    return v
end

local function findDisk(mountpoint)
    for _, d in ipairs(diskData) do
        if d.mountpoint == mountpoint then
            return d
        end
    end
    return nil
end

local function getDiskIcon(disk)
    if disk.removable then
        local name = (disk.devName or ""):lower()
        if name:match("sd") and not name:match("nvme") then
            return "device-sd-card"
        end
        return "device-usb"
    end
    return "database"
end

local function parseBytes(str)
    if not str or str == "?" then return 0 end
    local num, unit = str:match("^([%d%.]+)(.+)$")
    if not num then return 0 end
    num = tonumber(num)
    if not num then return 0 end
    unit = unit:upper()
    if unit == "T" or unit == "TB" then return num * 1024 * 1024 * 1024 * 1024
    elseif unit == "G" or unit == "GB" then return num * 1024 * 1024 * 1024
    elseif unit == "M" or unit == "MB" then return num * 1024 * 1024
    elseif unit == "K" or unit == "KB" then return num * 1024
    else return num end
end

local function getPercentUsed(disk)
    if disk.percent then
        return tonumber(disk.percent:match("(%d+)")) or 0
    end
    local totalBytes = parseBytes(disk.size)
    local usedBytes = parseBytes(disk.used)
    if totalBytes == 0 then return 0 end
    return math.floor((usedBytes / totalBytes) * 100)
end

local function render()
    if not loaded then
        barWidget.setVisible(false)
        return
    end

    local hideOnEmpty = noctalia.getConfig("hideOnEmpty")
    if hideOnEmpty == nil then hideOnEmpty = false end

    local displayDisk = noctalia.state.get("selectedDisk") or "/"
    local displayFormat = noctalia.state.get("displayFormat") or noctalia.getConfig("displayFormat") or "name_free"

    local disk = findDisk(displayDisk)

    if not disk then
        if hideOnEmpty then
            barWidget.setVisible(false)
        else
            barWidget.setVisible(true)
            barWidget.render(ui.row({ gap = 5, align = "center" }, {
                ui.glyph({ name = "database", size = 16, color = "on_surface_variant" }),
                ui.label({ text = tr("widget.noDisk", "Sem dados"), fontSize = 13, color = "on_surface/0.6" }),
            }))
        end
        return
    end

    barWidget.setVisible(true)

    local pct = getPercentUsed(disk)
    local icon = getDiskIcon(disk)

    local text = ""
    if displayFormat == "name_free" then
        text = (disk.avail or "?") .. " livres"
    elseif displayFormat == "free_only" then
        text = disk.avail or "?"
    elseif displayFormat == "percent" then
        text = tostring(pct) .. "%"
    elseif displayFormat == "name_percent" then
        text = (disk.avail or "?") .. " (" .. tostring(pct) .. "%)"
    else
        text = (disk.avail or "?") .. " livres"
    end

    barWidget.render(ui.row({ gap = 5, align = "center" }, {
        ui.glyph({ name = icon, size = 16, color = "on_surface" }),
        ui.label({ text = text, fontSize = 13, fontWeight = "bold", color = "on_surface" }),
    }))

    local tooltip = disk.devName .. " (" .. (disk.fstype or "?") .. ") - " .. (disk.used or "?") .. " / " .. (disk.size or "?")
    if disk.model and disk.model ~= "" then
        tooltip = disk.model .. " | " .. tooltip
    end
    barWidget.setTooltip(tooltip)
end

noctalia.state.watch("disks", function(value)
    if value and value ~= "" then
        local d = noctalia.json.decode(value)
        if d then diskData = d else diskData = {} end
    else
        diskData = {}
    end
    loaded = true
    render()
end)

noctalia.state.watch("selectedDisk", function(_value)
    render()
end)

noctalia.state.watch("displayFormat", function(_value)
    render()
end)

function onClick()
    noctalia.togglePanel("rael2pac/disk-monitor:panel")
end

render()
