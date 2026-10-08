--!nonstrict

-- Visibility settings
local hideEmpty = noctalia.getConfig("hide_empty")
local hideCount = noctalia.getConfig("hide_count")

-- Empty settings
local emptyGlyph = noctalia.getConfig("empty_glyph")
local emptyColor = noctalia.getConfig("empty_color")

-- Populated settings
local populatedGlyph = noctalia.getConfig("populated_glyph")
local populatedColor = noctalia.getConfig("populated_color")

-- Initial state
local snapshot = { count = nil, hasError = false }

-- Update the bar widget
local function render()
  if snapshot.hasError or snapshot.count == nil then
    barWidget.setVisible(false)
    return
  end

  -- Hide widget if empty and empty should be hidden
  local isEmpty = snapshot.count == 0
  if isEmpty and hideEmpty then
    barWidget.setVisible(false)
    return
  end

  -- Select glyph and color based on scratchpad state
  local glyph = isEmpty and emptyGlyph or populatedGlyph
  local color = isEmpty and emptyColor or populatedColor

  -- Hide widget if the count is hidden and there is no glyph
  local hasGlyph = glyph and glyph ~= ""
  if hideCount and not hasGlyph then
    barWidget.setVisible(false)
    return
  end

  barWidget.setVisible(true)
  barWidget.render(ui.row({ gap = 4, align = "center" }, {
    ui.glyph({
      name = glyph,
      color = color,
      visible = hasGlyph,
    }),
    ui.label({
      text = tostring(snapshot.count),
      color = color,
      visible = not hideCount,
    })
  }))
end

-- Render on sway scratchpad changes
noctalia.state.watch("sway-scratchpad", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Initial render
snapshot = noctalia.state.get("sway-scratchpad") or snapshot
render()
