-- panel.luau -- Arch Updater: update panel matching v4 layout

local updates = {}

local function tr(key, fallback)
    local v = noctalia.tr(key)
    if v == nil or v == key then return fallback or key end
    return v
end

local font = "FiraCode Nerd Font SemBd"

local function render()
    local body = {}

    if #updates == 0 then
        table.insert(body, ui.column({ align = "center", justify = "center", flexGrow = 1, padding = 30 }, {
            ui.glyph({ name = "check", size = 28, color = "secondary" }),
            ui.label({ text = tr("panel.noUpdates", "Nenhuma atualização disponível"), fontFamily = font, fontSize = 14, color = "on_surface/0.6" }),
        }))
    else
        -- Header
        table.insert(body, ui.row({ gap = 10, align = "center", paddingH = 6, paddingV = 2 }, {
            ui.label({ text = tr("panel.pacotes", "Pacotes"), fontFamily = font, fontSize = 13, fontWeight = "bold", color = "on_surface_variant", flexGrow = 1 }),
            ui.label({ text = "Versão", fontFamily = font, fontSize = 13, fontWeight = "bold", color = "on_surface_variant" }),
        }))

        -- Data rows
        -- Find max oldVer length for alignment
        local maxOldLen = 0
        for _, u in ipairs(updates) do
            if #u.oldVer > maxOldLen then maxOldLen = #u.oldVer end
        end

        for _, u in ipairs(updates) do
            local ic = "icons/pacman-yellow.svg"
            if u.source == "aur" then ic = "icons/aur-orange.svg"
            elseif u.source == "flatpak" then ic = "icons/flatpak-blue.svg" end

            local rColor = "#94a3b8"
            if u.repo == "core" then rColor = "#3b82f6"
            elseif u.repo == "extra" then rColor = "#22c55e"
            elseif u.repo == "multilib" then rColor = "#ec4899"
            elseif u.repo == "aur" then rColor = "#06b6d4"
            elseif u.repo == "flatpak" then rColor = "#38bdf8" end

            local prefix = ""
            if u.repo ~= "" then prefix = u.repo .. "/" end

            local nameText = prefix .. u.name
            local pad = string.rep(" ", maxOldLen - #u.oldVer) .. u.oldVer

            table.insert(body, ui.row({ gap = 0, align = "center", paddingH = 6, paddingV = 3 }, {
                ui.image({ path = ic, width = 14, height = 14 }),
                ui.label({ text = " " .. nameText, fontFamily = font, fontSize = 12, color = "on_surface", maxLines = 1, flexGrow = 1 }),
                ui.label({ text = pad, fontFamily = font, fontSize = 12, color = "#ef4444", maxLines = 1 }),
                ui.label({ text = "  ->  ", fontFamily = font, fontSize = 12, color = "primary" }),
                ui.label({ text = u.newVer, fontFamily = font, fontSize = 12, fontWeight = "bold", color = "#22c55e", maxLines = 1 }),
            }))
        end
    end

    panel.render(ui.column({ flexGrow = 1, gap = 6, padding = 12, fill = "surface", radius = 12 }, {
        -- Title bar (FIXED - outside scroll)
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = "arrow-big-down-lines", size = 18, color = "primary" }),
            ui.label({ text = tr("panel.title", "Archlinux Update"), fontFamily = font, fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
        }),

        -- Scrollable body
        ui.scroll({ flexGrow = 1, gap = 4 }, body),

        -- Footer buttons (FIXED - outside scroll)
        ui.row({ gap = 10, align = "center" }, {
            ui.button({ text = tr("panel.refresh", "Verificar"), glyph = "refresh", variant = "default", flexGrow = 1, onClick = "onRefreshClicked" }),
            ui.button({ text = tr("panel.update", "Atualizar Tudo"), glyph = "arrow-big-down-lines", variant = "default", flexGrow = 1, onClick = "onUpdateClicked" }),
        }),
    }))
end

function onOpen(_context)
    local raw = noctalia.state.get("updates_raw")
    if raw and raw ~= "" then
        local d = noctalia.json.decode(raw)
        if d then updates = d end
    else
        updates = {}
    end
    render()
end

function onClose()
    updates = {}
end

function onRefreshClicked()
    noctalia.state.set("refresh_request", (noctalia.state.get("refresh_request") or 0) + 1)
end

function onUpdateClicked()
    noctalia.state.set("update_request", (noctalia.state.get("update_request") or 0) + 1)
    panel.close()
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("updates_raw", function(value)
    if value and value ~= "" then
        local d = noctalia.json.decode(value)
        if d then updates = d else updates = {} end
    else
        updates = {}
    end
    render()
end)
