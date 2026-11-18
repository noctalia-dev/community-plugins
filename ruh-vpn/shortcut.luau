--!nonstrict
-- shortcut.luau — control-center tile: toggle the proxy on/off.

local nonce = 0
local function send(method, args)
  nonce = nonce + 1
  noctalia.state.set("cmd", { method = method, args = args or {}, nonce = tostring(nonce) .. ":" .. tostring(os.time()) })
end

local function refresh()
  local s = noctalia.state.get("status") or {}
  local running = s.running == true
  shortcut.setIcon(running and "lock" or "lock-open")
  shortcut.setLabel(running and noctalia.tr("shortcut.on") or noctalia.tr("shortcut.off"))
  shortcut.setActive(running)
end

function update() refresh() end

function onClick()
  local s = noctalia.state.get("status") or {}
  if s.running then
    send("StopProxy", {})
  else
    if s.activeServerId and s.activeServerId ~= "" then
      send("StartProxy", { s.activeServerId, s.mode or "rules", s.proxyMode or "system" })
    else
      noctalia.notifyError("VPN", noctalia.tr("error.no-server"))
    end
  end
end

noctalia.setUpdateInterval(2000)
