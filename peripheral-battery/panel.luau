--!nonstrict
-- Panel: list wireless peripheral batteries with exact levels and status.

local KEY_SNAPSHOT = "snapshot"
local KEY_REFRESH_NONCE = "refresh"
local PLUGIN_ID = "nemanja/peripheral-battery"

local snapshot = noctalia.state.get(KEY_SNAPSHOT)
local isOpen = false
local lastRenderedSnapshot = nil

local function requestRefresh()
  local nonce = (noctalia.state.get(KEY_REFRESH_NONCE) or 0) + 1
  noctalia.state.set(KEY_REFRESH_NONCE, nonce)
  noctalia.ipc(PLUGIN_ID .. ":service", "refresh", nil)
end

local function openSettings()
  noctalia.runAsync("noctalia msg settings-open-plugin " .. PLUGIN_ID, function() end)
end

local function statusColor(d)
  if d.charging or d.full then return "primary" end
  local pct = d.percentage
  if type(pct) == "number" then
    if pct <= 15 then return "error" end
    if pct <= 30 then return "tertiary" end
  end
  local warn = d.warningLevel
  if warn == "critical" or warn == "low" then return "error" end
  return "on_surface"
end

local function statusLabel(d)
  local parts = {}
  local pct = d.percentage
  local level = d.batteryLevel
  if type(pct) == "number" then
    parts[#parts + 1] = tostring(pct) .. "%"
  elseif level ~= nil and level ~= "" then
    parts[#parts + 1] = level
  else
    parts[#parts + 1] = "unknown"
  end

  if d.charging then
    parts[#parts + 1] = "charging"
  elseif d.full then
    parts[#parts + 1] = "fully charged"
  else
    local st = d.state
    if st ~= nil and st ~= "" and st ~= "unknown" then
      parts[#parts + 1] = st
    end
  end
  return table.concat(parts, " · ")
end

local function progressValue(d)
  local pct = d.percentage
  if type(pct) == "number" then
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    return pct / 100
  end
  local lvl = (d.batteryLevel or ""):lower()
  if lvl == "full" or lvl == "high" then return 1.0 end
  if lvl == "normal" then return 0.55 end
  if lvl == "low" then return 0.25 end
  if lvl == "critical" then return 0.10 end
  if lvl == "empty" then return 0.0 end
  return 0
end

local function deviceCard(d)
  local pctText
  local pct = d.percentage
  if type(pct) == "number" then
    pctText = tostring(pct) .. "%"
  elseif d.batteryLevel ~= nil and d.batteryLevel ~= "" then
    pctText = d.batteryLevel
  else
    pctText = "?"
  end

  local meta = statusLabel(d)
  local detail = d.detail or ""
  local color = statusColor(d)

  local infoChildren = {
    ui.row({ gap = 8, align = "center", justify = "space_between" }, {
      ui.label({ text = d.name or "Peripheral", fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1, flexGrow = 1 }),
      ui.label({ text = pctText, fontSize = 14, fontWeight = "bold", color = color }),
    }),
    ui.label({ text = (d.kindLabel or "Peripheral") .. " · " .. meta, fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
    ui.progress({ progress = progressValue(d), height = 6, radius = 3, flexGrow = 1, fill = color }),
  }

  if detail ~= "" then
    infoChildren[#infoChildren + 1] = ui.label({ text = detail, fontSize = 10, color = "on_surface_variant", maxLines = 2 })
  end

  return ui.row({
    key = "dev_" .. tostring(d.key or d.name),
    gap = 10,
    align = "center",
    fill = "surface",
    border = "outline_variant",
    borderWidth = 1,
    radius = 10,
    paddingH = 12,
    paddingV = 10,
  }, {
    ui.column({ gap = 0, align = "center", justify = "center", width = 28 }, {
      ui.glyph({ name = d.glyph or "battery", size = 22, color = color }),
    }),
    ui.column({ gap = 4, flexGrow = 1 }, infoChildren),
  })
end

local function buildTree()
  local children = {}
  local s = snapshot

  local subtitle = "Wireless peripherals via UPower"
  if s ~= nil and s.error == nil then
    local n = s.total or #(s.devices or {})
    subtitle = tostring(n) .. " device(s)"
    if s.updatedAt then
      subtitle = subtitle .. " · updated " .. os.date("%H:%M:%S", s.updatedAt)
    end
  elseif s ~= nil and s.error then
    subtitle = "Error reading devices"
  else
    subtitle = "Loading…"
  end

  children[#children + 1] = ui.row({
    gap = 10, align = "center", justify = "space_between",
    fill = "surface", border = "outline_variant", borderWidth = 1, radius = 10,
    paddingH = 14, paddingV = 10,
  }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "mouse", size = 24, color = "primary" }),
      ui.column({ gap = 1 }, {
        ui.label({ text = "Peripheral Battery", fontSize = 17, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({ glyph = "settings", glyphSize = 14, variant = "ghost", controlSize = "sm", tooltip = "Settings", onClick = openSettings }),
      ui.button({ glyph = "refresh", glyphSize = 14, variant = "ghost", controlSize = "sm", tooltip = "Refresh", onClick = requestRefresh }),
      ui.button({ glyph = "x", glyphSize = 14, variant = "ghost", controlSize = "sm", tooltip = "Close", onClick = function() panel.close() end }),
    }),
  })

  if s == nil then
    children[#children + 1] = ui.column({ gap = 8, padding = 20, align = "center" }, {
      ui.glyph({ name = "battery", size = 28, color = "on_surface_variant" }),
      ui.label({ text = "Loading peripheral batteries…", fontSize = 13, color = "on_surface_variant" }),
    })
  elseif s.error then
    children[#children + 1] = ui.column({ gap = 8, padding = 16, align = "center", fill = "surface", border = "outline_variant", borderWidth = 1, radius = 10 }, {
      ui.glyph({ name = "alert-triangle", size = 28, color = "error" }),
      ui.label({ text = "Could not read peripheral batteries", fontSize = 13, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tostring(s.error), fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
      ui.label({ text = "Make sure UPower is installed and running (upower -d).", fontSize = 10, color = "on_surface_variant", textAlign = "center" }),
    })
  else
    local devices = s.devices or {}
    if #devices == 0 then
      children[#children + 1] = ui.column({ gap = 8, padding = 20, align = "center", fill = "surface", border = "outline_variant", borderWidth = 1, radius = 10 }, {
        ui.glyph({ name = "plug-connected-x", size = 28, color = "on_surface_variant" }),
        ui.label({ text = "No peripheral batteries detected", fontSize = 13, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = "Connect a wireless mouse, keyboard, headset, or controller that reports battery status via UPower.", fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
      })
    else
      local cards = {}
      for i = 1, #devices do
        cards[#cards + 1] = deviceCard(devices[i])
      end
      children[#children + 1] = ui.column({ gap = 8 }, cards)
    end
  end

  return ui.column({ gap = 10, padding = 10 }, children)
end

local function render()
  if not isOpen then return end
  if snapshot == lastRenderedSnapshot then return end
  lastRenderedSnapshot = snapshot
  panel.render(buildTree())
end

function onOpen(_context)
  isOpen = true
  lastRenderedSnapshot = nil
  render()
end

function onClose()
  isOpen = false
  lastRenderedSnapshot = nil
end

noctalia.state.watch(KEY_SNAPSHOT, function(v)
  snapshot = v
  render()
end)

if snapshot ~= nil then
  -- keep initial snapshot; render on open
end
