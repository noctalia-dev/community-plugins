--!nonstrict
-- Monitor Control bar widget - the focused output's current mode at a glance.
--
-- Click opens the panel; every compositor call goes through the service, so
-- several bars on several outputs still share one poller. The widget is a thin
-- presentation of the "monitor.state" snapshot.

local snapshot = { available = false, outputs = {} }

local function outputByName(name)
  for _, output in ipairs(snapshot.outputs or {}) do
    if output.name == name then
      return output
    end
  end
  return nil
end

local function currentModeText(output)
  if output == nil then
    return nil
  end
  for _, mode in ipairs(output.modes or {}) do
    if mode.current == true then
      local hz = mode.refresh_mhz / 1000
      local rounded = math.floor(hz + 0.5)
      local hzText = math.abs(hz - rounded) < 0.02 and tostring(rounded) or string.format("%.2f", hz)
      return `{mode.width}x{mode.height} {hzText}Hz`
    end
  end
  return nil
end

local function render()
  -- Only meaningful on an Umbriel session: take no bar space elsewhere.
  if snapshot.available ~= true then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  -- Prefer the output THIS bar instance sits on: snapshot.focused comes from
  -- the service and can be nil outside a focus-driven refresh.
  local name = barWidget.outputName() or snapshot.focused
  local output = outputByName(name)
  if output == nil then
    -- Fallback: the first enabled output with an active mode, so the widget
    -- still says something useful on a headless/unfocused session.
    for _, candidate in ipairs(snapshot.outputs or {}) do
      if candidate.enabled == true and currentModeText(candidate) ~= nil then
        name = candidate.name
        output = candidate
        break
      end
    end
  end
  local modeText = currentModeText(output)

  barWidget.setGlyph(noctalia.getConfig("glyph") or "device-desktop")
  if noctalia.getConfig("show_text") == true and modeText ~= nil then
    barWidget.setText(modeText)
    barWidget.setTooltip({
      { key = noctalia.tr("tooltip.output"), value = tostring(name) },
      { key = noctalia.tr("tooltip.mode"), value = modeText },
    })
  else
    barWidget.setText("")
    barWidget.setTooltip(noctalia.tr("tooltip.open"))
  end
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("muhammadessam/monitor-control:panel")
end

noctalia.state.watch("monitor.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

-- Ask the service for a fresh snapshot on load: watch does not replay an old
-- value, and render() from a stale default hides the widget.
noctalia.state.set("monitor.request", { action = "refresh" })
