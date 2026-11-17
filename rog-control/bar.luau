--!nonstrict
-- ROG Control bar widget: the performance mode at a glance.
--
-- One glyph (leaf, scale, rocket). Hover for mode, graphics and battery; click for
-- the panel; one scroll flick steps the mode. It redraws only when the service
-- publishes a new snapshot: no timer work.

local model = require("./lib/model.luau")

local snapshot = { available = false }

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function gpuLabel(s)
  if s.gpu ~= nil then
    local g = model.gpuMode(s.gpu.mode)
    return g ~= nil and tr(g.key) or tr("gpu.other")
  end
  local fw = s.asusd ~= nil and s.asusd.gpuFirmware or nil
  if fw ~= nil then
    if fw.muxDiscrete then
      return tr("gpu.ultimate")
    end
    return tr(fw.dgpuDisabled and "gpu.eco" or "gpu.standard")
  end
  return nil
end

local function render()
  local a = snapshot.asusd
  if snapshot.available ~= true or a == nil then
    -- Not an asusd machine (or asusd is down): say why on hover rather than
    -- leaving a dead icon, but take as little room as possible.
    barWidget.render(ui.glyph({ name = "device-laptop", color = "on_surface_variant" }))
    barWidget.setTooltip(snapshot.error or tr("error.no_asusd"))
    return
  end

  local p = model.profile(a.profile)
  local glyph = ui.glyph({ name = p ~= nil and p.glyph or "gauge" })

  local rows = { { key = tr("tooltip.mode"), value = p ~= nil and tr(p.key) or "?" } }
  local gpu = gpuLabel(snapshot)
  if gpu ~= nil then
    table.insert(rows, { key = tr("tooltip.graphics"), value = gpu })
  end
  local charge = snapshot.charge
  if charge ~= nil then
    table.insert(rows, {
      key = tr("tooltip.battery"),
      value = charge.enabled and tr("tooltip.limit", { percent = charge.limit or 80 }) or tr("tooltip.full"),
    })
  end
  barWidget.setTooltip(rows)

  if barWidget.isVertical() or noctalia.getConfig("show_label") ~= true then
    barWidget.render(glyph)
    return
  end
  barWidget.render(ui.row({ gap = 6, align = "center" }, {
    glyph,
    ui.label({ text = p ~= nil and tr(p.key) or "", fontWeight = "medium" }),
  }))
end

function onClick()
  noctalia.togglePanel(model.PANEL_ID)
end

function onScroll(axis, steps, startsGesture)
  -- One step per flick: a mode per wheel notch would race past the one you wanted.
  if axis ~= "vertical" or not startsGesture or noctalia.getConfig("scroll_changes_mode") == false then
    return
  end
  noctalia.state.set(model.REQUEST, { action = "cycleProfile", value = steps > 0 and 1 or -1, at = noctalia.nowMs() })
end

function onConfigChanged()
  render()
end

noctalia.state.watch(model.STATE, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Nothing here changes with time; redraws are driven by the snapshot.
noctalia.setUpdateInterval(3600000)
snapshot = noctalia.state.get(model.STATE) or snapshot
render()
