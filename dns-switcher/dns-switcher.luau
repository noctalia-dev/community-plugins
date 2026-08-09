--!nonstrict
-- dns-switcher — bar widget: renders the state published by the service
-- entry (service.luau).
--
-- Click mapping is declared in plugin.toml's [widget.actions] (plugin_api >=
-- 14), not hard-coded here, so the user can remap it from the bar's own
-- gesture settings like any built-in widget:
--   Left click    — panel-toggle nightwatch75/dns-switcher:panel
--   Right click   — plugin nightwatch75/dns-switcher:service all apply default
--   Scroll up/down — plugin nightwatch75/dns-switcher:service all cycle next/prev
--
-- No middle-click binding: every bar widget carries a built-in `middle`
-- binding that opens its own settings, and that default is exactly what's
-- wanted here.

local STATE_KEY = "dns_state" -- published by service.luau

local GLYPH_UNKNOWN = "globe"

local snapshot = nil -- last state published by the service

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function setLabel(text)
    if noctalia.getConfig("show_label") == false then
        barWidget.setText("")
    else
        barWidget.setText(text)
    end
end

local function paint(glyph, role, label)
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(role)
    barWidget.setColor(role)
    setLabel(label)
end

local function render()
    local s = snapshot
    if s == nil or (s.current == nil and s.error == nil) then
        paint(GLYPH_UNKNOWN, "on_surface", tr("status_checking"))
        barWidget.clearTooltip()
        return
    end
    if s.changing == true then
        paint("refresh", "secondary", tr("status_switching"))
        barWidget.setTooltip(tr("tooltip_switching"))
        return
    end
    if s.error ~= nil then
        paint(GLYPH_UNKNOWN, "error", s.error)
        barWidget.clearTooltip()
        return
    end
    local role = s.current.id ~= "default" and "primary" or "on_surface"
    paint(s.current.glyph, role, s.current.label)
    local servers = s.current.ip
    if servers == "" then
        servers = s.servers ~= "" and s.servers or tr("status_auto")
    end
    barWidget.setTooltip({
        { key = tr("tooltip_provider"), value = s.current.label },
        { key = tr("tooltip_servers"), value = servers },
        { key = tr("tooltip_actions"), value = tr("tooltip_hints") },
    })
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

snapshot = noctalia.state.get(STATE_KEY)
render()
