local unit = noctalia.getConfig("unit")
local glucose = noctalia.state.get("glucose") or 0

local molar_mass = 180.156

local function render()
  if trend == "DoubleDown" then
    barWidget.setGlyph("arrows-down")
  elseif trend == "SingleDown" then
    barWidget.setGlyph("arrow-down")
  elseif trend == "FortyFiveDown" then
    barWidget.setGlyph("arrow-down-right")
  elseif trend == "Flat" then
    barWidget.setGlyph("arrow-right")
  elseif trend == "FortyFiveUp" then
    barWidget.setGlyph("arrow-up-right")
  elseif trend == "SingleUp" then
    barWidget.setGlyph("arrow-up")
  elseif trend == "DoubleUp" then
    barWidget.setGlyph("arrows-up")
  else
    barWidget.setGlyph("backslash")
  end

  if glucose == 0 then
    barWidget.setText("---")
    return
  end

  if unit == "mmol/L" then
    barWidget.setText((string.format("%.1f", (glucose*10)/molar_mass )) .. " mmol/L")
  elseif unit == "mg/dL" then
    barWidget.setText(glucose .. " mg/dL")
  end
end

render()

noctalia.state.watch("glucose", function(value)
  trend = noctalia.state.get("trend")
  glucose = value
  render()
end)

function onClick()
  noctalia.runAsync("noctalia msg plugin nuddel69/nightscout-monitor:ticker all fetch", function() end)
end
