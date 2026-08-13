--!nonstrict
-- widget.luau — bar tile. Reads shared state published by service.luau.

local PANEL = "umedbazarov/ruh-vpn:vpn_panel"

local function activeName(status)
  if not status.running then return "VPN" end
  for _, sv in ipairs(noctalia.state.get("servers") or {}) do
    if sv.id == status.activeServerId then return sv.name or "VPN" end
  end
  return "VPN"
end

local function fmtBytes(n)
  n = tonumber(n) or 0
  if n < 1024 then return string.format("%dB", n) end
  local u = { "K", "M", "G", "T" }
  local i = 0
  repeat n = n / 1024; i = i + 1 until n < 1024 or i >= #u
  return string.format(n < 10 and "%.1f%s" or "%.0f%s", n, u[i])
end

function update()
  local s = noctalia.state.get("status") or {}
  local h = noctalia.state.get("health") or {}
  local running = s.running == true

  barWidget.setGlyph(running and "lock" or "lock-open")
  barWidget.setColor(running and "primary" or "on_surface_variant")

  local label = activeName(s)
  if noctalia.getConfig("show_ping") and running and h.latency_ms and h.latency_ms > 0 then
    label = label .. " · " .. tostring(h.latency_ms) .. "ms"
  end
  if noctalia.getConfig("show_traffic") and running then
    local t = noctalia.state.get("traffic") or {}
    label = label .. "  ↓" .. fmtBytes(t.bytes_received) .. " ↑" .. fmtBytes(t.bytes_sent)
  end
  barWidget.setText(label)
  barWidget.setTooltip(running and ("Connected — " .. activeName(s)) or "VPN off")
end

function onClick()
  noctalia.togglePanel(PANEL)
end

noctalia.setUpdateInterval(2000)
