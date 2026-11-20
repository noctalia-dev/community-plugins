--!nonstrict
-- Screen Control dimming layer: one black, click-through surface on each monitor, as dark
-- as that monitor's dim level. The service shows the layer while any monitor is dimmed.

local model = nil

local function render()
  -- The output is not known yet while the script first runs; the watch renders again.
  local name = layer.outputName()
  if name == nil then
    return
  end
  local dim = 0
  for _, monitor in ipairs(model and model.monitors or {}) do
    if monitor.name == name then
      dim = monitor.dim
    end
  end
  -- Black, whatever the theme: the layer stands for less light, not for a color.
  local alpha = math.floor(math.clamp(dim, 0, 1) * 255 + 0.5)
  layer.render(ui.column({ fill = string.format("#000000%02x", alpha), flexGrow = 1 }, {}))
end

noctalia.state.watch("screen-control.model", function(value)
  model = value
  render()
end)
model = noctalia.state.get("screen-control.model")
render()
