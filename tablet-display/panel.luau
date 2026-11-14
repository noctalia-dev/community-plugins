--!nonstrict
-- Tablet Display panel.

local common = require("./lib/common.luau")
local tr = common.tr

local snapshot = common.snapshot()
local isOpen = false

local SCALES = { "auto", "1", "1.25", "1.5", "1.75", "2", "2.25", "2.5", "3" }
local POSITIONS = {
  { id = "left", glyph = "arrow-bar-left" },
  { id = "above", glyph = "arrow-bar-up" },
  { id = "below", glyph = "arrow-bar-down" },
  { id = "right", glyph = "arrow-bar-right" },
}

local function card(children)
  return ui.column({ gap = 8, padding = 12, fill = "surface_container/0.45", radius = 10, align = "stretch" }, children)
end

local function heading(text)
  return ui.label({ text = text, fontWeight = "bold", color = "on_surface" })
end

local function muted(text)
  return ui.label({ text = text, color = "on_surface_variant", maxLines = 6 })
end

local function message(text, color, glyph)
  return ui.row({ gap = 8, align = "start" }, {
    ui.glyph({ name = glyph, size = 16, color = color }),
    ui.label({ text = text, color = color, maxLines = 8, flexGrow = 1 }),
  })
end

local function busy()
  return (snapshot.pending or "") ~= "" or (snapshot.busy or "") ~= ""
end

local function modeButtons()
  local mode = snapshot.mode or "off"
  local enabled = not busy() and snapshot.installed ~= false
  local helperMissing = snapshot.helper and snapshot.helper.needed and not snapshot.helper.installed
  local function btn(id, glyph, blocked)
    return ui.button({
      text = tr("panel.mode." .. id),
      glyph = glyph,
      variant = mode == id and "primary" or "outline",
      selected = mode == id,
      enabled = enabled and not blocked,
      flexGrow = 1,
      onClick = function()
        if id ~= mode then common.send(id) end
      end,
    })
  end
  return ui.row({ gap = 6 }, {
    btn("off", "power", false),
    btn("extend", "device-tablet", helperMissing),
    btn("mirror", "copy", false),
  })
end

local function placementCard()
  local pos = snapshot.position or "right"
  local row = {}
  for _, p in ipairs(POSITIONS) do
    table.insert(row, ui.button({
      key = "pos-" .. p.id,
      glyph = p.glyph,
      tooltip = tr("panel.position." .. p.id),
      variant = pos == p.id and "primary" or "ghost",
      selected = pos == p.id,
      enabled = not busy(),
      flexGrow = 1,
      onClick = function()
        if p.id ~= pos then common.send("set", { key = "position", value = p.id }) end
      end,
    }))
  end

  local current = snapshot.scaleSetting or "auto"
  local labels, selected = {}, 0
  for i, s in ipairs(SCALES) do
    if s == "auto" then
      table.insert(labels, tr("panel.scale_auto", { scale = snapshot.scale or "?" }))
    else
      table.insert(labels, s .. "×")
    end
    if s == current then selected = i - 1 end
  end

  return card({
    heading(tr("panel.placement")),
    ui.row({ gap = 4 }, row),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("panel.scale"), color = "on_surface_variant", flexGrow = 1 }),
      ui.select({
        options = labels,
        selectedIndex = selected,
        enabled = not busy(),
        width = 160,
        controlSize = "sm",
        onChange = function(index)
          local s = SCALES[(tonumber(index) or 0) + 1]
          if s and s ~= current then common.send("set", { key = "scale", value = s }) end
        end,
      }),
    }),
  })
end

local function moonlightCard()
  local addrs = snapshot.addresses or {}
  local where = snapshot.host or tr("panel.this_computer")
  if #addrs > 0 then
    where = `{where} ({table.concat(addrs, ", ")})`
  end
  local children = {
    heading(tr("panel.moonlight")),
    muted(tr("panel.moonlight_help", { host = where })),
  }
  -- USB tethering: the tablet reaches Sunshine over the cable at this address.
  local usb = snapshot.usb or {}
  if #usb > 0 then
    local ips = {}
    for _, link in ipairs(usb) do
      table.insert(ips, tostring(link.ip))
    end
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "usb", size = 16, color = "primary" }),
      ui.label({ text = tr("panel.usb_address", { ip = table.concat(ips, ", ") }), color = "primary", flexGrow = 1, maxLines = 3 }),
    }))
    if snapshot.firewall then
      table.insert(children, muted(tr("panel.usb_firewall")))
    end
  end
  local client = common.clientLine(snapshot)
  if client ~= "" then
    table.insert(children, ui.label({ text = client, color = snapshot.client and "primary" or "on_surface_variant" }))
  end
  table.insert(children, ui.row({ gap = 6 }, {
    ui.button({ text = tr("panel.pair"), glyph = "key", variant = "outline", flexGrow = 1,
      tooltip = tr("panel.pair_tooltip"), onClick = function() common.send("pair") end }),
    ui.button({ text = tr("panel.sunshine"), glyph = "settings", variant = "outline", flexGrow = 1,
      tooltip = tr("panel.sunshine_tooltip"), onClick = function() common.send("admin") end }),
  }))
  return card(children)
end

local function setupMessages(children)
  if snapshot.available == false then
    table.insert(children, message(tr("panel.script_failed", { error = tostring((snapshot.errors or {})[1] or "?") }),
      "error", "alert-triangle"))
    return
  end
  if snapshot.installed == false then
    table.insert(children, card({ message(tr("panel.sunshine_missing"), "error", "alert-triangle") }))
  end
  local h = snapshot.helper
  if type(h) == "table" and h.needed and (not h.installed or not h.current) then
    local text = h.installed and tr("panel.helper_outdated")
      or tr("panel.helper_needed", { compositor = snapshot.compositor or "?" })
    table.insert(children, card({
      message(text, "tertiary", "tool"),
      ui.button({ text = h.installed and tr("panel.helper_update") or tr("panel.helper_install"), glyph = "download",
        variant = "primary", onClick = function() common.send("install-helper") end }),
    }))
  end
end

-- Hints, notices and errors come from the control script in English.
local function notices(children)
  local any = false
  if (snapshot.hint or "") ~= "" then
    table.insert(children, message(snapshot.hint, "tertiary", "info-circle"))
  end
  if (snapshot.notice or "") ~= "" then
    any = true
    table.insert(children, message(snapshot.notice, "on_surface", "info-circle"))
  end
  for _, err in ipairs(snapshot.errors or {}) do
    any = true
    table.insert(children, message(tostring(err), "error", "alert-triangle"))
  end
  if any and snapshot.available ~= false then
    table.insert(children, ui.button({ text = tr("panel.dismiss"), variant = "ghost", controlSize = "sm",
      onClick = function() common.send("clear-errors") end }))
  end
end

local function render()
  if not isOpen then return end
  local active = common.isActive(snapshot)
  local children = {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "device-tablet", size = 22, color = active and "primary" or "on_surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("title"), fontWeight = "bold", fontSize = 15 }),
        ui.label({ text = common.statusLine(snapshot), color = active and "primary" or "on_surface_variant", maxLines = 2 }),
      }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("panel.refresh"),
        onClick = function() common.send("refresh") end }),
    }),
  }
  setupMessages(children)
  table.insert(children, modeButtons())
  notices(children)
  table.insert(children, placementCard())
  table.insert(children, moonlightCard())
  table.insert(children, ui.row({ gap = 6, justify = "end" }, {
    ui.button({ text = tr("panel.diagnostics"), glyph = "stethoscope", variant = "ghost", controlSize = "sm",
      onClick = function() common.send("doctor") end }),
    ui.button({ text = tr("panel.settings"), glyph = "adjustments", variant = "ghost", controlSize = "sm",
      onClick = function() noctalia.openSettings() end }),
  }))
  panel.render(ui.column({ gap = 12, padding = 4, align = "stretch" }, children))
end

noctalia.state.watch(common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function onOpen(_context)
  isOpen = true
  snapshot = common.snapshot()
  render()
  common.send("refresh")
end

function onClose()
  isOpen = false
end
