--!nonstrict
-- Flatpak Background Apps panel - lists background Flatpak apps, each with a
-- Stop button. Stopping is done by the service; the panel only sends commands.
--
-- State (read): flatpak_bg.apps, flatpak_bg.stopping, flatpak_bg.error
-- Commands (sent): flatpak_bg.cmd = { op = "refresh" } | { op = "stop", id = "<app id>" }

-- The plugin's icon from plugin.toml; the glyph setting belongs to each bar widget
local HEADER_GLYPH = "box-multiple"

-- Rows are about 40px (28px icon, 4px padding top and bottom, 4px gap). Up to
-- this many fit under the header, and a scan error line, within
-- max_height = 360 in plugin.toml.
local MAX_ROWS_WITHOUT_SCROLL = 5

local apps = {}
local stopping = {}
local scanError = false
local closeButton = true
local isOpen = false

local function sendCommand(cmd)
  noctalia.state.set("flatpak_bg.cmd", cmd)
end

local function appRow(app)
  local busy = stopping[app.id] == true

  local leading
  if app.icon ~= "" then
    leading = ui.image({ path = app.icon, width = 28, height = 28, fit = "contain" })
  else
    leading = ui.glyph({ name = "box", size = 22, width = 28, color = "on_surface_variant" })
  end

  return ui.row({ key = app.id, gap = 12, align = "center", paddingV = 4 }, {
    leading,
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = app.name, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = app.id, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      text = busy and noctalia.tr("panel.stopping") or noctalia.tr("panel.stop"),
      variant = "destructive",
      controlSize = "sm",
      enabled = not busy,
      onClick = function() sendCommand({ op = "stop", id = app.id }) end,
    }),
  })
end

local function render()
  if not isOpen then return end

  local headerContent = {
    ui.glyph({ name = HEADER_GLYPH, size = 18, color = "primary" }),
    ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.refresh"),
      onClick = function() sendCommand({ op = "refresh" }) end,
    }),
  }
  if closeButton then
    table.insert(headerContent, ui.button({
      glyph = "close",
      variant = "ghost",
      controlSize = "sm",
      onClick = function() panel.close() end,
    }))
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, headerContent),
    ui.separator({}),
  }

  if scanError then
    table.insert(children, ui.label({ text = noctalia.tr("panel.scan_error"), color = "error" }))
  end

  if #apps == 0 then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.empty"),
      color = "on_surface_variant",
      textAlign = "center",
    }))
  else
    local rows = {}
    for _, app in ipairs(apps) do table.insert(rows, appRow(app)) end
    if #apps > MAX_ROWS_WITHOUT_SCROLL then
      -- Only a long list needs to scroll; the panel is at max_height then anyway
      table.insert(children, ui.scroll({ key = "list-scroll", gap = 4, flexGrow = 1 }, rows))
    else
      -- A flexGrow scroll fills the panel's current height, which keeps a
      -- content-sized panel from shrinking when rows go away
      table.insert(children, ui.column({ key = "list-plain", gap = 4 }, rows))
    end
  end

  panel.render(ui.column({ gap = 12 }, children))
end

local function readState()
  apps = noctalia.state.get("flatpak_bg.apps") or {}
  stopping = noctalia.state.get("flatpak_bg.stopping") or {}
  scanError = noctalia.state.get("flatpak_bg.error") == true
end

noctalia.state.watch("flatpak_bg.apps", function(value)
  apps = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("flatpak_bg.stopping", function(value)
  stopping = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("flatpak_bg.error", function(value)
  scanError = value == true
  render()
end)

function onOpen(_context)
  isOpen = true
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  readState()
  render()
  sendCommand({ op = "refresh" })
end

function onClose()
  isOpen = false
end
