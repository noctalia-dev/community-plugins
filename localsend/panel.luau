--!nonstrict
-- Panel: nearby devices (click to pick files and send) and the transfer list.

-- The daemon writes a private token (mode 0600) next to its certificate; every control request must carry it.
local cachedToken = nil
local function headers()
  if cachedToken == nil then
    local path = noctalia.pluginDataDir() .. "/control.token"
    cachedToken = noctalia.fileExists(path) and noctalia.readFile(path) or nil
  end
  return { "X-LocalSend-Token: " .. (cachedToken or ""), "Content-Type: application/json" }
end
local function forgetToken() cachedToken = nil end
local open = false

local function ctl(path) return "http://127.0.0.1:" .. noctalia.getConfig("control_port") .. path end

local function post(path, body)
  noctalia.http({
    url = ctl(path), method = "POST", headers = headers(),
    body = noctalia.json.encode(body or {}),
  }, function() end)
end

local function sendTo(peer)
  noctalia.runAsync({ "zenity", "--file-selection", "--multiple", "--separator=\n",
    "--title=" .. noctalia.tr("panel.send_tooltip", { name = peer.alias }) }, function(res)
    if res.exitCode ~= 0 then return end
    local paths = {}
    for line in string.gmatch(res.stdout, "[^\n]+") do table.insert(paths, line) end
    if #paths > 0 then post("/send", { fingerprint = peer.fingerprint, paths = paths }) end
  end)
end

local function sendFolderTo(peer)
  noctalia.runAsync({ "zenity", "--file-selection", "--directory",
    "--title=" .. noctalia.tr("panel.send_folder", { name = peer.alias }) }, function(res)
    local dir = noctalia.string.trim(res.stdout)
    if res.exitCode == 0 and dir ~= "" then
      post("/send", { fingerprint = peer.fingerprint, paths = { dir } })
    end
  end)
end

local function sendClipboardTo(peer)
  local text = noctalia.clipboardText()
  if text == nil or text == "" then
    noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.clipboard_empty"))
    return
  end
  post("/send", { fingerprint = peer.fingerprint, text = text })
end

local function deviceGlyph(t)
  if t == "mobile" then return "device-mobile" end
  if t == "web" then return "world" end
  if t == "server" or t == "headless" then return "server" end
  return "device-desktop"
end

local function deviceRow(peer)
  return ui.row({ align = "center", gap = 2 }, {
    ui.button({
      glyph = deviceGlyph(peer.deviceType),
      text = peer.alias .. "  ·  " .. peer.ip,
      variant = "ghost",
      contentAlign = "start",
      flexGrow = 1,
      tooltip = noctalia.tr("panel.send_tooltip", { name = peer.alias }),
      onClick = function() sendTo(peer) end,
    }),
    ui.button({ glyph = "folder", variant = "ghost",
      tooltip = noctalia.tr("panel.send_folder", { name = peer.alias }),
      onClick = function() sendFolderTo(peer) end }),
    ui.button({ glyph = "clipboard", variant = "ghost",
      tooltip = noctalia.tr("panel.send_clipboard", { name = peer.alias }),
      onClick = function() sendClipboardTo(peer) end }),
  })
end

local function statusText(s)
  return noctalia.tr("panel.status." .. s.status, { name = s.peer })
end

local function sessionRow(s)
  local title = (s.direction == "in" and "panel.from" or "panel.to")
  local names = {}
  for _, f in ipairs(s.files) do table.insert(names, f.name) end
  local summary = s.text ~= nil and s.text or table.concat(names, ", ")

  local rows = {
    ui.label({ text = noctalia.tr(title, { name = s.peer }), fontWeight = "bold" }),
    ui.label({ text = summary, maxLines = 2, maxWidth = 330, color = "on_surface_variant", fontSize = 12 }),
  }

  local active = s.status == "sending" or s.status == "receiving"
  if active then
    table.insert(rows, ui.progress({ progress = s.total > 0 and s.done / s.total or 0, height = 6, width = 330 }))
  end

  local status = statusText(s)
  if s.error ~= nil then status = status .. " (" .. s.error .. ")" end
  table.insert(rows, ui.label({ text = status, fontSize = 12, color = "on_surface_variant" }))

  local buttons = {}
  if s.direction == "in" and s.status == "pending" then
    table.insert(buttons, ui.button({ text = noctalia.tr("panel.accept"), variant = "primary",
      onClick = function() post("/accept", { session = s.id }) end }))
    table.insert(buttons, ui.button({ text = noctalia.tr("panel.reject"), variant = "outline",
      onClick = function() post("/reject", { session = s.id }) end }))
  elseif active or s.status == "waiting" then
    table.insert(buttons, ui.button({ text = noctalia.tr("panel.cancel"), variant = "outline",
      onClick = function() post("/cancel", { session = s.id }) end }))
  end
  if s.text ~= nil and s.direction == "in" and s.status == "done" then
    table.insert(buttons, ui.button({ glyph = "copy", text = noctalia.tr("panel.copy"), variant = "outline",
      onClick = function() noctalia.copyToClipboard(s.text, "text/plain") end }))
  end
  if #buttons > 0 then table.insert(rows, ui.row({ gap = 8 }, buttons)) end

  return ui.column({ gap = 4, padding = 10, radius = 10, fill = "surface_container" }, rows)
end

local function render()
  if not open then return end
  local ls = noctalia.state.get("ls") or { up = false }

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "send", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.rescan"),
        onClick = function() post("/rescan") end }),
      ui.button({ glyph = "x", variant = "ghost", onClick = function() panel.close() end }),
    }),
  }

  if not ls.up then
    table.insert(children, ui.label({ text = noctalia.tr("panel.daemon_down"), color = "error" }))
  else
    table.insert(children, ui.label({ text = noctalia.tr("panel.nearby"), fontWeight = "bold" }))
    if #ls.peers == 0 then
      table.insert(children, ui.label({ text = noctalia.tr("panel.no_devices"),
        color = "on_surface_variant", maxWidth = 340 }))
    else
      for _, p in ipairs(ls.peers) do table.insert(children, deviceRow(p)) end
    end

    table.insert(children, ui.separator({ spacing = 4 }))
    table.insert(children, ui.label({ text = noctalia.tr("panel.transfers"), fontWeight = "bold" }))
    if #ls.sessions == 0 then
      table.insert(children, ui.label({ text = noctalia.tr("panel.no_transfers"),
        color = "on_surface_variant" }))
    else
      for _, s in ipairs(ls.sessions) do table.insert(children, sessionRow(s)) end
    end
  end

  if ls.up then
    table.insert(children, ui.label({ text = noctalia.tr("panel.saving_to", { dir = ls.self.saveDir }),
      fontSize = 11, color = "on_surface_variant", maxWidth = 340 }))
  end
  panel.render(ui.scroll({ gap = 10, padding = 16, height = 520 }, children))
end

function onOpen(context)
  open = true
  noctalia.state.set("panel_open", true)
  render()
end

function onClose()
  open = false
  noctalia.state.set("panel_open", false)
end

noctalia.state.watch("ls", function() render() end)
