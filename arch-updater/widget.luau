-- widget.luau -- Arch Updater: bar widget showing update count

local count = nil
local noctaliaUpdate = false
local loaded = false

local function tr(key, fallback)
    local v = noctalia.tr(key)
    if v == nil or v == key then return fallback or key end
    return v
end

local function render()
    if not loaded then
        barWidget.setVisible(false)
        return
    end

    local hideOnEmpty = noctalia.getConfig("hideOnEmpty")
    if hideOnEmpty == nil then hideOnEmpty = false end

    if hideOnEmpty and count == 0 then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)

    local glyphColor = "on_surface_variant"
    if noctaliaUpdate then
        glyphColor = "secondary"
    elseif count and count > 0 then
        glyphColor = "primary"
    end

    barWidget.render(ui.row({ gap = 5, align = "center" }, {
        ui.glyph({ name = "arrow-big-down-lines", size = 16, color = glyphColor }),
        ui.label({ text = tostring(count or 0), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
    }))

    barWidget.setTooltip(nil)
end

noctalia.state.watch("count", function(value)
    count = value or 0
    loaded = true
    render()
end)

noctalia.state.watch("noctaliaUpdate", function(value)
    noctaliaUpdate = value == true
    render()
end)

function onClick()
    noctalia.togglePanel("rael2pac/arch-updater:panel")
end

function onMiddleClick()
    noctalia.state.set("refresh_request", (noctalia.state.get("refresh_request") or 0) + 1)
end
