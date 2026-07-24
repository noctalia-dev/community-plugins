--!nonstrict
-- Tailscale panel — the [[panel]] entry.
--
-- Header with connection state + up/down and refresh buttons, this node's
-- name/IP with copy buttons, a filter input, then the peer list (online
-- first) with per-row copy-IP / copy-name buttons and an exit-node toggle on
-- peers that offer it.
--
-- Per-row buttons use the predeclared-slot pattern (onIp0…, onName0…,
-- onExit0…): ui.* callbacks are global function names, so each row binds its
-- peer into a slot table the numbered globals read back.

local MAX_SLOTS = 24

local snapshot = nil
local isOpen = false
local cmdNonce = 0
local filterText = ""
local slots = {}

local OS_GLYPHS = {
  linux = "device-desktop",
  windows = "device-desktop",
  macos = "device-laptop",
  ios = "device-mobile",
  android = "device-mobile",
}

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
  noctalia.state.set("ts.cmd", noctalia.json.encode(cmd))
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
      glyph = "refresh",
      variant = "outline",
      controlSize = "sm",
      tooltip = tr("panel.refresh"),
      onClick = "onRefresh",
    }),
  })
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

local function peerRow(peer, slot)
  slots[slot] = peer
  local dotColor = peer.online and "primary" or "outline"
  local buttons = {
    ui.button({
      glyph = "copy",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.ip ~= "",
      tooltip = tr("panel.copy-ip-value", { value = peer.ip }),
      onClick = "onIp" .. slot,
    }),
    ui.button({
      glyph = "tag",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.shortName ~= "",
      tooltip = tr("panel.copy-name-value", { value = peer.shortName }),
      onClick = "onName" .. slot,
    }),
    ui.button({
      glyph = "activity",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.online and peer.ip ~= "",
      tooltip = tr("panel.ping"),
      onClick = "onPing" .. slot,
    }),
    ui.button({
      glyph = "terminal-2",
      variant = "ghost",
      controlSize = "sm",
      enabled = peer.online and peer.shortName ~= "",
      tooltip = tr("panel.ssh"),
      onClick = "onSsh" .. slot,
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
      onClick = "onExit" .. slot,
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
    local slot = 0
    for _, peer in snapshot.peers do
      if slot >= MAX_SLOTS then
        break
      end
      if matchesFilter(peer) then
        table.insert(rows, peerRow(peer, slot))
        slot += 1
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
  slots = {}
  local children = { header() }
  local login = needsLoginBox()
  if login then
    table.insert(children, login)
  end
  local selfR = selfRow()
  if selfR then
    table.insert(children, selfR)
  end
  local exitR = exitNodeRow()
  if exitR then
    table.insert(children, exitR)
  end
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
  panel.render(ui.column({ gap = 10, padding = 14, height = 540 }, children))
end

-- ── Lifecycle & callbacks ────────────────────────────────────────────────────

noctalia.state.watch("ts.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function onOpen(_context)
  isOpen = true
  local encoded = noctalia.state.get("ts.snapshot")
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

local function ipAt(slot)
  local peer = slots[slot]
  if peer then
    copyValue(peer.ip, peer.name, false)
  end
end

local function nameAt(slot)
  local peer = slots[slot]
  if peer then
    copyValue(peer.shortName, peer.name, true)
  end
end

local function exitAt(slot)
  local peer = slots[slot]
  if not peer then
    return
  end
  if peer.exitNode then
    sendCmd("exit_clear")
  elseif peer.ip ~= "" then
    sendCmd("exit_set", { ip = peer.ip })
  end
end

local function pingAt(slot)
  local peer = slots[slot]
  if peer and peer.ip ~= "" then
    sendCmd("ping", { ip = peer.ip, name = peer.name })
  end
end

local function sshAt(slot)
  local peer = slots[slot]
  if not peer or peer.shortName == "" then
    return
  end
  local user = noctalia.string.trim(noctalia.getConfig("ssh_username") or "")
  local target = user ~= "" and `{user}@{peer.shortName}` or peer.shortName
  noctalia.runInTerminal(`ssh {target}`)
end

function onPing0() pingAt(0) end
function onPing1() pingAt(1) end
function onPing2() pingAt(2) end
function onPing3() pingAt(3) end
function onPing4() pingAt(4) end
function onPing5() pingAt(5) end
function onPing6() pingAt(6) end
function onPing7() pingAt(7) end
function onPing8() pingAt(8) end
function onPing9() pingAt(9) end
function onPing10() pingAt(10) end
function onPing11() pingAt(11) end
function onPing12() pingAt(12) end
function onPing13() pingAt(13) end
function onPing14() pingAt(14) end
function onPing15() pingAt(15) end
function onPing16() pingAt(16) end
function onPing17() pingAt(17) end
function onPing18() pingAt(18) end
function onPing19() pingAt(19) end
function onPing20() pingAt(20) end
function onPing21() pingAt(21) end
function onPing22() pingAt(22) end
function onPing23() pingAt(23) end

function onSsh0() sshAt(0) end
function onSsh1() sshAt(1) end
function onSsh2() sshAt(2) end
function onSsh3() sshAt(3) end
function onSsh4() sshAt(4) end
function onSsh5() sshAt(5) end
function onSsh6() sshAt(6) end
function onSsh7() sshAt(7) end
function onSsh8() sshAt(8) end
function onSsh9() sshAt(9) end
function onSsh10() sshAt(10) end
function onSsh11() sshAt(11) end
function onSsh12() sshAt(12) end
function onSsh13() sshAt(13) end
function onSsh14() sshAt(14) end
function onSsh15() sshAt(15) end
function onSsh16() sshAt(16) end
function onSsh17() sshAt(17) end
function onSsh18() sshAt(18) end
function onSsh19() sshAt(19) end
function onSsh20() sshAt(20) end
function onSsh21() sshAt(21) end
function onSsh22() sshAt(22) end
function onSsh23() sshAt(23) end

function onIp0() ipAt(0) end
function onIp1() ipAt(1) end
function onIp2() ipAt(2) end
function onIp3() ipAt(3) end
function onIp4() ipAt(4) end
function onIp5() ipAt(5) end
function onIp6() ipAt(6) end
function onIp7() ipAt(7) end
function onIp8() ipAt(8) end
function onIp9() ipAt(9) end
function onIp10() ipAt(10) end
function onIp11() ipAt(11) end
function onIp12() ipAt(12) end
function onIp13() ipAt(13) end
function onIp14() ipAt(14) end
function onIp15() ipAt(15) end
function onIp16() ipAt(16) end
function onIp17() ipAt(17) end
function onIp18() ipAt(18) end
function onIp19() ipAt(19) end
function onIp20() ipAt(20) end
function onIp21() ipAt(21) end
function onIp22() ipAt(22) end
function onIp23() ipAt(23) end

function onName0() nameAt(0) end
function onName1() nameAt(1) end
function onName2() nameAt(2) end
function onName3() nameAt(3) end
function onName4() nameAt(4) end
function onName5() nameAt(5) end
function onName6() nameAt(6) end
function onName7() nameAt(7) end
function onName8() nameAt(8) end
function onName9() nameAt(9) end
function onName10() nameAt(10) end
function onName11() nameAt(11) end
function onName12() nameAt(12) end
function onName13() nameAt(13) end
function onName14() nameAt(14) end
function onName15() nameAt(15) end
function onName16() nameAt(16) end
function onName17() nameAt(17) end
function onName18() nameAt(18) end
function onName19() nameAt(19) end
function onName20() nameAt(20) end
function onName21() nameAt(21) end
function onName22() nameAt(22) end
function onName23() nameAt(23) end

function onExit0() exitAt(0) end
function onExit1() exitAt(1) end
function onExit2() exitAt(2) end
function onExit3() exitAt(3) end
function onExit4() exitAt(4) end
function onExit5() exitAt(5) end
function onExit6() exitAt(6) end
function onExit7() exitAt(7) end
function onExit8() exitAt(8) end
function onExit9() exitAt(9) end
function onExit10() exitAt(10) end
function onExit11() exitAt(11) end
function onExit12() exitAt(12) end
function onExit13() exitAt(13) end
function onExit14() exitAt(14) end
function onExit15() exitAt(15) end
function onExit16() exitAt(16) end
function onExit17() exitAt(17) end
function onExit18() exitAt(18) end
function onExit19() exitAt(19) end
function onExit20() exitAt(20) end
function onExit21() exitAt(21) end
function onExit22() exitAt(22) end
function onExit23() exitAt(23) end
