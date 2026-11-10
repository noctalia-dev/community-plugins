--!nonstrict
-- Drop-down panel: lists background Flatpak apps, each with a Stop button.
-- Stopping is done by the service; this panel only sends requests.

local apps = noctalia.state.get("bg_apps") or {}
local stopping = noctalia.state.get("bg_stopping") or {}
local scanError = noctalia.state.get("bg_error") == true
local isOpen = false

-- Rows of about 40px (28px icon, 4px padding top and bottom, 4px gap) that
-- fit under the header within max_height = 480; more than this scrolls
local MAX_ROWS_WITHOUT_SCROLL = 8

local function requestRefresh()
  noctalia.state.set("refresh", (tonumber(noctalia.state.get("refresh")) or 0) + 1)
end

local function requestStop(id)
  local requests = noctalia.state.get("stop_requests")
  if type(requests) ~= "table" then requests = {} end
  local last = requests[#requests]
  local seq = (type(last) == "table" and tonumber(last.seq) or 0) + 1
  local kept = {}
  -- Keep a short tail so a request sent right before this one is not lost
  for i = math.max(1, #requests - 9), #requests do table.insert(kept, requests[i]) end
  table.insert(kept, { id = id, seq = seq })
  noctalia.state.set("stop_requests", kept)
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
      onClick = function() requestStop(app.id) end,
    }),
  })
end

local function render()
  if not isOpen then return end

  local header = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = noctalia.getConfig("glyph"), size = 18, color = "primary" }),
    ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.refresh"),
      onClick = requestRefresh,
    }),
  })

  local children = { header, ui.separator({}) }

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

noctalia.state.watch("bg_apps", function(value)
  apps = value or {}
  render()
end)

noctalia.state.watch("bg_stopping", function(value)
  stopping = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("bg_error", function(value)
  scanError = value == true
  render()
end)

function onConfigChanged()
  render()
end

function onOpen()
  isOpen = true
  apps = noctalia.state.get("bg_apps") or {}
  stopping = noctalia.state.get("bg_stopping") or {}
  scanError = noctalia.state.get("bg_error") == true
  render()
  requestRefresh()
end

function onClose()
  isOpen = false
end
