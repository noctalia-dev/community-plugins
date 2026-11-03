--!nonstrict
-- Mic Denoise - control-center quick-toggle tile.
--
-- Thin client: renders the service's "status" and writes "command". It keeps no
-- state of its own, so a tile, a bar widget and IPC all stay in sync.

local on = false

local function applyStatus(st)
    local known = type(st) == "table"
    on = known and st.enabled == true

    shortcut.setLabel(on and noctalia.tr("shortcut.label-on") or noctalia.tr("shortcut.label-off"))
    shortcut.setIcon("microphone", "microphone-off")
    shortcut.setActive(on)
    -- Stay clickable even when the virtual source is missing: clicking runs the
    -- backend, which reports the real reason instead of leaving a dead tile.
    shortcut.setEnabled(true)
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)

-- Send the absolute target instead of a relative toggle: idempotent, so two
-- rapid clicks cannot race into an inverted state.
function onClick()
    noctalia.state.set("command", { action = on and "off" or "on", seq = noctalia.nowMs() })
end

-- Right click opens the plugin settings, where the microphone is configured.
function onRightClick()
    noctalia.openSettings()
end
