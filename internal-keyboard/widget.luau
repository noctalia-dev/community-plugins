--!nonstrict
-- Internal Keyboard - optional bar widget.
--
-- Same thin-client contract as the control center tile: mirror "status",
-- write "command". Add it from the bar widget picker.

local function render(status)
    local known = type(status) == "table"
    local off = known and status.state == "off"

    barWidget.setGlyph(off and "keyboard-off" or "keyboard")
    barWidget.setTooltip({
        {
            key = noctalia.tr("widget.tooltip.state"),
            value = noctalia.tr(off and "shortcut.state.off" or "shortcut.state.on"),
        },
        {
            key = noctalia.tr("widget.tooltip.device"),
            value = (known and status.device ~= "" and status.device) or "-",
        },
    })
end

render(noctalia.state.get("status"))
noctalia.state.watch("status", render)

function onClick()
    noctalia.state.set("command", { action = "toggle", seq = noctalia.nowMs() })
end

function onRightClick()
    noctalia.state.set("command", { action = "refresh", seq = noctalia.nowMs() })
end
