--!nonstrict
-- Screen Mirror - optional bar widget.
--
-- Same thin-client contract as the control-center tile: mirror "status", write
-- "command". Add it from the bar widget picker ("Screen Mirror").

local function dash(text)
    if type(text) ~= "string" or text == "" then
        return "-"
    end
    return (text:gsub(",", ", "))
end

local function render(st)
    local known = type(st) == "table"
    local on = known and st.enabled == true
    local running = known and st.running == true

    barWidget.setGlyph(on and "screen-share" or "screen-share-off")

    local rows = {
        {
            key = noctalia.tr("widget.tooltip.state"),
            value = on and noctalia.tr("shortcut.label-on") or noctalia.tr("shortcut.label-off"),
        },
    }
    if running then
        table.insert(rows, { key = noctalia.tr("widget.tooltip.source"), value = dash(st.source) })
        table.insert(rows, { key = noctalia.tr("widget.tooltip.targets"), value = dash(st.targets) })
    else
        table.insert(rows, {
            key = noctalia.tr("widget.tooltip.daemon"),
            value = noctalia.tr("widget.tooltip.stopped"),
        })
    end
    barWidget.setTooltip(rows)
end

render(noctalia.state.get("status"))
noctalia.state.watch("status", render)

function onClick()
    noctalia.state.set("command", { action = "toggle", seq = noctalia.nowMs() })
end
