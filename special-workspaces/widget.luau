local STATE_KEY = "special_workspaces"
local PILL_HEIGHT = 16
local PILL_GAP = 4
local state = noctalia.state.get(STATE_KEY) or {}
local maxLabelChars = tonumber(noctalia.getConfig("max_label_chars")) or 0
local hideInactive = noctalia.getConfig("hide_inactive") == true
local capsuleRadius = math.max(0, tonumber(noctalia.getConfig("capsule_radius")) or 8)
local capsulePadding = math.max(0, tonumber(noctalia.getConfig("capsule_padding")) or 5)
local capsuleMinWidth = math.max(0, tonumber(noctalia.getConfig("capsule_min_width")) or 35)
local activeStyle = noctalia.getConfig("active_style") or "fill"
local inactiveStyle = noctalia.getConfig("inactive_style") or "fill"
local renderedVertical = nil

local function displayName(name)
  if maxLabelChars <= 0 then
    return name
  end

  local nextOffset = utf8.offset(name, maxLabelChars + 1)
  if nextOffset then
    return string.sub(name, 1, nextOffset - 1)
  end
  return name
end

local function verticalName(name)
  local characters = {}
  for _, codepoint in utf8.codes(name) do
    table.insert(characters, utf8.char(codepoint))
  end
  return table.concat(characters, "\n")
end

local function render(vertical)
  renderedVertical = vertical
  local container = vertical and ui.column or ui.row
  local capsule = vertical and ui.column or ui.row
  local chips = {}

  for _, workspace in ipairs(state) do
    if workspace.active or not hideInactive then
      local name = workspace.name
      local style = workspace.active and activeStyle or inactiveStyle
      local filled = style == "fill"
      local fill = filled
          and (workspace.active and "primary" or "secondary")
        or "#00000000"
      local textColor = filled
          and (workspace.active and "on_primary" or "on_secondary")
        or (workspace.active and "primary" or "on_surface")
      local capsuleProps = {
        key = name,
        align = "center",
        justify = "center",
        fill = fill,
        radius = capsuleRadius,
      }
      if vertical then
        capsuleProps.width = PILL_HEIGHT
        capsuleProps.minHeight = capsuleMinWidth
        capsuleProps.paddingV = capsulePadding
      else
        capsuleProps.height = PILL_HEIGHT
        capsuleProps.minWidth = capsuleMinWidth
        capsuleProps.paddingH = capsulePadding
      end

      local label = displayName(name)
      table.insert(chips, capsule(capsuleProps, {
        ui.label({
          text = vertical and verticalName(label) or label,
          fontSize = 11,
          color = textColor,
          textAlign = "center",
        }),
      }))
    end
  end

  barWidget.render(container({ gap = PILL_GAP, align = "center" }, chips))
end

function update()
  local vertical = barWidget.isVertical()
  if vertical ~= renderedVertical then
    render(vertical)
  end
end

noctalia.state.watch(STATE_KEY, function(value)
  state = type(value) == "table" and value or {}
  render(renderedVertical)
end)

function onConfigChanged()
  maxLabelChars = tonumber(noctalia.getConfig("max_label_chars")) or 0
  hideInactive = noctalia.getConfig("hide_inactive") == true
  capsuleRadius = math.max(0, tonumber(noctalia.getConfig("capsule_radius")) or 8)
  capsulePadding = math.max(0, tonumber(noctalia.getConfig("capsule_padding")) or 5)
  capsuleMinWidth = math.max(0, tonumber(noctalia.getConfig("capsule_min_width")) or 35)
  activeStyle = noctalia.getConfig("active_style") or "fill"
  inactiveStyle = noctalia.getConfig("inactive_style") or "fill"
  render(renderedVertical)
end

render(barWidget.isVertical())
