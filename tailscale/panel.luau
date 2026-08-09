--!nonstrict
-- Tailscale manager panel.

local STATE_KEY = "ts_snapshot"
local COMMAND_KEY = "ts_command"
local RESULT_KEY = "ts_action_result"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  configured = false,
  loading = true,
  busy = false,
  installed = false,
  backendState = "",
  running = false,
  hostname = "",
  dnsName = "",
  ipv4 = "",
  ipv6 = "",
  tailnet = "",
  peers = {},
  exitNodes = {},
  onlineCount = 0,
  peerCount = 0,
  exitNode = "",
  shieldsUp = false,
  acceptRoutes = false,
  runSSH = false,
  acceptDNS = false,
  advertiseExitNode = false,
  exitNodeAllowLAN = false,
  health = {},
  error = "",
  updatedAt = 0,
  revision = 0,
}

local tab = "status" -- status | peers | exit
local selectedId = ""
local filterText = ""
local filterKey = 0
local requestCounter = 0
local feedback = ""
local feedbackError = false
local dirty = true

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function send(action, values)
  local command = { action = action, requestId = nextRequestId() }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
  return command.requestId
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function haystackContains(needle, ...)
  if needle == "" then return true end
  for i = 1, select("#", ...) do
    local part = lower(select(i, ...))
    if part ~= "" and part:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function matchesFilter(...)
  local q = noctalia.string.trim(filterText)
  if q == "" then return true end
  for raw in q:gmatch("%S+") do
    local neg = false
    local term = raw
    if term:sub(1, 1) == "!" then
      neg = true
      term = term:sub(2)
    end
    term = lower(term)
    if term ~= "" then
      local hit = haystackContains(term, ...)
      if neg then
        if hit then return false end
      else
        if not hit then return false end
      end
    end
  end
  return true
end

local function formatBytes(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.1fG", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
  return tostring(math.floor(n))
end

-- Connected = green; stopped = grey. Never primary (yellow) or error (red).
local COLOR_OK = "#73c936"
local COLOR_OFF = "#8a8a8a"

local function statusColor(ok)
  return (ok == true) and COLOR_OK or COLOR_OFF
end

-- Title/status: official-style Tailscale brand mark (3×3 dots), green/grey by state.
local function statusIcon(running, size)
  size = size or 24
  local ok = running == true
  return ui.image({
    path = ok and "assets/tailscale-green.png" or "assets/tailscale-grey.png",
    width = size,
    height = size,
    fit = "contain",
  })
end

local function listButton(props)
  props.contentAlign = "start"
  props.controlSize = props.controlSize or "md"
  return ui.button(props)
end

-- Toggle chip: fixed label; primary when on, outline when off (no selected —
-- selected can collapse the control to glyph-only in dense toolbars).
local function stateToggle(props)
  local on = props.on == true
  local text = props.label
  if type(text) ~= "string" or text == "" then
    text = "—"
  end
  return ui.button({
    text = text,
    glyph = props.glyph,
    variant = on and "primary" or "outline",
    enabled = props.enabled ~= false,
    onClick = props.onClick,
  })
end

local function selectedPeer()
  if tab ~= "peers" then return nil end
  for _, p in ipairs(snapshot.peers or {}) do
    if p.id == selectedId then return p end
  end
  return nil
end

local function selectedExit()
  if tab ~= "exit" then return nil end
  for _, e in ipairs(snapshot.exitNodes or {}) do
    if e.id == selectedId then return e end
  end
  return nil
end

local function emptyList(msg)
  return ui.column({
    key = "empty-" .. tab,
    align = "center",
    justify = "center",
    padding = 24,
    gap = 8,
    flexGrow = 1,
  }, {
    ui.glyph({ name = "search", size = 36, color = "on_surface_variant" }),
    ui.label({ text = msg, color = "on_surface_variant", textAlign = "center" }),
  })
end

local function itemColumn(rows)
  return ui.column({
    key = "items-" .. tab,
    align = "stretch",
    justify = "start",
    gap = 8,
    flexGrow = 1,
  }, rows)
end

local function onOff(v)
  return v and tr("status.on") or tr("status.off")
end

local function statusRows()
  local rows = {}
  local items = {
    {
      id = "st-state",
      glyph = snapshot.running and "network" or "network-off",
      text = tr("status.state", { state = snapshot.backendState ~= "" and snapshot.backendState or "—" }),
      ok = snapshot.running == true,
    },
    {
      id = "st-tailnet",
      glyph = "world",
      text = tr("status.tailnet", { name = snapshot.tailnet ~= "" and snapshot.tailnet or "—" }),
      ok = true,
    },
    {
      id = "st-ips",
      glyph = "network",
      text = tr("status.ips", {
        v4 = snapshot.ipv4 ~= "" and snapshot.ipv4 or "—",
        v6 = snapshot.ipv6 ~= "" and snapshot.ipv6 or "",
      }),
      ok = true,
    },
    {
      id = "st-dns",
      glyph = "world-www",
      text = tr("status.dns", { dns = snapshot.dnsName ~= "" and snapshot.dnsName or "—" }),
      ok = true,
    },
    {
      id = "st-exit",
      glyph = "world",
      text = tr("status.exit", {
        name = (snapshot.exitNode ~= "" and snapshot.exitNode) or tr("status.none"),
      }),
      ok = snapshot.exitNode == "" or snapshot.exitNodeOnline,
    },
    {
      id = "st-prefs",
      glyph = "settings",
      text = tr("status.prefs", {
        shields = onOff(snapshot.shieldsUp),
        routes = onOff(snapshot.acceptRoutes),
        ssh = onOff(snapshot.runSSH),
        dns = onOff(snapshot.acceptDNS),
      }),
      ok = true,
    },
  }
  if snapshot.version and snapshot.version ~= "" then
    table.insert(items, {
      id = "st-ver",
      glyph = "info-circle",
      text = tr("status.version", { version = snapshot.version }),
      ok = true,
    })
  end
  for _, h in ipairs(snapshot.health or {}) do
    table.insert(items, {
      id = "st-health-" .. tostring(#items),
      glyph = "alert-triangle",
      text = tr("panel.health", { msg = h }),
      ok = false,
    })
  end

  for _, item in ipairs(items) do
    if matchesFilter(item.text) then
      local selected = item.id == selectedId
      table.insert(rows, listButton({
        key = item.id,
        text = item.text,
        glyph = item.glyph,
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = item.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function peerRows()
  local rows = {}
  for _, p in ipairs(snapshot.peers or {}) do
    local onlineTag = p.online and "online" or "offline"
    local exitTag = p.exitNodeOption and "exit" or ""
    if matchesFilter(p.name, p.hostName, p.dnsName, p.ipv4, p.os, p.relay, onlineTag, exitTag) then
      local selected = p.id == selectedId
      local text = `{p.name}  ·  {p.online and "online" or "offline"}  ·  {p.ipv4}`
        .. (p.exitNodeOption and "  ·  exit" or "")
        .. (p.active and "  ·  active" or "")
      table.insert(rows, listButton({
        key = "peer-" .. p.id,
        text = text,
        glyph = p.online and "device-desktop" or "device-desktop-off",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = p.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function exitRows()
  local rows = {}
  for _, e in ipairs(snapshot.exitNodes or {}) do
    if matchesFilter(e.name, e.host, e.ip, e.status) then
      local selected = e.id == selectedId
      local text = `{e.name}  ·  {e.ip}`
        .. (e.selected and "  ·  selected" or "")
        .. (e.online and "" or "  ·  offline")
      table.insert(rows, listButton({
        key = "exit-" .. e.id,
        text = text,
        glyph = e.selected and "world" or "world-off",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = e.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function itemList()
  local rows
  if tab == "status" then
    rows = statusRows()
  elseif tab == "peers" then
    rows = peerRows()
  else
    rows = exitRows()
  end
  if #rows == 0 then
    return emptyList(tr("panel.empty"))
  end
  return itemColumn(rows)
end

local function toolbar()
  local busy = snapshot.busy == true

  if tab == "status" then
    local up = snapshot.running == true
    return ui.column({ gap = 6, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.row({ gap = 8, align = "center" }, {
        statusIcon(up, 18),
        ui.label({
          text = snapshot.hostname ~= "" and snapshot.hostname or "Tailscale",
          fontWeight = "bold",
          flexGrow = 1,
          maxLines = 1,
        }),
        ui.label({
          text = snapshot.backendState ~= "" and snapshot.backendState or "—",
          color = statusColor(up),
          fontSize = 12,
        }),
      }),
      ui.row({ gap = 6 }, {
        ui.button({
          text = tr("actions.up"),
          glyph = "player-play",
          variant = "primary",
          enabled = not busy and not snapshot.running,
          onClick = "onUp",
        }),
        ui.button({
          text = tr("actions.down"),
          glyph = "player-stop",
          variant = "outline",
          enabled = not busy and snapshot.running,
          onClick = "onDown",
        }),
        stateToggle({
          on = snapshot.shieldsUp == true,
          label = tr("actions.shields_on"),
          glyph = "shield",
          enabled = not busy,
          onClick = "onToggleShields",
        }),
        stateToggle({
          on = snapshot.runSSH == true,
          label = tr("actions.ssh_on"),
          glyph = "terminal-2",
          enabled = not busy,
          onClick = "onToggleSSH",
        }),
      }),
      ui.row({ gap = 6 }, {
        stateToggle({
          on = snapshot.acceptRoutes == true,
          label = tr("actions.routes_on"),
          glyph = "route",
          enabled = not busy,
          onClick = "onToggleRoutes",
        }),
        stateToggle({
          on = snapshot.advertiseExitNode == true,
          label = tr("actions.advertise_on"),
          glyph = "world-upload",
          enabled = not busy,
          onClick = "onToggleAdvertise",
        }),
        stateToggle({
          on = snapshot.exitNodeAllowLAN == true,
          label = tr("actions.lan_on"),
          glyph = "home",
          enabled = not busy,
          onClick = "onToggleLAN",
        }),
        ui.button({
          text = tr("actions.copy_ip"),
          glyph = "copy",
          variant = "ghost",
          enabled = snapshot.ipv4 ~= "",
          onClick = "onCopySelfIp",
        }),
      }),
    })
  end

  if tab == "peers" then
    local p = selectedPeer()
    if not p then
      return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
    end
    return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({
          name = p.online and "device-desktop" or "device-desktop-off",
          size = 18,
          color = statusColor(p.online),
        }),
        ui.label({ text = p.name, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
        ui.label({
          text = p.online and "online" or "offline",
          color = statusColor(p.online),
          fontSize = 12,
        }),
      }),
      ui.label({
        text = tr("peer.detail", {
          os = p.os ~= "" and p.os or "—",
          relay = p.relay ~= "" and p.relay or "—",
          v4 = p.ipv4 ~= "" and p.ipv4 or "—",
        }),
        color = "on_surface_variant",
        fontSize = 12,
        maxLines = 2,
      }),
      ui.label({
        text = p.dnsName,
        color = "on_surface_variant",
        fontSize = 11,
        visible = p.dnsName ~= "",
        maxLines = 1,
      }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("actions.ping"), glyph = "activity", variant = "primary", enabled = not busy, onClick = "onPing" }),
        ui.button({ text = tr("actions.ssh"), glyph = "terminal-2", variant = "outline", enabled = not busy, onClick = "onSSH" }),
        ui.button({ text = tr("actions.copy_ip"), glyph = "copy", variant = "ghost", enabled = p.ipv4 ~= "", onClick = "onCopyPeerIp" }),
        ui.button({ text = tr("actions.copy_dns"), glyph = "copy", variant = "ghost", enabled = p.dnsName ~= "", onClick = "onCopyPeerDns" }),
        ui.button({
          text = tr("actions.use_exit"),
          glyph = "world",
          variant = "ghost",
          enabled = not busy and p.exitNodeOption,
          visible = p.exitNodeOption == true,
          onClick = "onUsePeerExit",
        }),
      }),
    })
  end

  -- exit nodes tab
  local e = selectedExit()
  if not e then
    return ui.column({ gap = 6, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" }),
      ui.row({ gap = 6 }, {
        ui.button({
          text = tr("actions.clear_exit"),
          glyph = "x",
          variant = "outline",
          enabled = not busy and snapshot.exitNode ~= "",
          onClick = "onClearExit",
        }),
      }),
    })
  end
  return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "world", size = 18, color = statusColor(e.online) }),
      ui.label({ text = e.name, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = e.selected and "selected" or (e.online and "available" or "offline"),
        color = e.selected and "primary" or statusColor(e.online),
        fontSize = 12,
      }),
    }),
    ui.label({
      text = tr("exit.detail", { ip = e.ip, status = e.status ~= "" and e.status or "—" }),
      color = "on_surface_variant",
      fontSize = 12,
      maxLines = 2,
    }),
    ui.row({ gap = 6 }, {
      ui.button({
        text = tr("actions.use_exit"),
        glyph = "world",
        variant = "primary",
        enabled = not busy and not e.selected,
        onClick = "onUseExit",
      }),
      ui.button({
        text = tr("actions.clear_exit"),
        glyph = "x",
        variant = "outline",
        enabled = not busy and (e.selected or snapshot.exitNode ~= ""),
        onClick = "onClearExit",
      }),
      ui.button({
        text = tr("actions.copy_ip"),
        glyph = "copy",
        variant = "ghost",
        onClick = "onCopyExitIp",
      }),
    }),
  })
end

local function tabButton(label, id, cb)
  return ui.button({
    text = label,
    selected = tab == id,
    variant = tab == id and "primary" or "ghost",
    onClick = cb,
  })
end

render = function()
  dirty = false
  local notes = {}
  if not snapshot.installed then
    table.insert(notes, ui.label({ text = tr("panel.not_installed"), color = "error", maxLines = 3 }))
  end
  if snapshot.loading then
    table.insert(notes, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end
  if snapshot.busy then
    table.insert(notes, ui.label({ text = tr("panel.busy"), color = "primary" }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(notes, ui.label({ text = snapshot.error, color = "error", maxLines = 3 }))
  end
  if feedback ~= "" then
    table.insert(notes, ui.label({
      text = feedback,
      color = feedbackError and "error" or "tertiary",
      maxLines = 2,
    }))
  end

  local exitLabel = snapshot.exitNode ~= "" and snapshot.exitNode or "—"
  local summary = tr("panel.summary", {
    state = snapshot.backendState ~= "" and snapshot.backendState or "—",
    online = snapshot.onlineCount or 0,
    total = snapshot.peerCount or 0,
    exit = exitLabel,
  })

  -- Title row: large status indicator next to "Tailscale"
  local titleUp = snapshot.running == true
  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 10 }, {
      statusIcon(titleUp, 28),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({
          text = tr("panel.host", {
            host = snapshot.hostname ~= "" and snapshot.hostname
              or (snapshot.tailnet ~= "" and snapshot.tailnet or "—"),
          }) .. (snapshot.ipv4 ~= "" and (` · {snapshot.ipv4}`) or ""),
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.button({ text = tr("actions.open_admin"), glyph = "external-link", variant = "outline", onClick = "onAdmin" }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),

    ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tabs.status"), "status", "onTabStatus"),
      tabButton(tr("tabs.peers"), "peers", "onTabPeers"),
      tabButton(tr("tabs.exit"), "exit", "onTabExit"),
    }),

    ui.label({
      text = summary,
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = `filter-{tab}-{filterKey}`,
        value = filterText,
        placeholder = tr("filter.placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = "onFilterChange",
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        visible = filterText ~= "",
        onClick = "onClearFilter",
      }),
    }),

    toolbar(),
    ui.column({ gap = 3, align = "stretch" }, notes),
    ui.scroll({
      key = "scroll-" .. tab,
      flexGrow = 1,
      gap = 8,
      align = "stretch",
    }, { itemList() }),
    ui.label({
      text = (snapshot.updatedAt or 0) > 0
        and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", snapshot.updatedAt) })
        or "",
      color = "on_surface_variant",
      fontSize = 11,
    }),
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then return end
  -- Always re-render: toggle flags (routes, advertise exit, LAN, …) live on the snapshot.
  snapshot = value
  if selectedId ~= "" then
    if tab == "peers" and not selectedPeer() then
      selectedId = ""
    elseif tab == "exit" and not selectedExit() then
      selectedId = ""
    end
  end
  dirty = true
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then return end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then return end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  dirty = true
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  feedback = ""
  send("refresh")
  render()
end

function update()
  if dirty then render() end
end

function onClose() panel.close() end
function onRefresh() send("refresh") end
function onAdmin() send("open_admin") end
function onUp() send("up") end
function onDown() send("down") end

function onToggleShields()
  send("set_shields", { enabled = not snapshot.shieldsUp })
end
function onToggleSSH()
  send("set_ssh", { enabled = not snapshot.runSSH })
end
function onToggleRoutes()
  send("set_accept_routes", { enabled = not snapshot.acceptRoutes })
end
function onToggleAdvertise()
  -- Explicit next state: prefs AdvertiseRoutes default routes mean "on".
  local nextOn = not (snapshot.advertiseExitNode == true)
  send("set_advertise_exit", { enabled = nextOn })
end
function onToggleLAN()
  send("set_allow_lan", { enabled = not snapshot.exitNodeAllowLAN })
end

function onCopySelfIp()
  if snapshot.ipv4 ~= "" then
    send("copy", { text = snapshot.ipv4 })
  end
end

function onPing()
  local p = selectedPeer()
  if p then
    send("ping", { host = p.ipv4 ~= "" and p.ipv4 or p.name })
  end
end
function onSSH()
  local p = selectedPeer()
  if p then
    send("ssh", { host = p.dnsName ~= "" and p.dnsName or p.name })
  end
end
function onCopyPeerIp()
  local p = selectedPeer()
  if p and p.ipv4 ~= "" then
    send("copy", { text = p.ipv4 })
  end
end
function onCopyPeerDns()
  local p = selectedPeer()
  if p and p.dnsName ~= "" then
    send("copy", { text = p.dnsName })
  end
end
function onUsePeerExit()
  local p = selectedPeer()
  if p then
    send("set_exit_node", { node = p.ipv4 ~= "" and p.ipv4 or p.name })
  end
end

function onUseExit()
  local e = selectedExit()
  if e then
    send("set_exit_node", { node = e.ip })
  end
end
function onClearExit()
  send("clear_exit_node")
end
function onCopyExitIp()
  local e = selectedExit()
  if e then
    send("copy", { text = e.ip })
  end
end

local function switchTab(next)
  tab = next
  selectedId = ""
  filterKey += 1
  render()
end

function onTabStatus() switchTab("status") end
function onTabPeers() switchTab("peers") end
function onTabExit() switchTab("exit") end

function onFilterChange(value)
  filterText = if type(value) == "string" then value else ""
  render()
end

function onClearFilter()
  filterText = ""
  filterKey += 1
  render()
end
