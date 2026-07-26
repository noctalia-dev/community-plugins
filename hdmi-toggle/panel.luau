-- panel.luau -- Monitor Manager: toggle panel

local monitors = {}
local panelOpen = false

local function tr(key, fallback)
    local v = noctalia.tr(key)
    if v == nil or v == key then return fallback or key end
    return v
end

function parseOutputs(text)
    local list = {}
    local currentName = ""
    local currentOn = false
    for line in text:gmatch("[^\n]+") do
        local name = line:match('^Output%s+".+"%s+%(([^)]+)%)%s*$')
        if name then
            if currentName ~= "" then
                table.insert(list, { name = currentName, on = currentOn })
            end
            currentName = name
            currentOn = false
        elseif line:find("Current mode") then
            currentOn = true
        end
    end
    if currentName ~= "" then
        table.insert(list, { name = currentName, on = currentOn })
    end
    return list
end

local function doToggle(idx)
    local m = monitors[idx]
    if not m then return end
    local cmd = "niri msg output " .. m.name .. (m.on and " off" or " on")
    noctalia.runAsync(cmd, function(_result)
        noctalia.runAsync("niri msg outputs", function(result)
            if result.exitCode == 0 and result.stdout ~= "" then
                monitors = parseOutputs(result.stdout)
                noctalia.state.set("monitors", noctalia.json.encode(monitors))
            end
            render()
        end)
    end)
end

function onToggle1() doToggle(1) end
function onToggle2() doToggle(2) end
function onToggle3() doToggle(3) end
function onToggle4() doToggle(4) end
function onToggle5() doToggle(5) end
function onToggle6() doToggle(6) end
function onToggle7() doToggle(7) end
function onToggle8() doToggle(8) end

local toggleCb = {
    "onToggle1", "onToggle2", "onToggle3", "onToggle4",
    "onToggle5", "onToggle6", "onToggle7", "onToggle8",
}

function render()
    local body = {}

    if #monitors == 0 then
        table.insert(body, ui.column({ align = "center", justify = "center", flexGrow = 1, padding = 20 }, {
            ui.glyph({ name = "device-desktop", size = 24, color = "secondary" }),
            ui.label({ text = tr("panel.noMonitors", "Nenhum monitor detectado"), fontSize = 12, color = "on_surface/0.6" }),
        }))
    else
        for i, m in ipairs(monitors) do
            local statusIcon = m.on and "check" or "x"
            local statusColor = m.on and "#22c55e" or "#ef4444"
            local label = m.name .. "   " .. (m.on and "Ligado" or "Desligado")
            local cb = toggleCb[i] or toggleCb[1]

            table.insert(body, ui.button({
                text = label,
                glyph = statusIcon,
                variant = "outline",
                controlSize = "lg",
                onClick = cb,
            }))
        end
    end

    panel.render(ui.column({ flexGrow = 1, gap = 4, padding = 10, fill = "surface" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "device-desktop", size = 16, color = "primary" }),
            ui.label({ text = tr("panel.title", "Monitores"), fontSize = 14, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
        }),

        ui.scroll({ flexGrow = 1, gap = 4 }, body),
    }))
end

function onOpen(_context)
    panelOpen = true
    noctalia.runAsync("niri msg outputs", function(result)
        if result.exitCode == 0 and result.stdout ~= "" then
            monitors = parseOutputs(result.stdout)
            noctalia.state.set("monitors", noctalia.json.encode(monitors))
        end
        render()
    end)
end

function onClose()
    panelOpen = false
    monitors = {}
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("monitors", function(value)
    if value and value ~= "" then
        local d = noctalia.json.decode(value)
        if d then monitors = d else monitors = {} end
    else
        monitors = {}
    end
    if panelOpen then render() end
end)
