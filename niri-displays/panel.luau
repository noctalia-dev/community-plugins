--!nonstrict
-- Interactive Niri output controls. Niri's `msg output` API is intentionally
-- temporary: this plugin never edits the user's compositor configuration.

local MAX_DISPLAYS = 12
local COMMAND_TIMEOUT_MS = 8000
local SCALE_MARKS = { 0.5, 1, 1.5, 2, 2.5, 3 }
local TRANSFORM_OPTIONS = {
  { value = "normal", text = "Normal" },
  { value = "90", text = "90°" },
  { value = "180", text = "180°" },
  { value = "270", text = "270°" },
  { value = "flipped", text = "Flipped" },
  { value = "flipped-90", text = "Flipped 90°" },
  { value = "flipped-180", text = "Flipped 180°" },
  { value = "flipped-270", text = "Flipped 270°" },
}
local CENTERED_LAYOUT = { flexGrow = 1, align = "center", justify = "center", gap = 10, padding = 20 }

local snapshot = noctalia.state.get("display_snapshot") or {
  status = "loading",
  error_message = "",
  displays = {},
  updated_at = "",
}
local isOpen = false
local actionPending = false
local actionError = ""
local scaleDraft = {}
local scaleEditing = {}
local positionDraft = {}
local layoutExpanded = false
local selectedPort = nil
local layoutDirection = nil
local layoutOffset = 0

local render

local tr = noctalia.tr

local function quoteShellArgument(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function syncFromState()
  snapshot = noctalia.state.get("display_snapshot") or snapshot
  local presentPorts = {}
  for _, display in ipairs(snapshot.displays) do
    presentPorts[display.port] = true
    if scaleDraft[display.port] == nil or (not actionPending and not scaleEditing[display.port]) then
      scaleDraft[display.port] = display.scale
    end
    if positionDraft[display.port] == nil then
      positionDraft[display.port] = {
        x = display.x,
        y = display.y,
      }
    end
  end
  for port, _ in pairs(scaleDraft) do
    if presentPorts[port] ~= true then
      scaleDraft[port] = nil
      scaleEditing[port] = nil
      positionDraft[port] = nil
    end
  end
end

local function formatRefresh(milliHz)
  local hz = milliHz / 1000
  local rounded = math.floor(hz + 0.5)
  if math.abs(hz - rounded) < 0.01 then
    return tostring(rounded) .. " Hz"
  end
  return string.format("%.3f Hz", hz)
end

local function formatScale(value)
  local text = string.format("%.4f", value)
  text = text:gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function resolutionChoices(display)
  local choices = {}
  local seen = {}
  for _, mode in ipairs(display.modes) do
    local key = tostring(mode.width) .. "x" .. tostring(mode.height)
    if not seen[key] then
      seen[key] = true
      table.insert(choices, { width = mode.width, height = mode.height, text = key })
    end
  end
  return choices
end

local function refreshChoices(display, width, height)
  local choices = {}
  for _, mode in ipairs(display.modes) do
    if mode.width == width and mode.height == height then
      table.insert(choices, {
        refresh_rate = mode.refresh_rate,
        preferred = mode.preferred,
        text = formatRefresh(mode.refresh_rate),
      })
    end
  end
  return choices
end

local function selectedResolutionIndex(display, choices)
  for index, choice in ipairs(choices) do
    if choice.width == display.width and choice.height == display.height then
      return index - 1
    end
  end
  return 0
end

local function selectedRefreshIndex(display, choices)
  for index, choice in ipairs(choices) do
    if choice.refresh_rate == display.refresh_rate then
      return index - 1
    end
  end
  return 0
end

local function selectedTransformIndex(display)
  for index, choice in ipairs(TRANSFORM_OPTIONS) do
    if choice.value == display.transform then
      return index - 1
    end
  end
  return 0
end

local function optionsFromChoices(choices)
  local options = {}
  for _, choice in ipairs(choices) do
    table.insert(options, choice.text)
  end
  return options
end

local function presetFor(port, width, height)
  local rawPresets = noctalia.getConfig("scale_presets")
  local globalScale = nil
  local portScale = nil
  if type(rawPresets) ~= "table" then
    return nil
  end

  for _, raw in ipairs(rawPresets) do
    if type(raw) == "string" then
      local value = noctalia.string.trim(raw)
      local presetPort, presetWidth, presetHeight, presetScale =
        value:match("^([^:]+):(%d+)[xX](%d+)%s*=%s*(%d+%.?%d*)$")
      if presetPort ~= nil then
        if noctalia.string.trim(presetPort) == port
          and tonumber(presetWidth) == width
          and tonumber(presetHeight) == height
          and tonumber(presetScale) > 0 then
          portScale = tonumber(presetScale)
        end
      else
        presetWidth, presetHeight, presetScale =
          value:match("^(%d+)[xX](%d+)%s*=%s*(%d+%.?%d*)$")
        if tonumber(presetWidth) == width
          and tonumber(presetHeight) == height
          and tonumber(presetScale) > 0 then
          globalScale = tonumber(presetScale)
        end
      end
    end
  end
  return portScale or globalScale
end

local function bestRefresh(display, width, height)
  local choices = refreshChoices(display, width, height)
  if #choices == 0 then
    return nil
  end
  for _, choice in ipairs(choices) do
    if choice.refresh_rate == display.refresh_rate then
      return choice.refresh_rate
    end
  end
  for _, choice in ipairs(choices) do
    if choice.preferred then
      return choice.refresh_rate
    end
  end
  return choices[1].refresh_rate
end

local function runNiri(command)
  if actionPending then
    return
  end
  actionPending = true
  actionError = ""
  noctalia.log("niri-displays: running " .. command)
  render()

  local started = noctalia.runAsync(command, function(result)
    actionPending = false
    if result.exitCode ~= 0 then
      local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]*") or ""
      actionError = message ~= "" and message or tr("error.command")
    else
      noctalia.log("niri-displays: display change applied")
      noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
    end
    render()
  end, COMMAND_TIMEOUT_MS)
  if not started then
    actionPending = false
    actionError = tr("error.command")
    render()
  end
end

local function applyMode(display, width, height, refreshRate, automaticScale)
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " mode " .. quoteShellArgument(string.format("%dx%d@%.3f", width, height, refreshRate / 1000))
  if automaticScale ~= nil then
    command ..= " && niri msg output " .. quoteShellArgument(display.port)
      .. " scale " .. quoteShellArgument(formatScale(automaticScale))
    scaleDraft[display.port] = automaticScale
  end
  runNiri(command)
end

local function changeResolution(display, choices, index)
  local choice = choices[index + 1]
  local refreshRate = bestRefresh(display, choice.width, choice.height)
  if refreshRate == nil then
    actionError = tr("error.mode_missing")
    render()
    return
  end
  local automaticScale = presetFor(display.port, choice.width, choice.height)
  applyMode(display, choice.width, choice.height, refreshRate, automaticScale)
end

local function changeRefresh(display, choices, index)
  local choice = choices[index + 1]
  applyMode(display, display.width, display.height, choice.refresh_rate, nil)
end

local function changeTransform(display, index)
  local choice = TRANSFORM_OPTIONS[index + 1]
  if choice == nil then
    return
  end
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " transform " .. quoteShellArgument(choice.value)
  runNiri(command)
end

local function changeScaleDraft(display, value)
  scaleEditing[display.port] = true
  scaleDraft[display.port] = value
  render()
end

local function commitScale(display)
  local scale = scaleDraft[display.port] or display.scale
  scaleEditing[display.port] = false
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " scale " .. quoteShellArgument(formatScale(scale))
  runNiri(command)
end

local displayLogicalSize
local field

local function logicalArea(display)
  local size = displayLogicalSize(display)
  return size.width * size.height
end

local function defaultSelectedPort(displays)
  if selectedPort ~= nil then
    for _, display in ipairs(displays) do
      if display.port == selectedPort and display.enabled then
        return selectedPort
      end
    end
  end
  local best = nil
  for _, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      if best == nil or logicalArea(display) < logicalArea(best) then
        best = display
      end
    end
  end
  selectedPort = best and best.port or nil
  return selectedPort
end

local function referenceDisplay(displays, port)
  local best = nil
  for _, display in ipairs(displays) do
    if display.enabled and display.port ~= port and display.width > 0 and display.height > 0 then
      if best == nil or logicalArea(display) > logicalArea(best) then
        best = display
      end
    end
  end
  return best
end

local function snapPosition(display, ref, direction)
  local size = displayLogicalSize(display)
  local refSize = displayLogicalSize(ref)
  if direction == "right" then
    return ref.x + refSize.width, ref.y + (refSize.height - size.height) / 2
  elseif direction == "left" then
    return ref.x - size.width, ref.y + (refSize.height - size.height) / 2
  elseif direction == "top" then
    return ref.x + (refSize.width - size.width) / 2, ref.y - size.height
  elseif direction == "bottom" then
    return ref.x + (refSize.width - size.width) / 2, ref.y + refSize.height
  end
  return ref.x, ref.y
end

local function setDirection(display, ref, direction)
  layoutDirection = direction
  layoutOffset = 0
  local x, y = snapPosition(display, ref, direction)
  positionDraft[display.port] = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
  render()
end

local function changeLayoutOffset(display, ref, value)
  layoutOffset = value
  local direction = layoutDirection or "right"
  local x, y = snapPosition(display, ref, direction)
  if direction == "right" or direction == "left" then
    y = y + value
  else
    x = x + value
  end
  positionDraft[display.port] = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
  render()
end

local function commitPosition(display)
  local draft = positionDraft[display.port]
  if draft == nil then
    return
  end
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " position set -- " .. tostring(draft.x) .. " " .. tostring(draft.y)
  runNiri(command)
end

local MAP_WIDTH = 320
local MAP_HEIGHT = 150
local MAP_COLORS = { "primary", "tertiary", "secondary", "error" }
local POSITION_STEP = 10

local function isRotatedSideways(transform)
  return transform == "90" or transform == "270"
    or transform == "flipped-90" or transform == "flipped-270"
end

displayLogicalSize = function(display)
  local scale = display.scale > 0 and display.scale or 1
  local width = display.width / scale
  local height = display.height / scale
  if isRotatedSideways(display.transform) then
    return { width = height, height = width }
  end
  return { width = width, height = height }
end

local function effectivePosition(display)
  local draft = positionDraft[display.port]
  if draft ~= nil then
    return draft.x, draft.y
  end
  return display.x, display.y
end

local function layoutBounds(displays)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  local any = false
  for _, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local size = displayLogicalSize(display)
      minX = math.min(minX, display.x)
      minY = math.min(minY, display.y)
      maxX = math.max(maxX, display.x + size.width)
      maxY = math.max(maxY, display.y + size.height)
      any = true
    end
  end
  if not any then
    return nil
  end
  return { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

local function layoutMap(displays)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  local any = false
  for _, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local size = displayLogicalSize(display)
      local x, y = effectivePosition(display)
      minX = math.min(minX, x)
      minY = math.min(minY, y)
      maxX = math.max(maxX, x + size.width)
      maxY = math.max(maxY, y + size.height)
      any = true
    end
  end
  if not any then
    return nil
  end
  local totalW = math.max(1, maxX - minX)
  local totalH = math.max(1, maxY - minY)
  local scale = math.min(MAP_WIDTH / totalW, MAP_HEIGHT / totalH)

  local items = {}
  for index, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local size = displayLogicalSize(display)
      local x, y = effectivePosition(display)
      table.insert(items, {
        index = index,
        label = display.port,
        x = (x - minX) * scale,
        y = (y - minY) * scale,
        w = math.max(44, size.width * scale),
        h = math.max(18, size.height * scale),
      })
    end
  end

  table.sort(items, function(a, b) return a.y < b.y end)
  local rows = {}
  for _, item in ipairs(items) do
    local placed = false
    for _, row in ipairs(rows) do
      if item.y < row.bottom and row.top < item.y + item.h then
        table.insert(row.items, item)
        if item.y < row.top then row.top = item.y end
        if item.y + item.h > row.bottom then row.bottom = item.y + item.h end
        placed = true
        break
      end
    end
    if not placed then
      table.insert(rows, { top = item.y, bottom = item.y + item.h, items = { item } })
    end
  end
  table.sort(rows, function(a, b) return a.top < b.top end)
  for _, row in ipairs(rows) do
    table.sort(row.items, function(a, b) return a.x < b.x end)
  end

  local rowNodes = {}
  local previousBottom = 0
  for rowIndex, row in ipairs(rows) do
    if rowIndex > 1 then
      local gap = row.top - previousBottom
      if gap > 1 then
        table.insert(rowNodes, ui.spacer({ height = math.floor(gap + 0.5) }))
      end
    end
    local cols = {}
    local cursorX = 0
    for _, item in ipairs(row.items) do
      local offset = item.x - cursorX
      if offset > 1 then
        table.insert(cols, ui.spacer({ width = math.floor(offset + 0.5) }))
      end
      local color = MAP_COLORS[item.index % #MAP_COLORS + 1] or "primary"
      local cell = {}
      local topPad = item.y - row.top
      if topPad > 1 then
        table.insert(cell, ui.spacer({ height = math.floor(topPad + 0.5) }))
      end
      table.insert(cell, ui.column({
        width = math.floor(item.w + 0.5),
        height = math.floor(item.h + 0.5),
        fill = color .. "/0.35",
        border = color .. "/0.6",
        borderWidth = 1,
        radius = 4,
        align = "center",
        justify = "center",
        paddingH = 2,
      }, {
        ui.label({
          text = item.label,
          fontSize = 8,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
        }),
      }))
      table.insert(cols, ui.column({ gap = 0, align = "start" }, cell))
      cursorX = item.x + item.w
    end
    table.insert(rowNodes, ui.row({ gap = 0, align = "start" }, cols))
    previousBottom = row.bottom
  end

  return ui.column({ gap = 0, align = "center" }, rowNodes)
end

local function layoutSection(displays)
  local bounds = layoutBounds(displays)
  if bounds == nil then
    return nil
  end

  local header = ui.column({
    fill = "surface_variant/0.18",
    border = "outline/0.42",
    borderWidth = 1,
    radius = 12,
    align = "stretch",
  }, {
    ui.button({
      text = tr("panel.layout"),
      glyph = layoutExpanded and "chevron-down" or "chevron-right",
      variant = "ghost",
      fontSize = 12,
      flexGrow = 1,
      onClick = function()
        layoutExpanded = not layoutExpanded
        render()
      end,
    }),
  })

  if not layoutExpanded then
    return ui.column({ gap = 4, align = "stretch" }, { header })
  end

  local map = layoutMap(displays)
  local children = {}

  if map ~= nil then
    table.insert(children, ui.column({
      fill = "surface_variant/0.18",
      border = "outline/0.34",
      borderWidth = 1,
      radius = 10,
      padding = 10,
      align = "center",
    }, { map }))
  end

  local targetPort = defaultSelectedPort(displays)
  local selected = nil
  if targetPort ~= nil then
    for _, display in ipairs(displays) do
      if display.port == targetPort and display.enabled then
        selected = display
        break
      end
    end
  end

  if selected ~= nil then
    local ref = referenceDisplay(displays, selected.port)
    if ref ~= nil then
      local canMove = not actionPending

      local options = {}
      local optionPorts = {}
      local selectedIndex = 0
      for _, display in ipairs(displays) do
        if display.enabled then
          table.insert(optionPorts, display.port)
          table.insert(options, display.name .. " · " .. display.port)
          if display.port == selected.port then
            selectedIndex = #optionPorts - 1
          end
        end
      end

      local refSize = displayLogicalSize(ref)
      local selectedSize = displayLogicalSize(selected)
      local offsetMin = 0
      local offsetMax = 0
      local hasDirection = layoutDirection ~= nil
      if hasDirection then
        if layoutDirection == "right" or layoutDirection == "left" then
          local half = (refSize.height - selectedSize.height) / 2
          offsetMin = -math.floor(math.max(0, half))
          offsetMax = math.floor(math.max(0, half))
        else
          local half = (refSize.width - selectedSize.width) / 2
          offsetMin = -math.floor(math.max(0, half))
          offsetMax = math.floor(math.max(0, half))
        end
      end

      table.insert(children, ui.column({ gap = 8, align = "stretch" }, {
        ui.row({ gap = 10, align = "center" }, {
          field(tr("panel.position"), ui.select({
            options = options,
            selectedIndex = selectedIndex,
            enabled = canMove,
            onChange = function(index)
              local port = optionPorts[index + 1]
              if port ~= nil and port ~= selectedPort then
                selectedPort = port
                layoutDirection = nil
                layoutOffset = 0
                render()
              end
            end,
          })),
          ui.column({ gap = 4, align = "center" }, {
            ui.row({ gap = 4, align = "center" }, {
              ui.spacer({ width = 32 }),
              ui.button({ glyph = "chevron-up", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "top") end }),
              ui.spacer({ width = 32 }),
            }),
            ui.row({ gap = 4, align = "center" }, {
              ui.button({ glyph = "chevron-left", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "left") end }),
              ui.spacer({ width = 32 }),
              ui.button({ glyph = "chevron-right", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "right") end }),
            }),
            ui.row({ gap = 4, align = "center" }, {
              ui.spacer({ width = 32 }),
              ui.button({ glyph = "chevron-down", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "bottom") end }),
              ui.spacer({ width = 32 }),
            }),
          }),
          ui.column({ gap = 6, align = "stretch", width = 120 }, {
            ui.label({ text = tr("panel.position_offset"), fontSize = 11, color = "on_surface_variant" }),
            ui.slider({
              min = offsetMin,
              max = offsetMax,
              step = POSITION_STEP,
              value = layoutOffset,
              enabled = canMove and hasDirection,
              onChange = function(value)
                changeLayoutOffset(selected, ref, value)
              end,
            }),
          }),
        }),
        ui.button({
          text = tr("panel.apply"),
          variant = "primary",
          glyph = "check",
          enabled = canMove and hasDirection,
          onClick = function()
            commitPosition(selected)
          end,
        }),
      }))
    end
  end

  return ui.column({ gap = 8, align = "stretch" }, {
    header,
    ui.column({
      gap = 10,
      align = "stretch",
      fill = "surface_variant/0.18",
      border = "outline/0.34",
      borderWidth = 1,
      radius = 10,
      padding = 10,
    }, children),
  })
end

local function badge(text, color)
  return ui.row({ fill = color .. "/0.16", radius = 8, paddingH = 7, paddingV = 2, align = "center" }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = color }),
  })
end

field = function(label, control)
  return ui.column({ gap = 5, flexGrow = 1, align = "stretch" }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
    control,
  })
end

local function scaleMarkers(scale)
  local markers = {}
  for _, value in ipairs(SCALE_MARKS) do
    local active = math.abs(scale - value) < 0.026
    table.insert(markers, ui.column({ gap = 0, align = "center" }, {
      ui.label({
        text = "┆",
        fontSize = 12,
        color = active and "primary" or "outline",
      }),
      ui.label({
        text = formatScale(value) .. "×",
        fontSize = 9,
        fontWeight = active and "bold" or "normal",
        color = active and "primary" or "on_surface_variant",
      }),
    }))
  end
  return ui.row({ justify = "space_between", align = "start", paddingH = 4 }, markers)
end

local function displayCard(display, position)
  local resolutions = resolutionChoices(display)
  for _, choice in ipairs(resolutions) do
    local automaticScale = presetFor(display.port, choice.width, choice.height)
    if automaticScale ~= nil then
      choice.text ..= "  →  " .. formatScale(automaticScale) .. "×"
    end
  end
  local refreshes = refreshChoices(display, display.width, display.height)

  local resolutionOptions = optionsFromChoices(resolutions)
  local refreshOptions = optionsFromChoices(refreshes)
  local transformOptions = optionsFromChoices(TRANSFORM_OPTIONS)
  local enabled = display.enabled and not actionPending and #resolutions > 0
  local presetScale = presetFor(display.port, display.width, display.height)
  local scale = scaleDraft[display.port] or display.scale
  local minScale = 0.5
  local maxScale = 3.0

  local headerChildren = {
    badge(tostring(position), display.focused and "primary" or "on_surface_variant"),
    ui.glyph({ name = "device-desktop", size = 18, color = display.focused and "primary" or "on_surface_variant" }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = display.name, fontSize = 12, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = display.port, fontSize = 10, color = "on_surface_variant" }),
    }),
  }
  if display.focused then
    table.insert(headerChildren, badge(tr("panel.focused"), "primary"))
  end
  if not display.enabled then
    table.insert(headerChildren, badge(tr("panel.disabled"), "on_surface_variant"))
  end

  local body = {
    field(tr("panel.resolution"), ui.select({
      options = resolutionOptions,
      selectedIndex = selectedResolutionIndex(display, resolutions),
      enabled = enabled,
      onChange = function(index)
        changeResolution(display, resolutions, index)
      end,
    })),
    field(tr("panel.refresh_rate"), ui.select({
      options = refreshOptions,
      selectedIndex = selectedRefreshIndex(display, refreshes),
      enabled = enabled and #refreshes > 0,
      onChange = function(index)
        changeRefresh(display, refreshes, index)
      end,
    })),
    field(tr("panel.rotation"), ui.select({
      options = transformOptions,
      selectedIndex = selectedTransformIndex(display),
      enabled = enabled,
      onChange = function(index)
        changeTransform(display, index)
      end,
    })),
    ui.column({ gap = 4, align = "stretch" }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = tr("panel.scale"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = formatScale(scale) .. "×", fontWeight = "bold", color = "on_surface" }),
      }),
      ui.slider({
        min = minScale,
        max = maxScale,
        step = 0.05,
        value = scale,
        enabled = display.enabled and not actionPending,
        onChange = function(value)
          changeScaleDraft(display, value)
        end,
        onDragEnd = function()
          commitScale(display)
        end,
      }),
      scaleMarkers(scale),
    }),
  }

  if presetScale ~= nil then
    table.insert(body, ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "wand", size = 13, color = "primary" }),
      ui.label({
        text = tr("panel.preset_match", {
          resolution = tostring(display.width) .. "x" .. tostring(display.height),
          scale = formatScale(presetScale),
        }),
        fontSize = 10,
        color = "primary",
      }),
    }))
  end

  return ui.column({
    key = "display:" .. display.port,
    fill = display.focused and "primary/0.055" or "surface_variant/0.18",
    border = display.focused and "primary/0.75" or "outline/0.42",
    borderWidth = display.focused and 2 or 1,
    radius = 12,
    padding = 10,
    gap = 9,
    align = "stretch",
    flexGrow = 1,
    minWidth = 190,
  }, {
    ui.row({ gap = 8, align = "center" }, headerChildren),
    ui.column({ gap = 8, align = "stretch" }, body),
  })
end

local function body()
  local displays = snapshot.displays
  if #displays == 0 then
    if snapshot.status == "error" then
      return ui.column(CENTERED_LAYOUT, {
        ui.glyph({ name = "alert-circle", size = 38, color = "error" }),
        ui.label({ text = tr("error.title"), fontWeight = "bold", color = "error" }),
        ui.label({ text = snapshot.error_message, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
        ui.button({
          text = tr("panel.retry"),
          glyph = "refresh",
          variant = "primary",
          onClick = function()
            noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
          end,
        }),
      })
    elseif snapshot.status == "ok" then
      return ui.column(CENTERED_LAYOUT, {
        ui.glyph({ name = "device-desktop-off", size = 38, color = "on_surface_variant" }),
        ui.label({ text = tr("panel.empty"), color = "on_surface_variant", textAlign = "center" }),
      })
    end
    return ui.column(CENTERED_LAYOUT, {
      ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
      ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }),
    })
  end

  local cards = {}
  for index, display in ipairs(displays) do
    if index <= MAX_DISPLAYS then
      table.insert(cards, displayCard(display, index))
    end
  end
  if #displays > MAX_DISPLAYS then
    table.insert(cards, ui.label({
      text = tr("panel.more_displays", { count = #displays - MAX_DISPLAYS }),
      color = "on_surface_variant",
      textAlign = "center",
    }))
  end

  local scrollChildren = {}

  local layout = layoutSection(displays)
  if layout ~= nil then
    table.insert(scrollChildren, layout)
  end

  local currentRow = {}
  for _, card in ipairs(cards) do
    table.insert(currentRow, card)
    if #currentRow == 2 then
      table.insert(scrollChildren, ui.row({ gap = 10, align = "start" }, currentRow))
      currentRow = {}
    end
  end
  if #currentRow > 0 then
    table.insert(scrollChildren, ui.row({ gap = 10, align = "start" }, currentRow))
  end

  return ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, scrollChildren)
end

render = function()
  if not isOpen then
    return
  end
  local children = {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "device-desktop", size = 22, color = "primary" }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = tr("panel.subtitle"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({
        text = snapshot.updated_at ~= "" and tr("panel.updated", { time = snapshot.updated_at }) or "",
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.button({ glyph = "close", onClick = panel.close }),
    }),
  }

  if actionError ~= "" then
    table.insert(children, ui.label({ text = actionError, color = "error", fontSize = 11, maxLines = 3 }))
  elseif snapshot.status == "error" and #snapshot.displays > 0 then
    table.insert(children, ui.label({ text = snapshot.error_message, color = "error", fontSize = 11, maxLines = 3 }))
  end

  table.insert(children, body())
  table.insert(children, ui.row({
    gap = 8,
    align = "center",
    paddingH = 10,
    paddingV = 4,
    fill = "surface_variant/0.18",
    border = "outline/0.34",
    borderWidth = 1,
    radius = 10,
  }, {
    ui.glyph({ name = "info-circle", size = 13, color = "on_surface_variant" }),
    ui.label({ text = tr("panel.temporary_note"), fontSize = 10, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 5, align = "stretch" }, children))
end

noctalia.state.watch("display_snapshot", function()
  syncFromState()
  render()
end)

function onOpen(_context)
  scaleEditing = {}
  syncFromState()
  isOpen = true
  noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
  render()
end

function onClose()
  isOpen = false
  scaleEditing = {}
  layoutExpanded = false
end

function onConfigChanged()
  render()
end
