--!nonstrict
-- Pin bar widget: lit pin = the target bar is pinned always-visible,
-- dim pin = smart auto-hide. Click toggles.

local function setting(key, fallback)
    local v = noctalia.getConfig(key)
    if v == nil or v == "" then
        return fallback
    end
    return v
end

local function render(pinned)
    local color = "on_surface_variant"
    if pinned == true then
        color = setting("pin_color", "primary")
    end
    barWidget.render(ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = setting("glyph", "pin"), color = color }),
    }))
    if noctalia.state.get("error") then
        barWidget.setTooltip(noctalia.state.get("error"))
    else
        barWidget.setTooltip(pinned == true and noctalia.tr("tooltip.pinned") or noctalia.tr("tooltip.smart"))
    end
end

render(noctalia.state.get("pinned") == true)

noctalia.state.watch("pinned", function(v)
    render(v == true)
end)

function onClick()
    local pinned = noctalia.state.get("pinned") == true
    local path = setting("config_path", "bar.dock.smart_auto_hide")
    -- Pin = smart_auto_hide off; unpin = on.
    local value = pinned and "true" or "false"
    noctalia.runAsync("noctalia msg config-set " .. path .. " " .. value, function(result)
        if result.exitCode == 0 then
            noctalia.state.set("pinned", not pinned)
            noctalia.notify(
                noctalia.tr("title"),
                pinned and noctalia.tr("notify.unpinned") or noctalia.tr("notify.pinned")
            )
        else
            noctalia.notifyError(noctalia.tr("title"), (result.stderr or result.stdout or "config-set failed"):sub(1, 160))
        end
    end)
end

function onConfigChanged()
    render(noctalia.state.get("pinned") == true)
end
