--!nonstrict
-- Full-width, click-through audio spectrum line along the bottom edge of the bar.

local spectrum = noctalia.state.get("audio-spectrum")

local function graphSeries(values, active)
  local out = {}
  if type(values) ~= "table" or #values == 0 or not active then
    return out
  end

  local count = 64
  for i = 1, count do
    local index = math.max(1, math.floor((i - 0.5) * #values / count) + 1)
    local nextIndex = math.min(#values, index + 1)
    local energy = ((tonumber(values[index]) or 0) + (tonumber(values[nextIndex]) or 0)) / 2
    out[i] = math.max(0, math.min(1, 0.04 + energy * 0.92))
  end
  return out
end

local function render()
  local active = noctalia.getConfig("audio_visualizer") ~= false
    and type(spectrum) == "table"
    and spectrum.active == true
  local values = graphSeries(type(spectrum) == "table" and spectrum.values or nil, active)
  local values2 = {}
  for i, value in ipairs(values) do
    local neighbor = values[math.max(1, i - 2)] or value
    values2[i] = math.max(0, math.min(1, neighbor * 0.72 + value * 0.18))
  end

  layer.render(ui.column({ flexGrow = 1, align = "stretch", justify = "center" }, {
    ui.graph({
      key = "full-width-audio-wave",
      flexGrow = 1,
      height = 7,
      visible = #values > 0,
      values = values,
      values2 = values2,
      color = "primary",
      color2 = "tertiary",
      lineWidth = 1.4,
      fillOpacity = 0,
    }),
  }))
end

noctalia.state.watch("audio-spectrum", function(value)
  spectrum = value
  render()
end)

render()
