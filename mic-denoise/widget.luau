--!nonstrict
-- Mic Denoise - optional bar widget.
--
-- Add it from the bar widget picker ("Mic Denoise"). Same thin-client contract
-- as the control-center tile: mirror "status", write "command".

local on = false

local function render(st)
    local known = type(st) == "table"
    on = known and st.enabled == true

    barWidget.setGlyph(on and "microphone" or "microphone-off")
    barWidget.setTooltip({
        {
            key = noctalia.tr("widget.tooltip.state"),
            value = on and noctalia.tr("shortcut.label-on") or noctalia.tr("shortcut.label-off"),
        },
        {
            key = noctalia.tr("widget.tooltip.input"),
            value = (known and st.default ~= "" and st.default) or "-",
        },
    })
end

render(noctalia.state.get("status"))
noctalia.state.watch("status", render)

-- Absolute target, so a double click stays idempotent (see shortcut.luau).
function onClick()
    noctalia.state.set("command", { action = on and "off" or "on", seq = noctalia.nowMs() })
end

function onRightClick()
    noctalia.openSettings()
end
