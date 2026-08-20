--!nonstrict
-- Hover preview panel for Flex Taskbar.

local opened = false

local function cfg(key)
  return noctalia.getConfig(key)
end

local function setPanelHovered(state)
  noctalia.state.set("preview_panel_hovered", state == "true")
end

local function focusWindow(windowId)
  local id = tonumber(windowId)
  if id == nil then return end
  noctalia.runAsync("niri msg action focus-window --id " .. tostring(math.floor(id)))
  panel.close()
end

local function fallbackIcon(appId)
  return noctalia.appIconPath(tostring(appId or ""), tonumber(cfg("preview_width")) or 190)
end

local function makeCard(window)
  local width = tonumber(cfg("preview_width")) or 190
  local height = tonumber(cfg("preview_height")) or 115
  local radius = tonumber(cfg("preview_radius")) or 8
  local content = {}

  if window.ready == true and noctalia.fileExists(tostring(window.path or "")) then
    table.insert(content, ui.image({
      key = "thumb-" .. tostring(window.id),
      path = tostring(window.path),
      width = width,
      height = height,
      radius = radius,
      fit = "cover",
    }))
  else
    local icon = fallbackIcon(window.app_id)
    if icon ~= nil then
      table.insert(content, ui.image({
        key = "fallback-" .. tostring(window.id),
        path = icon,
        width = math.min(64, width),
        height = math.min(64, height),
        radius = radius,
        fit = "contain",
        opacity = 0.65,
      }))
    else
      table.insert(content, ui.glyph({ name = "app-window", size = 46, opacity = 0.55 }))
    end
  end

  if cfg("preview_show_titles") == true then
    table.insert(content, ui.label({
      key = "title-" .. tostring(window.id),
      text = tostring(window.title or "Window"),
      fontSize = tonumber(cfg("preview_title_size")) or 11,
      maxWidth = width,
      maxLines = 1,
      textAlign = "center",
      color = window.focused == true and "primary" or "on_surface",
    }))
  end

  return ui.column({
    key = "window-" .. tostring(window.id),
    width = width + 12,
    padding = 6,
    gap = 6,
    align = "center",
    justify = "center",
    fill = cfg("preview_card_color"),
    radius = radius + 3,
    border = window.focused == true and "primary" or cfg("preview_border_color"),
    borderWidth = tonumber(cfg("preview_border_width")) or 1.0,
    onClick = function() focusWindow(window.id) end,
    onHover = setPanelHovered,
  }, content)
end

local function render()
  if not opened then return end
  local data = noctalia.state.get("preview_data") or {}
  local cards = {}
  for _, window in ipairs(data) do table.insert(cards, makeCard(window)) end

  if #cards == 0 then
    table.insert(cards, ui.column({ align = "center", justify = "center", flexGrow = 1 }, {
      ui.glyph({ name = "photo-off", size = 34, opacity = 0.5 }),
      ui.label({ text = "No window previews", opacity = 0.6 }),
    }))
  end

  panel.render(ui.row({
    padding = 12,
    gap = tonumber(cfg("preview_gap")) or 10,
    align = "center",
    justify = "center",
    onHover = setPanelHovered,
  }, cards))
end

noctalia.state.watch("preview_data", function(_value)
  render()
end)

function onOpen(_context)
  opened = true
  noctalia.state.set("preview_open", true)
  noctalia.state.set("preview_panel_hovered", false)
  render()
end

function onClose()
  opened = false
  noctalia.state.set("preview_open", false)
  noctalia.state.set("preview_panel_hovered", false)
end

function onExit()
  noctalia.state.set("preview_open", false)
  noctalia.state.set("preview_panel_hovered", false)
end
