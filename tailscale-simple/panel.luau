--!nonstrict
-- Everyday controls first; network preferences stay in their own view.
local snapshot = noctalia.state.get("ts_snapshot") or {}
local view = "devices"
local query = ""
local expanded = ""
local serial = 0
local pending = false
local dirty = true
local render
local function tr(key) return noctalia.tr("simple." .. key) end

-- Draw with semantic colors so palette changes also update an open panel.
local function brandIcon()
  local rows = {}
  for row = 1, 3 do
    local dots = {}
    for col = 1, 3 do
      local solid = row == 2 or (row == 3 and col == 2)
      table.insert(dots, ui.box({ width = 6, height = 6, radius = 3,
        fill = solid and "on_surface" or "on_surface/0.3" }))
    end
    table.insert(rows, ui.row({ gap = 3 }, dots))
  end
  return ui.column({ width = 24, height = 24, gap = 3 }, rows)
end

local function send(action, fields)
  serial += 1
  local command = fields or {}
  command.action = action
  command.requestId = `simple-panel-{serial}`
  -- Refresh publishes snapshots, not an action result.
  pending = action ~= "refresh"
  noctalia.state.set("ts_command", command)
  dirty = true
end

local function text(value, size, muted)
  return ui.label({ text = tostring(value or ""), fontSize = size or 13,
    color = muted and "on_surface_variant" or "on_surface", maxLines = 2 })
end

local function button(label, callback, enabled, variant, glyph, tooltip)
  return ui.button({ text = label, onClick = callback, enabled = enabled ~= false,
    variant = variant or "ghost", glyph = glyph, controlSize = "sm", tooltip = tooltip })
end

local function card(children)
  return ui.column({ padding = 12, gap = 8, radius = 12,
    fill = "surface_variant/0.35", align = "stretch" }, children)
end

local function ready()
  return not pending and not snapshot.busy and not snapshot.loading
    and snapshot.installed == true and snapshot.available == true
end

local function copy(value)
  if value and value ~= "" then send("copy", { text = value }) end
end

local function switch(nextView)
  view = nextView
  expanded = ""
  query = ""
  render()
end

local function matches(...)
  local needle = string.lower(query)
  for i = 1, select("#", ...) do
    if string.find(string.lower(tostring(select(i, ...) or "")), needle, 1, true) then return true end
  end
  return false
end

local function devices()
  local peers = {}
  for _, peer in ipairs(snapshot.peers or {}) do
    if matches(peer.name, peer.ipv4, peer.dnsName) then table.insert(peers, peer) end
  end
  table.sort(peers, function(a, b)
    if (a.online == true) ~= (b.online == true) then return a.online == true end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  local rows = {}
  for _, peer in ipairs(peers) do
    local p = peer
    local children = {
      ui.row({ gap = 8, align = "center" }, {
        ui.box({ width = 8, height = 8, radius = 4,
          fill = p.online and "#73c936" or "#8a8a8a" }),
        ui.column({ flexGrow = 1, gap = 2 }, {
          text(p.name, 14),
        }),
        button(tr("copy_ip"), function() copy(p.ipv4) end, (p.ipv4 or "") ~= "" and ready(), "ghost", "copy"),
        button(nil, function()
          expanded = expanded == p.id and "" or p.id
          render()
        end, true, "ghost", "dots-vertical", tr(expanded == p.id and "less" or "more")),
      }),
    }
    if expanded == p.id then
      table.insert(children, text(p.ipv4, 12, true))
      table.insert(children, ui.row({ gap = 6 }, {
        button(tr("ping"), function() onDeviceMenu("ping", p.id) end, ready()),
        button(tr("ssh"), function() onDeviceMenu("ssh", p.id) end, ready() and p.online),
        button(tr("copy_dns"), function() onDeviceMenu("copy_dns", p.id) end,
          ready() and (p.dnsName or "") ~= ""),
      }))
    end
    table.insert(rows, card(children))
  end
  if #rows == 0 then table.insert(rows, text(tr(query ~= "" and "no_matches" or "no_devices"), 13, true)) end
  return rows
end

local function exits()
  local rows = { text(tr("exit_help"), 12, true) }
  local current = snapshot.exitNode or ""
  table.insert(rows, button((current == "" and "✓  " or "") .. tr("direct"),
    function() send("clear_exit_node") end, ready() and current ~= "", current == "" and "outline" or "ghost"))
  for _, node in ipairs(snapshot.exitNodes or {}) do
    local e = node
    if matches(e.name, e.ip) then
      table.insert(rows, card({
        ui.row({ gap = 8, align = "center" }, {
          ui.column({ flexGrow = 1, gap = 2 }, {
            text(e.name, 14), text(tr(e.selected and "in_use" or (e.online and "available" or "offline")), 11, true),
          }),
          button(tr(e.selected and "in_use" or "use"), function() send("set_exit_node", { node = e.ip }) end,
            ready() and snapshot.running and e.online and not e.selected, "outline"),
        }),
      }))
    end
  end
  if #(snapshot.exitNodes or {}) == 0 then table.insert(rows, text(tr("no_exits"), 13, true)) end
  return rows
end

local function preferences()
  local rows = { text(tr("advanced"), 14) }
  local settings = {
    { "shields", "shields_help", "shieldsUp", "set_shields" },
    { "tailscale_ssh", "ssh_help", "runSSH", "set_ssh" },
    { "routes", "routes_help", "acceptRoutes", "set_accept_routes" },
    { "advertise", "advertise_help", "advertiseExitNode", "set_advertise_exit" },
    { "lan", "lan_help", "exitNodeAllowLAN", "set_allow_lan" },
  }
  for _, setting in ipairs(settings) do
    local s = setting
    local on = snapshot[s[3]] == true
    table.insert(rows, card({ ui.row({ gap = 10, align = "center" }, {
      ui.column({ flexGrow = 1, gap = 3 }, { text(tr(s[1]), 13), text(tr(s[2]), 11, true) }),
      ui.toggle({ key = "setting-" .. s[3], checked = on, enabled = ready(),
        onChange = function(value)
          local enabled = value == true or value == "true"
          if ready() and enabled ~= (snapshot[s[3]] == true) then
            send(s[4], { enabled = enabled })
            render()
          end
        end }),
    }) }))
  end
  return rows
end

render = function()
  dirty = false
  local running = snapshot.running == true
  local busy = pending or snapshot.busy or snapshot.loading
  local state = tr(busy and "updating" or (running and "connected" or "disconnected"))
  if snapshot.installed == false then state = tr("not_installed")
  elseif snapshot.available == false and not busy then state = tr("unavailable") end
  local content = {
    ui.row({ gap = 10, align = "center" }, {
      brandIcon(),
      ui.column({ flexGrow = 1, gap = 2 }, { text(noctalia.tr("title"), 18), text(state, 12, true) }),
      button(nil, function() send("open_admin") end, ready(), "ghost", "external-link", tr("admin")),
      button(nil, function() send("refresh") end, not busy, "ghost", "refresh", tr("refresh")),
      button(nil, function() panel.close() end, true, "ghost", "x", tr("close")),
    }),
    card({
      ui.row({ gap = 8, align = "center" }, {
        ui.column({ flexGrow = 1, gap = 3 }, {
          text((snapshot.hostname or "") ~= "" and snapshot.hostname or tr("this_device"), 14),
          text((snapshot.ipv4 or "") ~= "" and snapshot.ipv4 or tr("no_ip"), 12, true),
        }),
        button(tr("ip"), function() copy(snapshot.ipv4) end, ready() and (snapshot.ipv4 or "") ~= "", "ghost", "copy", tr("copy_ip")),
        button(tr("dns"), function() copy(snapshot.dnsName) end, ready() and (snapshot.dnsName or "") ~= "", "ghost", "copy", tr("copy_dns")),
        ui.toggle({ key = "connection", checked = running, enabled = ready(),
          onChange = function(value)
            local connect = value == true or value == "true"
            if ready() and connect ~= (snapshot.running == true) then
              send(connect and "up" or "down")
              render()
            end
          end }),
      }),
    }),
    ui.row({ gap = 4 }, {
      button(tr("devices"), function() switch("devices") end, true, view == "devices" and "primary" or "ghost"),
      button(tr("exit_node"), function() switch("exit") end, true, view == "exit" and "primary" or "ghost"),
      button(tr("settings"), function() switch("settings") end, true, view == "settings" and "primary" or "ghost"),
    }),
  }
  local body = {}
  if view ~= "settings" then
    table.insert(body, ui.input({ key = "search-" .. view, value = query,
      placeholder = tr(view == "devices" and "search_devices" or "search_exits"),
      onChange = function(value) query = type(value) == "string" and value or ""; render() end }))
  end
  if (snapshot.error or "") ~= "" then table.insert(body, text(snapshot.error, 12, true)) end
  for _, warning in ipairs(snapshot.health or {}) do table.insert(body, text(warning, 12, true)) end
  local rows = view == "devices" and devices() or (view == "exit" and exits() or preferences())
  table.insert(body, ui.scroll({ key = "list-" .. view, flexGrow = 1, align = "stretch", padding = 0, paddingV = 0 }, {
    ui.column({ gap = 8, align = "stretch", padding = 0 }, rows),
  }))
  -- The scroll viewport adds 8px of top inset; 4px here matches the 12px outer gap.
  table.insert(content, ui.column({ flexGrow = 1, gap = 4, align = "stretch" }, body))
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, content))
end

noctalia.state.watch("ts_snapshot", function(value)
  if type(value) == "table" then snapshot = value; dirty = true end
end)
noctalia.state.watch("ts_action_result", function(result)
  if type(result) ~= "table" or not tostring(result.requestId):match("^simple%-panel%-%d+$") then return end
  pending = false
  dirty = true
end)
panel.setWantsSecondTicks(true)
function onOpen(context)
  pending = false
  if context == "devices" or context == "exit" or context == "settings" then
    view = context
    query = ""
  end
  -- Service refresh is read-only; no connection or preference changes on open.
  noctalia.state.set("ts_command", { action = "refresh" })
  render()
end
function update() if dirty then render() end end
function onClose() panel.close() end

function onDeviceMenu(action, context)
  if not ready() then return end
  -- Resolve against the latest snapshot: devices can change while the menu is open.
  for _, p in ipairs(snapshot.peers or {}) do
    if p.id == context then
      if action == "ping" then
        send("ping", { host = (p.ipv4 or "") ~= "" and p.ipv4 or p.name })
      elseif action == "ssh" and p.online then
        send("ssh", { host = (p.dnsName or "") ~= "" and p.dnsName or p.name })
      elseif action == "copy_dns" then
        copy(p.dnsName)
      end
      render()
      return
    end
  end
end
