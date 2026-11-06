--!nonstrict
-- Arch Audit bar widget: an ambient severity indicator over the state the
-- service publishes. It never runs a command itself.
--
--   left click:  open/close the details panel
--   right click: run a check now
--   middle:      Noctalia's built-in widget-settings gesture (not overridden)
--
-- The glyph is the configured one while advisories are present, shield-check
-- when the last check was clean, and shield-x when the plugin cannot check.

local audit = require("./lib/audit.luau")

local STATE_KEY = "arch_audit_state"
local REQUEST_KEY = "arch_audit_request"
local PANEL_ID = "cero800/arch-audit:panel"

local snapshot = nil

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function request_check()
    local previous = noctalia.state.get(REQUEST_KEY)
    local nonce = ((type(previous) == "table" and tonumber(previous.nonce)) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, action = "check" })
end

local function configured_glyph()
    local glyph = noctalia.getConfig("glyph")
    if type(glyph) == "string" and glyph ~= "" then
        return glyph
    end
    return "shield-exclamation"
end

local function is_clean()
    return snapshot ~= nil
        and snapshot.phase == "clean"
        and not snapshot.binaryMissing
        and not snapshot.err
end

local function status_label()
    if snapshot == nil then
        return tr("widget.state.idle")
    end
    if snapshot.phase == "checking" then
        return tr("widget.state.checking")
    end
    if snapshot.binaryMissing then
        return tr("widget.state.missing")
    end
    if snapshot.err then
        return tr("widget.state.error")
    end
    if (snapshot.total or 0) > 0 then
        return noctalia.trp("widget.state.ready", snapshot.total)
    end
    if snapshot.phase == "clean" then
        return tr("widget.state.clean")
    end
    return tr("widget.state.idle")
end

local function counts_label()
    local counts = snapshot ~= nil and snapshot.counts or {}
    local parts = {}
    for _, severity in ipairs(audit.SEVERITIES) do
        local count = tonumber(counts[severity]) or 0
        if count > 0 then
            table.insert(parts, count .. " " .. tr("severity." .. severity):lower())
        end
    end
    if #parts == 0 then
        return tr("widget.counts_none")
    end
    return table.concat(parts, " · ")
end

local function checked_label()
    if snapshot == nil or snapshot.checkedAtMs == nil then
        return tr("time.never")
    end
    return audit.age_text(snapshot.checkedAtMs, tr, noctalia.trp)
end

local function glyph_color()
    if snapshot == nil then
        return "on_surface_variant"
    end
    if snapshot.binaryMissing or snapshot.err then
        return "error"
    end
    if snapshot.phase == "checking" then
        return "secondary"
    end
    if (snapshot.total or 0) > 0 then
        return audit.severity_color(snapshot.severity)
    end
    if snapshot.phase == "clean" then
        return "on_surface"
    end
    return "on_surface_variant"
end

local function glyph_name()
    if snapshot == nil then
        return configured_glyph()
    end
    if snapshot.binaryMissing or snapshot.err then
        return "shield-x"
    end
    if is_clean() then
        return "shield-check"
    end
    return configured_glyph()
end

local function render()
    barWidget.setGlyph(glyph_name())
    barWidget.setGlyphColor(glyph_color())

    local show_count = noctalia.getConfig("show_count") == true
    local count_text = ""
    if show_count then
        if (snapshot ~= nil and (snapshot.total or 0) > 0) then
            count_text = tostring(snapshot.total)
        elseif snapshot ~= nil and (snapshot.binaryMissing or snapshot.err) then
            count_text = "!"
        end
    end
    barWidget.setText(count_text)

    local hide_on_clean = noctalia.getConfig("hide_on_clean") == true
    barWidget.setVisible(not (hide_on_clean and is_clean()))

    local rows = {
        { key = tr("widget.tooltip.status"), value = status_label() },
        { key = tr("widget.tooltip.severities"), value = counts_label() },
    }
    if snapshot ~= nil and (tonumber(snapshot.newCount) or 0) > 0 then
        table.insert(rows, {
            key = tr("widget.tooltip.new"),
            value = noctalia.trp("widget.tooltip.new_value", snapshot.newCount),
        })
    end
    table.insert(rows, { key = tr("widget.tooltip.checked"), value = checked_label() })
    table.insert(rows, { key = "", value = tr("widget.tooltip.hint") })
    barWidget.setTooltip(rows)
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    request_check()
end

-- Slow tick only as a safety net for settings changes; the state watch does
-- the real work. One render a minute is free.
function update()
    render()
end

noctalia.setUpdateInterval(60000)
snapshot = noctalia.state.get(STATE_KEY)
render()
