--!nonstrict
local pending = 0

local function display()
  local value = noctalia.getConfig and noctalia.getConfig("display")
  if value == "icon_text" or value == "text" then return value end
  return "icon"
end

local ICONS = {
  ["settings"] = true,
  ["settings-2"] = true,
  ["settings-cog"] = true,
  ["adjustments-horizontal"] = true,
  ["adjustments-cog"] = true,
  ["tool"] = true,
  ["tools"] = true,
  ["moon"] = true,
  ["moon-stars"] = true,
  ["moon-2"] = true,
  ["home-cog"] = true,
}

local function icon()
  local value = noctalia.getConfig and noctalia.getConfig("icon")
  return ICONS[value] and value or "moon-stars"
end

local function refresh()
  barWidget.setTooltip(pending > 0 and ("Umbriel Settings: " .. pending .. (pending == 1 and " unsaved change" or " unsaved changes"))
    or "Open Umbriel Settings")
  local mode = display()
  if barWidget.isVertical and barWidget.isVertical() then mode = "icon" end
  -- Unsaved edits tint the icon (the text when there is no icon) instead of adding a mark: a widget that
  -- changes width moves the bar and the panel anchored to it on every unsaved/saved flip, and a mark kept
  -- hidden would leave a gap. Without a color the bar's own default applies again.
  local accent = pending > 0 and "primary" or nil
  local children = {}
  if mode ~= "text" then table.insert(children, ui.glyph({ name = icon(), color = accent })) end
  if mode ~= "icon" then
    table.insert(children, ui.label({ text = "Umbriel Settings", color = mode == "text" and accent or nil }))
  end
  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
end

function update()
  refresh()
end

function onClick()
  noctalia.togglePanel("0rz0rz0rz/umbriel-settings:main")
end

if noctalia.state and noctalia.state.watch then
  noctalia.state.watch("umbriel.pending", function(value)
    pending = tonumber(value) or 0
    refresh()
  end)
end

refresh()
