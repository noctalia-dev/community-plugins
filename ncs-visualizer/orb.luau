--!nonstrict
-- NCS Visualizer - desktop widget.
--
-- The orb itself is drawn by the companion renderer (aurora-ncs) in its own
-- click-through layer exactly over this widget's box; the service reads the
-- box from the desktop-widget layout. So this widget stays empty and just
-- holds the place - you move and resize it like any other desktop widget.
--
-- If something is missing it shows what, instead of an invisible box.

local SIZE = 420 -- auto-fit size; keep in sync with DEFAULT_SIZE in service.luau

local status = noctalia.state.get("status")

local function message(glyph, title, hint)
    return ui.column({
        width = SIZE,
        height = SIZE,
        padding = 24,
        gap = 10,
        fill = "surface",
        radius = SIZE / 2,
        align = "center",
        justify = "center",
    }, {
        ui.glyph({ name = glyph, size = 36, color = "primary" }),
        ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "on_surface", textAlign = "center" }),
        ui.label({ text = hint, fontSize = 12, color = "on_surface_variant", maxWidth = SIZE - 96, maxLines = 4, textAlign = "center" }),
    })
end

local function render()
    local problem = if type(status) == "table" then status.problem else nil
    if problem == "missing_renderer" then
        desktopWidget.render(message("alert-triangle", noctalia.tr("widget.missing_renderer"), noctalia.tr("widget.missing_renderer_hint")))
    elseif problem == "missing_cava" then
        desktopWidget.render(message("alert-triangle", noctalia.tr("widget.missing_cava"), noctalia.tr("widget.missing_cava_hint")))
    elseif problem == "crashed" then
        desktopWidget.render(message("alert-triangle", noctalia.tr("widget.crashed"),
            noctalia.tr("widget.crashed_hint", { path = status.config or "" })))
    else
        -- Disabled orbs leave an empty box too: the tile already says it's off.
        desktopWidget.render(ui.box({ width = SIZE, height = SIZE, fill = "#00000000" }, {}))
    end
end

-- Noctalia (re)creates this widget's surface whenever the layout changes, and
-- a newly mapped surface stacks above the renderer's. Tell the service so the
-- renderer re-maps its windows on top again.
noctalia.state.set("surface", noctalia.nowMs())

noctalia.state.watch("status", function(value)
    status = value
    render()
end)

render()
