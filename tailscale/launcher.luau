--!nonstrict
-- /ts launcher: Tailscale peers, exit nodes, connect/disconnect.

local STATE_KEY = "ts_snapshot"
local COMMAND_KEY = "ts_command"
local PANEL_ID = "davemhammer/tailscale:manager"
local MAX_ROWS = 40

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  running = false,
  installed = false,
  peers = {},
  exitNodes = {},
  onlineCount = 0,
  peerCount = 0,
  backendState = "",
  exitNode = "",
  hostname = "",
  error = "",
}

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
  end
end)

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function send(action, values)
  local command = { action = action, requestId = "launcher-" .. tostring(os.time()) }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
end

local function scoreText(filter, ...)
  if filter == "" then
    return 1
  end
  local best = nil
  for i = 1, select("#", ...) do
    local text = tostring(select(i, ...) or "")
    if text ~= "" then
      local s = noctalia.fuzzyScore(filter, text)
      if s ~= nil and (best == nil or s > best) then
        best = s
      end
      if best == nil and lower(text):find(lower(filter), 1, true) then
        best = 0.5
      end
    end
  end
  return best
end

local function statusRow(title, subtitle, glyph)
  return {
    id = "",
    title = title,
    subtitle = subtitle,
    glyph = glyph or "circles",
  }
end

local function ensureSnapshot()
  if snapshot.loading or not snapshot.available then
    send("refresh")
  end
end

local function topCategories()
  local state = snapshot.backendState ~= "" and snapshot.backendState or "—"
  local summary = `{state} · {snapshot.onlineCount or 0}/{snapshot.peerCount or 0} online`
  if snapshot.exitNode and snapshot.exitNode ~= "" then
    summary = summary .. " · exit " .. snapshot.exitNode
  end
  return {
    {
      id = "cat:peers",
      title = noctalia.tr("launcher.cat.peers"),
      subtitle = noctalia.tr("launcher.cat.peers-sub"),
      glyph = "device-desktop",
      score = 100,
    },
    {
      id = "cat:exit",
      title = noctalia.tr("launcher.cat.exit"),
      subtitle = noctalia.tr("launcher.cat.exit-sub"),
      glyph = "world",
      score = 95,
    },
    {
      id = "act:status",
      title = noctalia.tr("launcher.cat.status"),
      subtitle = summary,
      glyph = "info-circle",
      score = 90,
    },
    {
      id = "act:up",
      title = noctalia.tr("launcher.cat.up"),
      subtitle = noctalia.tr("launcher.cat.up-sub"),
      glyph = "player-play",
      score = 85,
    },
    {
      id = "act:down",
      title = noctalia.tr("launcher.cat.down"),
      subtitle = noctalia.tr("launcher.cat.down-sub"),
      glyph = "player-stop",
      score = 80,
    },
    {
      id = "act:panel",
      title = noctalia.tr("launcher.cat.panel"),
      subtitle = noctalia.tr("launcher.cat.panel-sub"),
      glyph = "layout-dashboard",
      score = 70,
    },
    {
      id = "act:admin",
      title = noctalia.tr("launcher.cat.admin"),
      subtitle = noctalia.tr("launcher.cat.admin-sub"),
      glyph = "external-link",
      score = 60,
    },
    {
      id = "act:refresh",
      title = noctalia.tr("launcher.cat.refresh"),
      subtitle = noctalia.tr("launcher.cat.refresh-sub"),
      glyph = "refresh",
      score = 50,
    },
  }
end

local function peerActions(peer)
  local ref = peer.id
  return {
    {
      id = "peeract:ping:" .. ref,
      title = noctalia.tr("launcher.action.ping"),
      subtitle = peer.name .. " · " .. (peer.ipv4 ~= "" and peer.ipv4 or peer.dnsName),
      glyph = "activity",
      score = 100,
    },
    {
      id = "peeract:ssh:" .. ref,
      title = noctalia.tr("launcher.action.ssh"),
      subtitle = peer.dnsName ~= "" and peer.dnsName or peer.name,
      glyph = "terminal-2",
      score = 95,
    },
    {
      id = "peeract:copyip:" .. ref,
      title = noctalia.tr("launcher.action.copy_ip"),
      subtitle = peer.ipv4,
      glyph = "copy",
      score = 90,
    },
    {
      id = "peeract:copydns:" .. ref,
      title = noctalia.tr("launcher.action.copy_dns"),
      subtitle = peer.dnsName,
      glyph = "copy",
      score = 85,
    },
  }
end

local function findPeer(id)
  for _, p in ipairs(snapshot.peers or {}) do
    if p.id == id then return p end
  end
  return nil
end

local function findExit(id)
  for _, e in ipairs(snapshot.exitNodes or {}) do
    if e.id == id then return e end
  end
  return nil
end

local function listPeers(filter)
  local rows = {}
  for _, p in ipairs(snapshot.peers or {}) do
    local sc = scoreText(filter, p.name, p.hostName, p.dnsName, p.ipv4, p.os)
    if sc then
      table.insert(rows, {
        id = "peer:" .. p.id,
        title = p.name,
        subtitle = (p.online and "online" or "offline")
          .. (p.ipv4 ~= "" and (" · " .. p.ipv4) or "")
          .. (p.exitNodeOption and " · exit" or ""),
        glyph = p.online and "device-desktop" or "device-desktop-off",
        score = sc + (p.online and 10 or 0),
      })
    end
  end
  table.sort(rows, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  while #rows > MAX_ROWS do
    table.remove(rows)
  end
  return rows
end

local function listExits(filter)
  local rows = {
    {
      id = "act:clear-exit",
      title = noctalia.tr("launcher.action.clear_exit"),
      subtitle = snapshot.exitNode ~= "" and snapshot.exitNode or "—",
      glyph = "x",
      score = 200,
    },
  }
  for _, e in ipairs(snapshot.exitNodes or {}) do
    local sc = scoreText(filter, e.name, e.host, e.ip, e.status)
    if sc then
      table.insert(rows, {
        id = "exit:" .. e.id,
        title = e.name,
        subtitle = e.ip .. (e.selected and " · selected" or "") .. (e.online and "" or " · offline"),
        glyph = "world",
        score = sc + (e.selected and 20 or 0),
      })
    end
  end
  table.sort(rows, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  return rows
end

function search(query)
  ensureSnapshot()
  query = trim(query)

  if not snapshot.installed then
    launcher.setResults(query, { statusRow(noctalia.tr("launcher.missing"), "", "alert-triangle") })
    return
  end

  if snapshot.loading and not snapshot.available then
    launcher.setResults(query, { statusRow(noctalia.tr("launcher.loading"), snapshot.hostname, "loader") })
    return
  end

  local head, rest = query:match("^(%S+)%s*(.-)$")
  head = lower(head or "")
  rest = trim(rest or "")

  if head == "" then
    launcher.setResults(query, topCategories())
    return
  end

  if head == "peers" or head == "peer" or head == "p" then
    -- peer actions if exact match id after peers
    local peerId = rest:match("^id:(%S+)") or ""
    if peerId ~= "" then
      local peer = findPeer(peerId)
      if peer then
        launcher.setResults(query, peerActions(peer))
        return
      end
    end
    -- if rest matches a single peer name exactly, show actions
    if rest ~= "" then
      local matches = {}
      for _, p in ipairs(snapshot.peers or {}) do
        if lower(p.name) == lower(rest) or lower(p.dnsName) == lower(rest) or p.ipv4 == rest then
          table.insert(matches, p)
        end
      end
      if #matches == 1 then
        launcher.setResults(query, peerActions(matches[1]))
        return
      end
    end
    launcher.setResults(query, listPeers(rest))
    return
  end

  if head == "exit" or head == "exits" or head == "e" then
    launcher.setResults(query, listExits(rest))
    return
  end

  if head == "status" or head == "up" or head == "down" or head == "panel" or head == "refresh" or head == "admin" then
    local map = {
      status = "act:status",
      up = "act:up",
      down = "act:down",
      panel = "act:panel",
      refresh = "act:refresh",
      admin = "act:admin",
    }
    -- still show categories filtered
    local rows = {}
    for _, row in ipairs(topCategories()) do
      if row.id == map[head] or scoreText(query, row.title, row.subtitle) then
        table.insert(rows, row)
      end
    end
    launcher.setResults(query, #rows > 0 and rows or topCategories())
    return
  end

  -- free text: peers + categories
  local rows = listPeers(query)
  for _, row in ipairs(topCategories()) do
    local sc = scoreText(query, row.title, row.subtitle)
    if sc then
      row.score = sc
      table.insert(rows, row)
    end
  end
  table.sort(rows, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  while #rows > MAX_ROWS do
    table.remove(rows)
  end
  launcher.setResults(query, rows)
end

function activate(id)
  if type(id) ~= "string" or id == "" then
    return
  end

  if id == "cat:peers" then
    launcher.setQuery("peers ")
    return
  end
  if id == "cat:exit" then
    launcher.setQuery("exit ")
    return
  end
  if id == "act:status" then
    local state = snapshot.backendState or "—"
    noctalia.notify(noctalia.tr("title"), `{state} · {snapshot.onlineCount or 0}/{snapshot.peerCount or 0} online · {snapshot.ipv4 or ""}`)
    return
  end
  if id == "act:up" then
    send("up")
    return
  end
  if id == "act:down" then
    send("down")
    return
  end
  if id == "act:panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end
  if id == "act:admin" then
    send("open_admin")
    return
  end
  if id == "act:refresh" then
    send("refresh")
    return
  end
  if id == "act:clear-exit" then
    send("clear_exit_node")
    return
  end

  local peerId = id:match("^peer:(.+)$")
  if peerId then
    launcher.setQuery("peers id:" .. peerId)
    return
  end

  local exitId = id:match("^exit:(.+)$")
  if exitId then
    local e = findExit(exitId)
    if e then
      send("set_exit_node", { node = e.ip })
    end
    return
  end

  local act, ref = id:match("^peeract:([^:]+):(.+)$")
  if act and ref then
    local peer = findPeer(ref)
    if not peer then return end
    if act == "ping" then
      send("ping", { host = peer.ipv4 ~= "" and peer.ipv4 or peer.name })
    elseif act == "ssh" then
      send("ssh", { host = peer.dnsName ~= "" and peer.dnsName or peer.name })
    elseif act == "copyip" then
      send("copy", { text = peer.ipv4 })
    elseif act == "copydns" then
      send("copy", { text = peer.dnsName })
    end
  end
end
