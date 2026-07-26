-- panel.luau -- Monitor de Discos: painel com seletor e config

local disks = {}
local panelOpen = false

local function tr(key, fallback)
    local v = noctalia.tr(key)
    if v == nil or v == key then return fallback or key end
    return v
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

local function getPercentColor(pct)
    if pct >= 80 then return "#ef4444"
    elseif pct >= 60 then return "#facc15"
    else return "#22c55e" end
end

local function getBarWidth(pct)
    local filled = math.floor(pct / 5)
    if filled > 20 then filled = 20 end
    if filled < 0 then filled = 0 end
    local empty = 20 - filled
    return string.rep("█", filled) .. string.rep("░", empty)
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

local function stripSlash(mp)
    if not mp then return "?" end
    if mp == "/" then return "/" end
    return mp:gsub("^/", "")
end

local function formatSize(disk)
    local used = parseBytes(disk.used)
    local total = parseBytes(disk.size)
    if total == 0 then return (disk.used or "?") .. " / " .. (disk.size or "?") end
    local usedGB = used / (1024 * 1024 * 1024)
    local totalGB = total / (1024 * 1024 * 1024)
    if totalGB >= 1 then
        return string.format("%.1f / %.1f GB", usedGB, totalGB)
    else
        return (disk.used or "?") .. " / " .. (disk.size or "?")
    end
end

function onSelect1() setDisk(1) end
function onSelect2() setDisk(2) end
function onSelect3() setDisk(3) end
function onSelect4() setDisk(4) end
function onSelect5() setDisk(5) end
function onSelect6() setDisk(6) end
function onSelect7() setDisk(7) end
function onSelect8() setDisk(8) end

function setDisk(idx)
    local d = disks[idx]
    if not d then return end
    noctalia.state.set("selectedDisk", d.mountpoint)
    render()
end

function onCycleFormat()
    local formats = { "name_free", "free_only", "percent", "name_percent" }
    local current = noctalia.state.get("displayFormat") or noctalia.getConfig("displayFormat") or "name_free"
    local nextIdx = 1
    for i, f in ipairs(formats) do
        if f == current then
            nextIdx = (i % #formats) + 1
            break
        end
    end
    noctalia.state.set("displayFormat", formats[nextIdx])
    render()
end

function render()
    local body = {}
    local currentDisplay = noctalia.state.get("selectedDisk") or "/"

    if #disks == 0 then
        table.insert(body, ui.column({ align = "center", justify = "center", flexGrow = 1, padding = 30 }, {
            ui.glyph({ name = "database", size = 28, color = "secondary" }),
            ui.label({ text = tr("panel.noDisks", "Nenhum disco detectado"), fontSize = 14, color = "on_surface/0.6" }),
        }))
    else
        for i, d in ipairs(disks) do
            local pct = getPercentUsed(d)
            local color = getPercentColor(pct)
            local bar = getBarWidth(pct)
            local icon = getDiskIcon(d)
            local label = stripSlash(d.mountpoint)
            local isSelected = (d.mountpoint == currentDisplay)
            local variant = isSelected and "default" or "outline"

            local tagLabel = ""
            if d.ssd then tagLabel = "SSD" end
            if d.removable then
                if tagLabel ~= "" then tagLabel = tagLabel .. " " end
                tagLabel = tagLabel .. "USB"
            end

            local modelStr = ""
            if d.model and d.model ~= "" then
                modelStr = d.model
            end

            local cb = "onSelect" .. i

            table.insert(body, ui.column({ gap = 3, paddingH = 8, paddingV = 6, fill = "surface_variant", radius = 8 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.button({ glyph = icon, variant = variant, controlSize = "sm", onClick = cb }),
                    ui.column({ gap = 1, flexGrow = 1 }, {
                        ui.row({ gap = 6, align = "center" }, {
                            ui.label({ text = label, fontSize = 14, fontWeight = "bold", color = "on_surface" }),
                            ui.label({ text = tagLabel, fontSize = 11, color = color }),
                        }),
                        ui.label({ text = modelStr, fontSize = 10, color = "on_surface/0.5" }),
                    }),
                    ui.label({ text = tostring(pct) .. "%", fontSize = 14, fontWeight = "bold", color = color }),
                }),
                ui.row({ gap = 6, align = "center" }, {
                    ui.label({ text = bar, fontFamily = "monospace", fontSize = 11, color = color }),
                    ui.label({ text = formatSize(d), fontSize = 11, color = "on_surface/0.7" }),
                }),
                ui.row({ gap = 4, align = "center" }, {
                    ui.label({ text = d.devName, fontSize = 10, color = "on_surface/0.4" }),
                    ui.label({ text = (d.fstype or "?"), fontSize = 10, color = "on_surface/0.4" }),
                }),
            }))
        end
    end

    local currentFormat = noctalia.state.get("displayFormat") or noctalia.getConfig("displayFormat") or "name_free"
    local hideOnEmpty = noctalia.getConfig("hideOnEmpty")
    if hideOnEmpty == nil then hideOnEmpty = false end
    local refreshInterval = noctalia.getConfig("refreshInterval") or 30

    local formatLabel = "Espaco Livre"
    if currentFormat == "free_only" then formatLabel = "Apenas Livre"
    elseif currentFormat == "percent" then formatLabel = "Percentual"
    elseif currentFormat == "name_percent" then formatLabel = "Livre + Percentual"
    end

    table.insert(body, ui.column({ gap = 6, paddingH = 8, paddingV = 8, fill = "surface_variant", radius = 8 }, {
        ui.label({ text = tr("panel.config", "Configuracoes"), fontSize = 13, fontWeight = "bold", color = "primary" }),
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = tr("panel.format", "Formato na barra:"), fontSize = 11, color = "on_surface/0.7", flexGrow = 1 }),
            ui.button({ text = formatLabel, glyph = "adjustments", variant = "outline", controlSize = "sm", onClick = "onCycleFormat" }),
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = tr("panel.interval", "Atualizar a cada:"), fontSize = 11, color = "on_surface/0.7", flexGrow = 1 }),
            ui.label({ text = tostring(refreshInterval) .. "s", fontSize = 11, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = tr("panel.hideEmpty", "Ocultar vazio:"), fontSize = 11, color = "on_surface/0.7", flexGrow = 1 }),
            ui.label({ text = hideOnEmpty and "Sim" or "Nao", fontSize = 11, fontWeight = "bold", color = "on_surface" }),
        }),
    }))

    panel.render(ui.column({ flexGrow = 1, gap = 6, padding = 12, fill = "surface", radius = 12 }, {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = "settings", size = 18, color = "primary" }),
            ui.label({ text = tr("panel.title", "Monitor de Discos"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
        }),

        ui.scroll({ flexGrow = 1, gap = 6 }, body),
    }))
end

function onOpen(_context)
    panelOpen = true
    local raw = noctalia.state.get("disks")
    if raw and raw ~= "" then
        local d = noctalia.json.decode(raw)
        if d then disks = d else disks = {} end
    else
        disks = {}
    end
    render()
end

function onClose()
    panelOpen = false
    disks = {}
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("disks", function(value)
    if value and value ~= "" then
        local d = noctalia.json.decode(value)
        if d then disks = d else disks = {} end
    else
        disks = {}
    end
    if panelOpen then render() end
end)
