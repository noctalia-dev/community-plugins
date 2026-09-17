--!nonstrict
-- topgrade-wrapper — bar widget: pending-update badge and panel toggle.
--
-- A pure renderer over the shared state the engine (service.luau) publishes on
-- "topgrade_state"; the count is therefore already there when the panel has
-- never been opened, and every bar showing the widget agrees.
--
-- Click mapping is declared in plugin.toml's [widget.actions] (plugin_api >=
-- 14), not hard-coded here, so the user can remap it from the bar's own
-- gesture settings like any built-in widget:
--   Left click   — panel-toggle nightwatch75/topgrade-wrapper:panel
--   Right click  — plugin nightwatch75/topgrade-wrapper:service all check
--                  (the exact same IPC line service.luau's onIpc documents)
--
-- There is deliberately no middle-click binding: every bar widget carries a
-- built-in `middle` binding that opens its own settings, and that default
-- behaviour is exactly what's wanted here.

local shared = require("./shared.luau")

local snapshot = nil

local function tr(key, args)
    return shared.tr(key, args)
end

-- "pacman 5 · Flatpak 1" — the per-manager breakdown, non-zero entries only.
local function breakdown()
    if snapshot == nil or type(snapshot.counts) ~= "table" then
        return ""
    end
    local parts = {}
    for _, entry in ipairs(snapshot.counts) do
        if entry.n > 0 then
            table.insert(parts, tr("count." .. entry.key) .. " " .. entry.n)
        end
    end
    return table.concat(parts, " · ")
end

local function statusLabel()
    if snapshot == nil then
        return tr("status_idle")
    end
    local phase = snapshot.phase
    if phase == "missing" then
        return tr("status_missing")
    elseif phase == "checking" then
        local current = snapshot.step
        if current ~= nil and current ~= "" then
            return tr("status_checking_step", { step = current })
        end
        return tr("status_checking")
    elseif phase == "running" then
        return tr("status_running")
    elseif phase == "error" then
        return snapshot.err or tr("status_error")
    elseif phase == "clean" then
        return tr("status_clean")
    elseif phase == "ready" then
        return noctalia.trp("status_ready", snapshot.total or 0, {})
    end
    return tr("status_idle")
end

-- Updates are "pending" only while they are worth interrupting the user for:
-- a dismissed result stays visible in the panel but takes the bar back to its
-- resting colour.
local function pending()
    return snapshot ~= nil
        and snapshot.phase == "ready"
        and snapshot.dismissed ~= true
        and (snapshot.total or 0) > 0
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))

    local phase = snapshot ~= nil and snapshot.phase or "idle"
    if phase == "missing" or phase == "error" then
        barWidget.setGlyphColor("error")
    elseif phase == "checking" or phase == "running" then
        barWidget.setGlyphColor("secondary")
    elseif pending() then
        barWidget.setGlyphColor("primary")
    else
        barWidget.setGlyphColor("on_surface")
    end

    if pending() and noctalia.getConfig("show_count") == true then
        barWidget.setText(tostring(snapshot.total))
    else
        barWidget.setText("")
    end

    -- A semantic row label, not the plugin name: the tooltip hangs off this
    -- plugin's own glyph, so restating "Topgrade Wrapper" only costs width.
    local rows = { { key = tr("tooltip_status"), value = statusLabel() } }
    local detail = breakdown()
    if detail ~= "" then
        table.insert(rows, { key = tr("tooltip_pending"), value = detail })
    end
    if snapshot ~= nil and snapshot.checkedAt ~= nil and snapshot.checkedAt ~= "" then
        table.insert(rows, { key = tr("tooltip_checked"), value = snapshot.checkedAt })
    end
    table.insert(rows, { key = "", value = tr("tooltip_hints") })
    barWidget.setTooltip(rows)
end

noctalia.state.watch(shared.STATE_KEY, function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

-- Periodic re-render keeps the glyph and count in sync with widget-setting
-- edits, which do not move the engine's state.
function update()
    render()
end

noctalia.setUpdateInterval(1000)
snapshot = noctalia.state.get(shared.STATE_KEY)
render()
