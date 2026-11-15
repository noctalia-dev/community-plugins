-- view_panel.luau: snapshot in, ui tree out.
local view_panel = loadModule("view_panel.luau")
local parse = loadModule("parse.luau")
local ui = stubs.ui

local function tr(key, subst)
  local parts = {}
  for k, v in pairs(subst or {}) do
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  table.sort(parts)
  if #parts == 0 then
    return key
  end
  return key .. "|" .. table.concat(parts, ",")
end

local calls = {}
local h = {
  connect = function(id) calls[#calls + 1] = "connect:" .. tostring(id) end,
  disconnect = function(id) calls[#calls + 1] = "disconnect:" .. tostring(id) end,
  openGui = function() calls[#calls + 1] = "open_gui" end,
  openDownload = function() calls[#calls + 1] = "open_download" end,
  dismiss = function(key) calls[#calls + 1] = "dismiss:" .. tostring(key) end,
  copy = function(text) calls[#calls + 1] = "copy:" .. text end,
}

local function walk(node, fn)
  if type(node) ~= "table" then
    return
  end
  if node.type then
    fn(node)
  end
  for _, child in ipairs(node.children or {}) do
    walk(child, fn)
  end
end

local function texts(tree)
  local out = {}
  walk(tree, function(n)
    if n.props.text then
      out[#out + 1] = n.props.text
    end
  end)
  return out
end

local function hasText(tree, needle)
  for _, t in ipairs(texts(tree)) do
    if t == needle then
      return true
    end
  end
  return false
end

local function hasPrefix(tree, prefix)
  for _, t in ipairs(texts(tree)) do
    if t:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function buttons(tree, text)
  local out = {}
  walk(tree, function(n)
    if n.type == "button" and (text == nil or n.props.text == text) then
      out[#out + 1] = n
    end
  end)
  return out
end

local function conn(id, status, extra)
  local c = {
    id = id, name = "Work", host = "vpn.example.com", account = "user@example.com",
    status = status, authorized = true, dns = {},
  }
  for k, v in pairs(extra or {}) do
    c[k] = v
  end
  return c
end

local function snap(connections, extra)
  local s = {
    installed = true, service = "running", connections = connections,
    inFlight = {}, rowErrors = {}, rebootNeeded = false, busy = false,
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function build(s)
  return view_panel.build(s, ui, tr, h)
end

-- each panel state renders its message
local loading = build(nil)
check("views: loading renders", hasText(loading, "panel.loading"))
check("views: header title", hasText(loading, "panel.title"))
local notInstalled = build(snap({}, { installed = false }))
check("views: not_installed message", hasText(notInstalled, "panel.not_installed"))
check("views: not_installed how-to button", #buttons(notInstalled, "button.how_to_get") == 1)
eq("views: not_installed has no footer button", #buttons(notInstalled), 1)
buttons(notInstalled)[1].props.onClick()
eq("views: how-to calls openDownload", calls[#calls], "open_download")
local down = build(snap({}, { service = "down" }))
check("views: service_down message", hasText(down, "panel.service_down"))
check("views: service_down hint", hasText(down, "panel.service_hint"))
check("views: service_down copy button", #buttons(down, "button.copy") == 1)
buttons(down, "button.copy")[1].props.onClick()
check("views: copy sends the command", calls[#calls]:sub(1, 5) == "copy:" and calls[#calls]:find("systemctl", 1, true) ~= nil)
local none = build(snap({}))
check("views: no_connections message", hasText(none, "panel.no_connections"))
local noneOpen = buttons(none, "button.open_gui")
eq("views: no_connections one Open LogonBox", #noneOpen, 1)
eq("views: no_connections Open is primary", noneOpen[1].props.variant, "primary")

-- the problem message appears once: the header carries no subtitle repeating it
local function countText(tree, needle)
  local n = 0
  for _, t in ipairs(texts(tree)) do
    if t == needle then
      n = n + 1
    end
  end
  return n
end
eq("views: not_installed message appears once", countText(notInstalled, "panel.not_installed"), 1)
eq("views: service_down message appears once", countText(down, "panel.service_down"), 1)
eq("views: no_connections message appears once", countText(none, "panel.no_connections"), 1)

local reboot = build(snap({ conn(0, "disconnected") }, {
  rebootNeeded = true, rowErrors = { ["0"] = { key = "error.reboot_needed" } },
}))
eq("views: reboot message appears once", countText(reboot, "error.reboot_needed"), 1)

-- list rows
local connected = build(snap({ conn(1, "CONNECTED", { dns = { "198.51.100.2", "198.51.100.3" } }) }))
check("views: connected row shows DNS", hasText(connected, "panel.dns|servers=198.51.100.2, 198.51.100.3"))
local disc = buttons(connected, "button.disconnect")
eq("views: connected row has Disconnect", #disc, 1)
eq("views: Disconnect is outline", disc[1].props.variant, "outline")
disc[1].props.onClick()
eq("views: Disconnect click", calls[#calls], "disconnect:1")
check("views: row title", hasText(connected, "Work"))
check("views: row subtitle has account and status", hasText(connected, "status.connected · vpn.example.com"))

local off = build(snap({ conn(1, "DISCONNECTED") }))
check("views: disconnected row hides DNS", not hasPrefix(off, "panel.dns"))
local con = buttons(off, "button.connect")
eq("views: disconnected row has Connect", #con, 1)
eq("views: Connect is primary", con[1].props.variant, "primary")
con[1].props.onClick()
eq("views: Connect click", calls[#calls], "connect:1")

local unauth = build(snap({ conn(1, "DISCONNECTED", { authorized = false }) }))
local gui = buttons(unauth, "button.open_gui")
check("views: unauthorized row shows Open LogonBox", #gui >= 1)
eq("views: unauthorized has no Connect", #buttons(unauth, "button.connect"), 0)
eq("views: row Open LogonBox is secondary", gui[1].props.variant, "secondary")

local flight = build(snap({ conn(1, "DISCONNECTED") }, { inFlight = { ["1"] = "connecting" } }))
eq("views: inFlight row button disabled", buttons(flight, "button.connect")[1].props.enabled, false)
check("views: inFlight row says connecting", hasText(flight, "status.connecting · vpn.example.com"))

local errRow = build(snap({ conn(1, "DISCONNECTED") }, { rowErrors = { ["1"] = { key = "error.connect_failed_detail", detail = "no route" } } }))
local errColor
walk(errRow, function(n)
  if n.props.text == "error.connect_failed_detail|detail=no route" then
    errColor = n.props.color
  end
end)
eq("views: row error line in error colour", errColor, "error")

local busy = build(snap({ conn(1, "DISCONNECTED"), conn(2, "CONNECTED") }, { busy = true }))
local allDisabled = true
for _, b in ipairs(buttons(busy)) do
  if b.props.enabled ~= false and b.props.glyph == nil and b.props.text ~= "button.open_gui" then
    allDisabled = false
  end
end
check("views: busy disables every action button", allDisabled)

local multi = parse.show(fixture("show-multi.txt"))
local multiSnap = snap(multi, { rowErrors = {} })
for _, c in ipairs(multiSnap.connections) do
  c.status = "DISCONNECTED"
end
local primaries = 0
for _, b in ipairs(buttons(build(multiSnap))) do
  if b.props.variant == "primary" then
    primaries = primaries + 1
  end
end
check("views: multi has several rows", #multiSnap.connections >= 2)
eq("views: at most one primary button", primaries, 1)

-- footer + lastError + test mode
local footer = build(snap({ conn(1, "DISCONNECTED") }))
local footGui = buttons(footer, "button.open_gui")
eq("views: footer Open LogonBox", #footGui, 1)
eq("views: footer Open LogonBox is ghost", footGui[1].props.variant, "ghost")
local withErr = build(snap({ conn(1, "DISCONNECTED") }, { lastError = { key = "error.read" } }))
check("views: lastError line", hasText(withErr, "error.read"))
local dismissBtn
walk(withErr, function(n)
  if n.type == "button" and n.props.key == "btn.dismiss_error" then
    dismissBtn = n
  end
end)
check("views: lastError dismiss button", dismissBtn ~= nil)
dismissBtn.props.onClick()
eq("views: dismiss click carries the error key", calls[#calls], "dismiss:error.read")
check("views: no test line by default", not hasText(footer, "panel.test_mode"))
check("views: test mode line", hasText(build(snap({ conn(1, "DISCONNECTED") }, { simulate = "multi" })), "panel.test_mode"))

-- Open LogonBox stays enabled while busy (footer and sign-in row)
local busyGui = build(snap({ conn(1, "DISCONNECTED"), conn(2, "DISCONNECTED", { authorized = false }) }, { busy = true }))
local guiBtns = buttons(busyGui, "button.open_gui")
eq("views: busy keeps two Open LogonBox buttons", #guiBtns, 2)
for _, b in ipairs(guiBtns) do
  check("views: busy Open LogonBox enabled", b.props.enabled ~= false)
end
eq("views: busy still disables Connect", buttons(busyGui, "button.connect")[1].props.enabled, false)
local busyEmpty = build(snap({}, { busy = true }))
check("views: busy empty-state Open LogonBox enabled", buttons(busyEmpty, "button.open_gui")[1].props.enabled ~= false)

-- empty subtitle: no dangling separator
local bare = conn(3, "CONNECTED", { name = "" })
bare.account = nil
local bareTree = build(snap({ bare }))
check("views: empty subtitle renders status only", hasText(bareTree, "status.connected"))
check("views: no dangling separator", not hasPrefix(bareTree, " · ") and not hasText(bareTree, "status.connected · "))

-- failed first read: error shown with a way forward, not "Loading..."
local readErr = build(snap({}, { service = "unknown", lastError = { key = "error.read" } }))
check("views: failed first read shows the error", hasText(readErr, "error.read"))
check("views: failed first read is not loading", not hasText(readErr, "panel.loading"))
eq("views: failed first read has Open LogonBox", #buttons(readErr, "button.open_gui"), 1)
check("views: failed first read has dismiss", (function()
  local found = false
  walk(readErr, function(n) if n.props.key == "btn.dismiss_error" then found = true end end)
  return found
end)())

-- offline header
local offTree = build(snap({ conn(0, "TEMPORARILY_OFFLINE") }))
check("views: offline header says offline", hasText(offTree, "status.offline"))
