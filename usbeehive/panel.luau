--!nonstrict
-- Device panel: power summary, charging diagnostics, and an expandable list of
-- connected devices. Re-renders whenever the service publishes a snapshot.

local model = require("./lib/model.luau")

local snap = noctalia.state.get("snapshot") or model.emptySnapshot()
local expanded = {} -- device key -> true
local isOpen = false

local function muted(text, props)
  props = props or {}
  props.text = text
  props.color = "on_surface_variant"
  props.fontSize = props.fontSize or 12
  return ui.label(props)
end

local function detailRow(key, label, value)
  return ui.row({ key = key, gap = 8 }, {
    muted(label, { width = 80 }),
    ui.label({ text = value, fontSize = 12, flexGrow = 1, maxLines = 3 }),
  })
end

local function deviceDetails(d)
  local rows = {}
  local function add(label, value)
    if value ~= nil and value ~= "" then
      table.insert(rows, detailRow(d.key .. "-" .. label, label, value))
    end
  end

  if d.category ~= "typec" then
    add(noctalia.tr("panel.id"), d.vendorId .. ":" .. d.productId)
  end
  add(noctalia.tr("panel.driver"), d.driver)
  add(noctalia.tr("panel.usb"), d.usbVersion)
  add(noctalia.tr("panel.link"), model.speed(d.linkSpeedMbps))
  if d.category == "typec" then
    add(noctalia.tr("panel.status"), d.status)
  end
  if d.inMW > 0 then
    add(noctalia.tr("panel.power_in"), noctalia.tr("power.up_to", { watts = model.watts(d.inMW) }))
  end
  if d.outMW > 0 then
    add(noctalia.tr("panel.power_out"), noctalia.tr("power.up_to", { watts = model.watts(d.outMW) }))
  end
  if d.contractMW > 0 then
    add(noctalia.tr("panel.contract"), model.watts(d.contractMW))
  end
  if d.cable then
    local parts = {}
    for _, part in ipairs({ d.cable.kind, d.cable.current, d.cable.speed, d.cable.vendor }) do
      if part ~= "" then
        table.insert(parts, part)
      end
    end
    if d.cable.maxWatts > 0 then
      table.insert(parts, noctalia.tr("power.max", { watts = tostring(d.cable.maxWatts) .. "W" }))
    end
    add(noctalia.tr("panel.cable"), table.concat(parts, " · "))
  end
  for i, p in ipairs(d.pdos) do
    add(i == 1 and noctalia.tr("panel.charger") or " ", (p.active and "● " or "○ ") .. model.pdoLabel(p))
  end
  if d.charging then
    add(noctalia.tr("panel.diagnosis"), d.charging.summary)
    add(" ", d.charging.detail)
  end
  return rows
end

local function deviceCard(d)
  local isExpanded = expanded[d.key] == true
  local header = ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = d.glyph, size = 18, color = (d.charging and d.charging.isWarning) and "tertiary" or "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = d.headline, fontWeight = "bold", maxLines = 1 }),
      muted(d.subtitle, { maxLines = 1 }),
    }),
    muted(d.inMW > 0 and model.watts(d.inMW) or model.speed(d.linkSpeedMbps)),
    ui.glyph({ name = isExpanded and "chevron-down" or "chevron-right", size = 14, color = "on_surface_variant" }),
  })

  local children = { header }
  if isExpanded then
    table.insert(children, ui.separator({ spacing = 4 }))
    for _, row in ipairs(deviceDetails(d)) do
      table.insert(children, row)
    end
  end

  return ui.column({
    key = d.key,
    gap = 6,
    padding = 10,
    radius = 10,
    fill = "surface_variant/0.5",
    onClick = function()
      expanded[d.key] = not isExpanded or nil
      render()
    end,
  }, children)
end

local function powerSummary()
  local flow = snap.flow
  if flow.mode == "idle" then
    return nil
  end
  local title = flow.mw > 0 and noctalia.tr("panel." .. flow.mode .. "_at", { watts = model.watts(flow.mw) })
    or noctalia.tr("panel." .. flow.mode)
  local text = { ui.label({ text = title, fontSize = 16, fontWeight = "bold" }) }
  if flow.mode == "charging" then
    local note = flow.requested and noctalia.tr("panel.requested_note") or noctalia.tr("panel.contract_note")
    table.insert(text, muted(note, { maxLines = 2 }))
  end
  return ui.row({ gap = 12, align = "center", padding = 12, radius = 12, fill = "primary/0.12" }, {
    ui.glyph({ name = model.flowGlyph(flow.mode), size = 24, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, text),
  })
end

local function warningCard(w)
  return ui.row({ key = "warn-" .. w.key, gap = 10, padding = 10, radius = 10, fill = "tertiary/0.12" }, {
    ui.glyph({ name = "alert-triangle", size = 18, color = "tertiary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = w.summary, fontWeight = "bold", maxLines = 2 }),
      muted(w.detail, { maxLines = 3 }),
    }),
  })
end

function render()
  local body = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "usb", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.refresh"), onClick = function()
        noctalia.state.set("command", model.refreshCommand(noctalia.nowMs()))
      end }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = function()
        panel.close()
      end }),
    }),
  }

  if snap.error ~= nil then
    table.insert(body, ui.row({ gap = 10, padding = 12, radius = 12, fill = "error/0.12" }, {
      ui.glyph({ name = "plug-x", size = 20, color = "error" }),
      ui.label({ text = snap.error, flexGrow = 1, maxLines = 6 }),
    }))
    table.insert(body, ui.button({ text = noctalia.tr("panel.open_settings"), glyph = "settings", variant = "outline", onClick = function()
      noctalia.openSettings()
    end }))
  end

  local summary = powerSummary()
  if summary then
    table.insert(body, summary)
  end
  for _, w in ipairs(snap.warnings) do
    table.insert(body, warningCard(w))
  end

  local list = {}
  for _, d in ipairs(snap.devices) do
    table.insert(list, deviceCard(d))
  end
  if #list == 0 then
    local empty = snap.status == "starting" and noctalia.tr("status.starting") or noctalia.tr("panel.empty")
    table.insert(list, muted(empty, { fontSize = 14 }))
  end
  table.insert(body, ui.scroll({ gap = 6, flexGrow = 1 }, list))

  -- flexGrow fills the panel so the scroll list below can take the remaining height.
  panel.render(ui.column({ gap = 12, padding = 4, flexGrow = 1 }, body))
end

noctalia.state.watch("snapshot", function(value)
  snap = value or model.emptySnapshot()
  if isOpen then
    render()
  end
end)

function onOpen()
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end
