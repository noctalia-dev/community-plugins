--!nonstrict

-- Settings
local glyph = noctalia.getConfig("glyph")
local hideDefault = noctalia.getConfig("hide_default")
local renameDefault = noctalia.getConfig("rename_default")

-- Initial state
local snapshot = { mode = nil, isPango = false, hasError = false }

-- Update the bar widget
local function render()
  if snapshot.hasError or snapshot.mode == nil then
    barWidget.setVisible(false)
    return
  end

  -- Hide widget if default and default should be hidden
  local isDefault = snapshot.mode == "default"
  if isDefault and hideDefault then
    barWidget.setVisible(false)
    return
  end

  -- Rename default if necessary
  local currentMode = snapshot.mode
  if isDefault and renameDefault and renameDefault ~= "" then
    currentMode = renameDefault
  end

  -- Avoid rendering an empty glyph name
  local hasGlyph = glyph and glyph ~= ""

  barWidget.setVisible(true)
  barWidget.render(ui.row({ gap = 4, align = "center" }, {
    ui.glyph({
      name = glyph,
      visible = hasGlyph,
    }),
    ui.label({
      text = currentMode,
    })
  }))
end

-- Render on sway mode changes
noctalia.state.watch("sway-mode", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Initial render
snapshot = noctalia.state.get("sway-mode") or snapshot
render()
