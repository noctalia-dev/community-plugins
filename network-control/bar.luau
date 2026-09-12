--!nonstrict
-- Network Control bar widget - the default route's address at a glance.
--
-- The service reports which interface the kernel actually routes through (not
-- the first entry in the routing table, which can be a stray static route), so
-- this stays honest on a box with several defaults. Click opens the panel; the
-- only state this widget owns is presentation.
--
-- While a change is waiting to be confirmed the tile turns into a countdown:
-- the confirm window is the one moment where a glance beats opening the panel.

local net = require("./net.luau")

local KIND_GLYPHS = {
  wifi = "wifi",
  ethernet = "plug-connected",
  dummy = "binary-tree",
  bridge = "network",
  loopback = "refresh",
  vpn = "shield-lock",
}

local snapshot = { available = false }

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function orEmpty(value)
  if value == nil or value == "" then
    return tr("panel.empty")
  end
  return value
end

local function tooltipRows(primary)
  local live = primary.live
  local rows = {
    { key = tr("tooltip.device"), value = primary.device },
  }
  if live ~= nil then
    table.insert(rows, { key = tr("tooltip.connection"), value = orEmpty(live.connection) })
    table.insert(rows, { key = tr("tooltip.ipv4"), value = #live.ipv4_addresses > 0 and table.concat(live.ipv4_addresses, ", ") or tr("panel.empty") })
    if live.ipv4_gateway ~= "" then
      table.insert(rows, { key = tr("tooltip.gateway"), value = live.ipv4_gateway })
    end
    if #live.ipv4_dns > 0 then
      table.insert(rows, { key = tr("tooltip.dns"), value = table.concat(live.ipv4_dns, ", ") })
    end
    if #live.ipv6_addresses > 0 then
      table.insert(rows, { key = tr("tooltip.ipv6"), value = live.ipv6_addresses[1] })
    end
  end
  table.insert(rows, { key = tr("tooltip.open"), value = "" })
  return rows
end

local function render()
  if snapshot.available ~= true then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  if snapshot.pending ~= nil then
    local remaining = math.max(0, math.ceil((snapshot.pending.deadline_ms - (snapshot.now_ms or 0)) / 1000))
    barWidget.setGlyph("hourglass")
    barWidget.setColor("error")
    barWidget.setText(tostring(remaining) .. "s")
    barWidget.setTooltip({
      { key = tr("bar.confirm_title"), value = snapshot.pending.name },
      { key = tr("bar.confirm_body"), value = tostring(remaining) },
    })
    return
  end

  barWidget.setColor("on_surface")
  local primary = snapshot.primary
  if primary == nil then
    barWidget.setGlyph("network-off")
    barWidget.setText(noctalia.getConfig("show_text") == true and tr("bar.offline") or "")
    barWidget.setTooltip(tr("tooltip.offline"))
    return
  end

  local live = primary.live
  local glyph = noctalia.getConfig("glyph") or "network"
  if live ~= nil then
    glyph = KIND_GLYPHS[live.kind] or glyph
  end
  barWidget.setGlyph(glyph)
  if noctalia.getConfig("show_text") == true then
    barWidget.setText(net.primaryLabel(primary))
  else
    barWidget.setText("")
  end
  barWidget.setTooltip(tooltipRows(primary))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("muhammadessam/network-control:panel")
end

noctalia.state.watch("network.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

-- state.watch does not replay an old value to a late-attaching entry, so ask for
-- a snapshot on load instead of rendering the default forever.
noctalia.state.set("network.request", { action = "refresh" })
