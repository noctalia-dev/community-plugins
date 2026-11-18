--!nonstrict

-- Visibility settings
local hideInactive = noctalia.getConfig("hide_inactive")
local showCapsLock = noctalia.getConfig("show_caps_lock")
local showNumLock = noctalia.getConfig("show_num_lock")
local showScrollLock = noctalia.getConfig("show_scroll_lock")

-- Glyph settings
local iconSpacing = noctalia.getConfig("icon_spacing")
local capsLockGlyph = noctalia.getConfig("caps_lock_glyph")
local numLockGlyph = noctalia.getConfig("num_lock_glyph")
local scrollLockGlyph = noctalia.getConfig("scroll_lock_glyph")

-- Color settings
local activeColor = noctalia.getConfig("active_color")
local inactiveColor = noctalia.getConfig("inactive_color")

-- Initial state
local snapshot = {
  hasError = false,
  capsLocked = false,
  numLocked = false,
  scrollLocked = false,
}

-- Update the bar widget
local function render()
  if snapshot.hasError then
    barWidget.setVisible(false)
    return
  end

  -- Invert condition for readability
  local showInactive = not hideInactive

  -- Determine if glyphs should be visible according to state and settings
  local capsVisible = showCapsLock and (showInactive or snapshot.capsLocked)
  local numVisible = showNumLock and (showInactive or snapshot.numLocked)
  local scrollVisible = showScrollLock and (showInactive or snapshot.scrollLocked)

  -- Skip rendering for empty glyphs
  local renderCaps = capsVisible and capsLockGlyph and capsLockGlyph ~= ""
  local renderNum = numVisible and numLockGlyph and numLockGlyph ~= ""
  local renderScroll = scrollVisible and scrollLockGlyph and scrollLockGlyph ~= ""

  -- Only render if there is at least one glyph to show
  if not renderCaps and not renderNum and not renderScroll then
    barWidget.setVisible(false)
    return
  end

  barWidget.setVisible(true)
  barWidget.render(ui.row({ gap = iconSpacing, align = "center" }, {
    ui.glyph({
      name = capsLockGlyph,
      color = snapshot.capsLocked and activeColor or inactiveColor,
      visible = renderCaps,
    }),
    ui.glyph({
      name = numLockGlyph,
      color = snapshot.numLocked and activeColor or inactiveColor,
      visible = renderNum,
    }),
    ui.glyph({
      name = scrollLockGlyph,
      color = snapshot.scrollLocked and activeColor or inactiveColor,
      visible = renderScroll,
    }),
  }))
end

-- Render on keyboard state changes
noctalia.state.watch("keyboard-state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

-- Initial render
snapshot = noctalia.state.get("keyboard-state") or snapshot
render()
