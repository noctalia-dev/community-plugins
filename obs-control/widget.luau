--!nonstrict

local function render(status)
    status = type(status) == "table" and status or {}
    local active = status.record or status.replay or status.stream
    barWidget.setVisible(active or noctalia.getConfig("show_when_idle"))
    barWidget.setGlyph(status.record and "circle" or "video")
    barWidget.setColor(active and "error" or "primary")
    local labels = {}
    if status.record then
        local label = status.paused and "PAUSED" or "REC"
        if noctalia.getConfig("show_elapsed_in_bar") and type(status.record_time) == "string" then
            label = label .. " " .. (status.record_time:match("^[^.]+") or status.record_time)
        end
        table.insert(labels, label)
    end
    if status.replay then table.insert(labels, "REPLAY") end
    if status.stream then table.insert(labels, "LIVE") end
    barWidget.setText(#labels > 0 and table.concat(labels, " · ") or "OBS")
    barWidget.setTooltip(status.error or (status.record and status.record_time) or
        status.message or (status.connected and noctalia.tr("connected")) or "OBS Studio")
end

noctalia.state.watch("status", render)
render(noctalia.state.get("status"))
function onClick() noctalia.togglePanel("ayagmar/obs-control:controls") end
function onRightClick() noctalia.openSettings() end
