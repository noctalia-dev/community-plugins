--!nonstrict
-- Tailscale panel — the [[panel]] entry.
--
-- Header with connection state + up/down and refresh buttons, this node's
-- name/IP with copy buttons, a filter input, then the peer list (online
-- first) with per-row copy-IP / copy-name buttons and an exit-node toggle on
-- peers that offer it.
--
-- Per-row buttons pass a closure that captures the row's peer, so the list has
-- no length limit and no numbered callback globals.

-- Must match height = … in the [[panel]] entry of plugin.toml: the root
-- column's height is what actually sizes the panel content.
local PANEL_HEIGHT = 540

local snapshot = nil
local isOpen = false
local cmdNonce = 0
local filterText = ""

local OS_GLYPHS = {
  linux = "device-desktop",
  windows = "device-desktop",
  macos = "device-laptop",
  ios = "device-mobile",
  android = "device-mobile",
}

-- The runtime only takes a command *line*, so every dynamic argument has to be
-- shell-quoted by hand: wrap in single quotes and escape embedded ones.
local function shq(value)
  local quoted = tostring(value or ""):gsub("'", "'\\''")
  return `'{quoted}'`
end

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function sendCmd(action, extra)
  cmdNonce += 1
  local cmd = { n = cmdNonce, action = action }
  if extra then
    for k, v in extra do
      cmd[k] = v
    end
  end
  noctalia.state.set("tn.cmd", noctalia.json.encode(cmd))
end

local function copyValue(value, name, isName)
  if value == "" then
    return
  end
  noctalia.copyToClipboard(value, "text/plain")
  noctalia.notify(tr("toast.title"),
    tr(isName and "toast.copied-name" or "toast.copied-ip", { host = name, value = value }))
end

local function stateOf()
  return snapshot and snapshot.state or "stopped"
end

local function setPref(pref, enabled)
  sendCmd("set_pref", { pref = pref, enabled = enabled })
end

-- ── Per-peer actions ─────────────────────────────────────────────────────────

local function copyPeerIp(peer)
  copyValue(peer.ip, peer.name, false)
end

local function copyPeerName(peer)
  copyValue(peer.shortName, peer.name, true)
end

local function togglePeerExitNode(peer)
  if peer.exitNode then
    sendCmd("exit_clear")
  elseif peer.ip ~= "" then
    sendCmd("exit_set", { ip = peer.ip })
  end
end

local function pingPeer(peer)
  if peer.ip ~= "" then
    sendCmd("ping", { ip = peer.ip, name = peer.name })
  end
end

local function sshPeer(peer)
  -- The Tailscale IP always works; the short name and the MagicDNS FQDN only
  -- resolve when MagicDNS is enabled, so the IP is the target and the name is
  -- just a fallback.
  local host = peer.ip ~= "" and peer.ip or peer.shortName
  if host == "" then
    return
  end
  local user = noctalia.string.trim(noctalia.getConfig("ssh_username") or "")
  -- Only a plain login name is accepted; anything else is ignored rather than
  -- interpolated into the command line.
  if user ~= "" and not user:match("^[%w%._%-]+$") then
    noctalia.notifyError(tr("toast.title"), tr("toast.invalid-username"))
    return
  end
  local target = user ~= "" and `{user}@{host}` or host
  noctalia.runInTerminal(`ssh {shq(target)}`)
end

-- ── Sections ─────────────────────────────────────────────────────────────────

local function header()
  local state = stateOf()
  local running = state == "running"
  local stateColor = running and "primary" or (state == "stopped" and "outline" or "error")
  return ui.row({ gap = 8, align = "center" }, {
    ui.image({
      path = noctalia.isDarkMode() and "icon.svg" or "icon-light.svg",
      width = 20,
      height = 20,
      fit = "contain",
    }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = tr(`state.{state}`), fontSize = 12, color = stateColor }),
    }),
    ui.button({
      glyph = "download",
      variant = "ghost",
      controlSize = "sm",
      enabled = running,
      tooltip = tr("panel.taildrop"),
      onClick = "onTaildrop",
    }),
    ui.button({
      glyph = running and "plug-connected-x" or "plug-connected",
      variant = running and "outline" or "primary",
      controlSize = "sm",
      enabled = state == "running" or state == "stopped",
      tooltip = running and tr("panel.disconnect") or tr("panel.connect"),
      onClick = running and "onDown" or "onUp",
    }),
    ui.button({
      glyph = "external-link",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.admin"),
      onClick = "onAdmin",
    }),
    ui.button({
      glyph = "refresh",
      variant = "outline",
      controlSize = "sm",
      tooltip = tr("panel.refresh"),
      onClick = "onRefresh",
    }),
  })
end

-- The five `tailscale set` toggles, as one row of icon buttons: a lit button
-- means the flag is on. Order matches how often they get touched.
-- `label` is the translation key: en.json segments have to be lowercase, so it
-- cannot just be the snapshot field name.
local PREFS = {
  { key = "shieldsUp", label = "shields-up", glyph = "shield" },
  { key = "acceptRoutes", label = "accept-routes", glyph = "route" },
  { key = "runSSH", label = "run-ssh", glyph = "server" },
  { key = "advertiseExitNode", label = "advertise-exit-node", glyph = "world-upload" },
  { key = "allowLanAccess", label = "allow-lan-access", glyph = "network" },
}

local function prefsRow()
  local prefs = snapshot and snapshot.prefs
  if not prefs then
    return nil
  end
  local buttons = {}
  for _, pref in PREFS do
    local on = prefs[pref.key] == true
    table.insert(buttons, ui.button({
      glyph = pref.glyph,
      variant = "ghost",
      controlSize = "sm",
      selected = on,
      flexGrow = 1,
      tooltip = `{tr(`pref.{pref.label}`)} — {tr(on and "pref.on" or "pref.off")}`,
      onClick = function()
        setPref(pref.key, not on)
      end,
    }))
  end
  return ui.row({ gap = 4 }, buttons)
end

local function healthBox()
  local health = snapshot and snapshot.health or {}
  if #health == 0 then
    return nil
  end
  local children = {}
  for _, warning in health do
    table.insert(children, ui.label({ text = warning, fontSize = 11, color = "error/0.9", maxLines = 3 }))
  end
  return ui.column({ gap = 3, padding = 8, fill = "error/0.1", radius = 8 }, children)
end

local function selfRow()
  if not snapshot or stateOf() ~= "running" then
    return nil
  end
  return ui.row({ gap = 8, padding = 8, align = "center", fill = "primary/0.12", radius = 8 }, {
    ui.glyph({ name = "home", size = 14, color = "primary" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = snapshot.self.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
      ui.label({ text = snapshot.self.ip, fontSize = 11, color = "on_surface/0.65", maxLines = 1 }),
    }),
    ui.button({
      glyph = "copy",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.copy-ip"),
      onClick = "onCopySelfIp",
    }),
    ui.button({
      glyph = "tag",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.copy-name"),
      onClick = "onCopySelfName",
    }),
  })
end

local function exitNodeRow()
  if not snapshot or not snapshot.exitNode then
    return nil
  end
  return ui.row({ gap = 8, padding = 8, align = "center", fill = "secondary/0.15", radius = 8 }, {
    ui.glyph({ name = "world", size = 14, color = "secondary" }),
    ui.label({
      text = tr("panel.exit-node-active", { name = snapshot.exitNode.name }),
      fontSize = 12,
      flexGrow = 1,
      maxLines = 1,
    }),
    ui.button({
      text = tr("panel.exit-node-clear"),
      variant = "outline",
      controlSize = "sm",
      onClick = "onExitClear",
    }),
  })
end

local function matchesFilter(peer)
  if filterText == "" then
    return true
  end
  local needle = filterText:lower()
  local haystack = (`{peer.name} {peer.ip} {peer.os}`):lower()
  return haystack:find(needle, 1, true) ~= nil
end

local function peerRow(peer)
  local dotColor = peer.online and "primary" or "outline"
  local buttons = {
    ui.button({
      glyph = "copy",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.ip ~= "",
      tooltip = tr("panel.copy-ip-value", { value = peer.ip }),
      onClick = function()
        copyPeerIp(peer)
      end,
    }),
    ui.button({
      glyph = "tag",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.shortName ~= "",
      tooltip = tr("panel.copy-name-value", { value = peer.shortName }),
      onClick = function()
        copyPeerName(peer)
      end,
    }),
    ui.button({
      glyph = "activity",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.online and peer.ip ~= "",
      tooltip = tr("panel.ping"),
      onClick = function()
        pingPeer(peer)
      end,
    }),
    ui.button({
      glyph = "terminal-2",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.online and peer.shortName ~= "",
      tooltip = tr("panel.ssh"),
      onClick = function()
        sshPeer(peer)
      end,
    }),
  }
  if peer.exitNodeOption then
    table.insert(buttons, ui.button({
      glyph = "world",
      variant = "ghost",
      controlSize = "sm",
      selected = peer.exitNode,
      enabled = peer.online or peer.exitNode,
      tooltip = peer.exitNode and tr("panel.exit-node-clear") or tr("panel.exit-node-use"),
      onClick = function()
        togglePeerExitNode(peer)
      end,
    }))
  end

  local children = {
    ui.box({ width = 8, height = 8, radius = 4, fill = dotColor }),
    ui.glyph({ name = OS_GLYPHS[peer.os:lower()] or "device-desktop", size = 14, color = "on_surface/0.7" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = peer.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
      ui.label({
        text = (function()
          local base = peer.ip ~= "" and peer.ip or (peer.online and tr("launcher.online") or tr("launcher.offline"))
          if not peer.online and peer.lastSeen and peer.lastSeen ~= "" then
            return `{base} · {tr("peer.last-seen", { value = peer.lastSeen })}`
          end
          return base
        end)(),
        fontSize = 11,
        color = "on_surface/0.65",
        maxLines = 1,
      }),
    }),
  }
  for _, b in buttons do
    table.insert(children, b)
  end

  return ui.row({
    key = `peer-{peer.shortName ~= "" and peer.shortName or peer.name}`,
    gap = 8,
    padding = 8,
    align = "center",
    fill = "surface_variant/0.5",
    radius = 8,
    opacity = peer.online and 1 or 0.6,
  }, children)
end

local function peerList()
  local rows = {}
  if snapshot and stateOf() == "running" then
    for _, peer in snapshot.peers do
      if matchesFilter(peer) then
        table.insert(rows, peerRow(peer))
      end
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = tr("panel.no-peers"), fontSize = 12, color = "on_surface/0.6" }))
  end
  return ui.scroll({ gap = 6, flexGrow = 1 }, rows)
end

local function needsLoginBox()
  if stateOf() ~= "needs-login" then
    return nil
  end
  return ui.column({ gap = 8, padding = 10, fill = "error/0.12", radius = 8 }, {
    ui.label({ text = tr("panel.needs-login"), fontSize = 12, maxLines = 3 }),
    ui.button({
      text = tr("panel.login"),
      variant = "primary",
      controlSize = "sm",
      enabled = snapshot ~= nil and snapshot.authUrl ~= "",
      onClick = "onLogin",
    }),
  })
end

local function render()
  if not isOpen then
    return
  end
  local children = { header() }
  -- Each of these returns nil when it has nothing to show, and a nil in the
  -- middle of an array literal would truncate the siblings after it.
  local function push(node)
    if node then
      table.insert(children, node)
    end
  end
  push(needsLoginBox())
  push(healthBox())
  push(selfRow())
  push(prefsRow())
  push(exitNodeRow())
  if snapshot and stateOf() == "running" then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "filter",
        value = filterText,
        placeholder = tr("panel.filter", { online = snapshot.online, total = snapshot.total }),
        controlSize = "sm",
        onChange = "onFilter",
        flexGrow = 1,
      }),
    }))
  end
  table.insert(children, peerList())
  if snapshot then
    table.insert(children, ui.label({
      text = tr("panel.last-check-info", { value = snapshot.checkedAt }),
      fontSize = 11,
      color = "on_surface/0.55",
    }))
  end
  -- height pins the root to the [[panel]] size so the scroll area actually
  -- scrolls instead of growing past the panel background
  panel.render(ui.column({ gap = 10, padding = 14, height = PANEL_HEIGHT }, children))
end

-- ── Lifecycle & callbacks ────────────────────────────────────────────────────

noctalia.state.watch("tn.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function onOpen(_context)
  isOpen = true
  local encoded = noctalia.state.get("tn.snapshot")
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
  sendCmd("refresh")
end

function onClose()
  isOpen = false
end

function onFilter(value)
  filterText = noctalia.string.trim(value)
  render()
end

function onRefresh()
  sendCmd("refresh")
end

function onUp()
  sendCmd("up")
end

function onDown()
  sendCmd("down")
end

function onLogin()
  if snapshot and snapshot.authUrl ~= "" then
    sendCmd("login", { url = snapshot.authUrl })
  end
end

function onExitClear()
  sendCmd("exit_clear")
end

function onTaildrop()
  sendCmd("taildrop_get")
end

function onAdmin()
  sendCmd("open_admin")
end

function onCopySelfIp()
  if snapshot then
    copyValue(snapshot.self.ip, snapshot.self.name, false)
  end
end

function onCopySelfName()
  if snapshot then
    copyValue(snapshot.self.dnsName, snapshot.self.name, true)
  end
end
