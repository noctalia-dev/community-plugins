--!nonstrict
-- Bar widget: one compact line that follows the desktop overlay and opens the
-- control panel. Hidden whenever the overlay has nothing to show.

local MAX_CHARS = 48

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function clamp(text)
  if #text <= MAX_CHARS then
    return text
  end
  return string.sub(text, 1, MAX_CHARS - 1) .. "…"
end

function update()
  noctalia.setUpdateInterval(400)

  if not cfg("enabled", true) or noctalia.state.get("lyrics_hidden") == true then
    barWidget.setVisible(false)
    return
  end

  local status = noctalia.state.get("status") or "idle"
  local current = noctalia.state.get("current") or ""
  if current == "" or status == "idle" or status == "off" or status == "filtered" then
    barWidget.setVisible(false)
    return
  end

  barWidget.setVisible(true)
  barWidget.render(ui.row({
    gap = 6,
    onClick = "openPanel",
    tooltip = noctalia.tr("bar.tooltip"),
  }, {
    ui.glyph({ name = "music", size = 13, color = "primary" }),
    ui.label({
      text = clamp(current),
      fontSize = 13,
      fontWeight = "medium",
      color = noctalia.state.get("playing") and "on_surface" or "on_surface/0.5",
      maxLines = 1,
    }),
  }))
end

function openPanel()
  noctalia.togglePanel("alitura/desktop-lyrics:controls")
end

function onClick()
  openPanel()
end
