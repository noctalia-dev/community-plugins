--!nonstrict
-- Interactive Niri output controls. Niri's `msg output` API is intentionally
-- temporary: this plugin never edits the user's compositor configuration.

local MAX_DISPLAYS = 12
local COMMAND_TIMEOUT_MS = 8000
local SCALE_MARKS = { 0.5, 1, 1.5, 2, 2.5, 3 }
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
  end
  for port, _ in pairs(scaleDraft) do
    if presentPorts[port] ~= true then
      scaleDraft[port] = nil
      scaleEditing[port] = nil
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

local function badge(text, color)
  return ui.row({ fill = color .. "/0.16", radius = 8, paddingH = 7, paddingV = 2, align = "center" }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = color }),
  })
end

local function field(label, control)
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
  local enabled = display.enabled and not actionPending and #resolutions > 0
  local presetScale = presetFor(display.port, display.width, display.height)
  local scale = scaleDraft[display.port] or display.scale
  local minScale = 0.5
  local maxScale = 3.0

  local headerChildren = {
    badge(tostring(position), display.focused and "primary" or "on_surface_variant"),
    ui.glyph({ name = "device-desktop", size = 20, color = display.focused and "primary" or "on_surface_variant" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = display.name, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = display.port, fontSize = 11, color = "on_surface_variant" }),
    }),
  }
  if display.focused then
    table.insert(headerChildren, badge(tr("panel.focused"), "primary"))
  end
  if not display.enabled then
    table.insert(headerChildren, badge(tr("panel.disabled"), "on_surface_variant"))
  end

  local body = {
    ui.row({ gap = 14, align = "end" }, {
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
    }),
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
      ui.glyph({ name = "wand", size = 14, color = "primary" }),
      ui.label({
        text = tr("panel.preset_match", {
          resolution = tostring(display.width) .. "x" .. tostring(display.height),
          scale = formatScale(presetScale),
        }),
        fontSize = 11,
        color = "primary",
      }),
    }))
  end

  return ui.column({
    key = "display:" .. display.port,
    fill = display.focused and "primary/0.055" or "surface_variant/0.18",
    border = display.focused and "primary/0.75" or "outline/0.42",
    borderWidth = display.focused and 2 or 1,
    radius = 13,
    padding = 14,
    gap = 13,
    align = "stretch",
  }, {
    ui.row({ gap = 10, align = "center" }, headerChildren),
    ui.column({ gap = 11, align = "stretch" }, body),
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
  return ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, cards)
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
    paddingV = 8,
    fill = "surface_variant/0.18",
    border = "outline/0.34",
    borderWidth = 1,
    radius = 10,
  }, {
    ui.glyph({ name = "info-circle", size = 13, color = "on_surface_variant" }),
    ui.label({ text = tr("panel.temporary_note"), fontSize = 10, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
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
end

function onConfigChanged()
  render()
end
