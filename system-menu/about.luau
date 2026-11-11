--!nonstrict

local distroIcon = require("./distro_icon.luau")

local data = nil
local loading = false
local errorMessage = nil
local expanded = false
local copied = false
local generation = 0
local visible = false
local labelWidth = 136

local function informationRow(row)
    local value = {
        ui.label({ text = row.value, fontSize = 14, fontWeight = "medium", maxLines = 3 }),
    }
    if row.detail and row.detail ~= "" then
        table.insert(value, ui.label({ text = row.detail, fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
    end
    return ui.row({ gap = 16, paddingV = 8, align = "start" }, {
        ui.column({ width = labelWidth, minWidth = labelWidth }, {
            ui.label({ text = row.label, maxWidth = labelWidth, fontSize = 13, color = "on_surface_variant", maxLines = 2 }),
        }),
        ui.column({ gap = 4, width = 0, minWidth = 0, flexGrow = 1 }, value),
    })
end

local function sectionCard(section)
    local rows = {
        ui.row({ gap = 8, align = "center", paddingV = 4 }, {
            ui.glyph({ name = section.icon, size = 18, color = "primary" }),
            ui.label({ text = section.title, fontWeight = "bold", fontSize = 15 }),
        }),
    }
    for index, row in ipairs(section.rows) do
        if index > 1 then table.insert(rows, ui.separator({ color = "outline_variant/0.5" })) end
        table.insert(rows, informationRow(row))
    end
    return ui.column({ gap = 2, padding = 16, fill = "surface_container", radius = 14 }, rows)
end

local function render()
    if not visible then return end
    local content = {}
    if data then
        table.insert(content, ui.column({ align = "center", gap = 8, paddingV = 12 }, {
            ui.image({ path = distroIcon.path(64) or data.logo, width = 64, height = 64 }),
            ui.label({ text = data.hostname, fontSize = 25, fontWeight = "bold", maxLines = 2, textAlign = "center" }),
            ui.label({ text = data.subtitle, fontSize = 14, color = "on_surface_variant", textAlign = "center" }),
        }))
        for _, section in ipairs(data.sections) do
            table.insert(content, sectionCard(section))
        end
        if #data.details.rows > 0 then
            table.insert(content, ui.button({
                text = "Technical Details", glyph = expanded and "chevron-up" or "chevron-down",
                variant = "ghost", contentAlign = "start", onClick = "toggleDetails",
            }))
            if expanded then table.insert(content, sectionCard(data.details)) end
        end
        for _, warning in ipairs(data.warnings) do
            table.insert(content, ui.label({ text = warning, color = "on_surface_variant", fontSize = 12, maxLines = 3 }))
        end
    elseif loading then
        table.insert(content, ui.label({ text = "Reading system information…", color = "on_surface_variant" }))
    end
    if errorMessage then
        table.insert(content, ui.label({ text = errorMessage, color = "error", maxLines = 4 }))
    end

    panel.render(ui.column({ gap = 14, flexGrow = 1 }, {
        ui.row({ gap = 12, align = "center" }, {
            ui.label({ text = "About This System", fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = "closeAbout" }),
        }),
        ui.scroll({ gap = 12, flexGrow = 1 }, content),
        ui.row({ gap = 8 }, {
            ui.button({ text = loading and "Reading…" or "Refresh", glyph = "refresh", variant = "ghost",
                enabled = not loading, onClick = "refresh" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({ text = copied and "Copied" or "Copy Information", glyph = copied and "check" or "copy",
                variant = "primary", enabled = data ~= nil, onClick = "copyInformation" }),
        }),
    }))
end

function refresh()
    if loading then return end
    generation = generation + 1
    local request = generation
    loading = true
    copied = false
    errorMessage = nil
    render()
    local started = noctalia.runAsync({ "python3", noctalia.pluginDir() .. "/collect.py" }, function(result)
        if request ~= generation then return end
        loading = false
        if result.exitCode == 0 then
            local parsed = noctalia.json.decode(result.stdout)
            if parsed and parsed.sections and parsed.details and parsed.report then
                data = parsed
            else
                errorMessage = "Could not read system information. Try refreshing."
            end
        else
            errorMessage = "Could not collect system information. Please try again."
            noctalia.log("System information: " .. (result.stderr or "unknown error"))
        end
        render()
    end)
    if not started then
        loading = false
        errorMessage = "Could not start collecting system information."
        render()
    end
end

function onOpen()
    visible = true
    expanded = false
    refresh()
end

function onClose()
    visible = false
    generation = generation + 1
    loading = false
end

function closeAbout()
    panel.close()
end

function toggleDetails()
    expanded = not expanded
    render()
end

function copyInformation()
    if data and noctalia.copyToClipboard(data.report, "text/plain") then
        copied = true
        render()
    end
end
