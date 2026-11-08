--!nonstrict
-- Internal Keyboard - optional bar widget.
--
-- Same thin-client contract as the control center tile: mirror "status",
-- write "command". Add it from the bar widget picker.

local function render(status)
    local known = type(status) == "table"
    local off = known and status.state == "off"
    local ready = known and status.installed == true

    barWidget.setGlyph(off and "keyboard-off" or "keyboard")
    barWidget.setTooltip({
        {
            key = noctalia.tr("widget.tooltip.state"),
            value = ready and noctalia.tr(off and "shortcut.state.off" or "shortcut.state.on")
                or noctalia.tr("widget.tooltip.setup"),
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
    local status = noctalia.state.get("status")
    if type(status) ~= "table" or status.installed ~= true then
        noctalia.state.set("command", { action = "setup", seq = noctalia.nowMs() })
        return
    end
    noctalia.state.set("command", { action = "toggle", seq = noctalia.nowMs() })
end

function onRightClick()
    noctalia.state.set("command", { action = "refresh", seq = noctalia.nowMs() })
end
