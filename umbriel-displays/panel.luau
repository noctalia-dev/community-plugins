--!nonstrict
-- Power, workspace floor, mode and scale for one display at a time, with the
-- arrangement above it and the rest of the section's keys behind Advanced.
--
-- Every control writes the include file and lets Umbriel's config watcher apply
-- it. The model is updated from what was written rather than re-read: the
-- reload is a filesystem round trip, so an immediate query would answer with
-- the state the control just replaced. Refresh re-reads on demand.

local displays = require("./outputs.luau")
local controls = require("./controls.luau")

-- Umbriel takes any positive scale, but fractional factors off this ladder
-- produce blurry integer-scaled clients more often than they help.
local SCALE_STEPS = { 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0 }

local opened = false
local outputs = {}
local selectedName = ""
local status = ""
local statusIsError = false
-- ui.toggle keeps the state the pointer put it in, so a refused change needs a
-- new node to be drawn from `checked` again rather than from the flip.
local powerKey = 0

local render
local applyRefresh, applyScale, applyWorkspaces

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function fail(message)
  status = message
  statusIsError = true
end

-- ── Model ──────────────────────────────────────────────────────────────────

-- Exact, so the lit tile and the card below it can never disagree: load() is
-- what guarantees selectedName still names a connected display.
local function selected()
  for _, output in ipairs(outputs) do
    if output.name == selectedName then
      return output
    end
  end
  return nil
end

local function scaleSteps(output)
  local list = {}
  for _, step in ipairs(SCALE_STEPS) do
    table.insert(list, step)
  end
  local current = math.floor(output.scale * 100 + 0.5) / 100
  for _, step in ipairs(list) do
    if math.abs(step - current) < 0.001 then
      return list
    end
  end
  table.insert(list, current)
  table.sort(list)
  return list
end

local WORKSPACES_DEFAULT = 3
local WORKSPACES_MIN = 1
local WORKSPACES_MAX = 64

-- A count here means a static inventory; "dynamic" or a list of names does not.
local function staticCount(output)
  return tonumber(displays.text(output.section.workspaces))
end

local function workspaceCount(output)
  return staticCount(output)
    or tonumber(displays.text(output.section.min_workspaces))
    or WORKSPACES_DEFAULT
end

-- ui.select counts its options from zero.
local function optionIndex(list, value)
  for index, entry in ipairs(list) do
    if entry == value then
      return index - 1
    end
  end
  return 0
end

local function load()
  displays.query(function(result)
    if result == nil then
      outputs = {}
      fail(tr("status.query_failed"))
    else
      outputs = result
      -- The workspace keys live in the file and nowhere in the compositor's
      -- own report, so they are read back from the section that owns them.
      local sections = displays.read()
      for _, entry in ipairs(outputs) do
        entry.section = displays.sectionFor(sections, entry)
      end
      if selected() == nil then
        selectedName = outputs[1] ~= nil and outputs[1].name or ""
      end
    end
    if opened then
      render()
    end
  end)
end

-- ── Writing ────────────────────────────────────────────────────────────────

-- A mode or scale change resizes the display, which moves everything to the
-- right of it, so the arrangement is laid out again around the new geometry.
local function commit(output, mutate)
  local sections = displays.apply(outputs, displays.rows(outputs))
  if mutate ~= nil then
    mutate(displays.sectionFor(sections, output))
  end

  displays.write(sections, function(ok, err, unsupported)
    if ok then
      status, statusIsError = tr("status.applied"), false
    else
      -- The value the control just showed never landed, so re-read rather than
      -- leave the panel claiming something the file does not say.
      fail(unsupported ~= nil and tr("status.unsupported", { key = unsupported })
        or tr("status.write_failed", { error = tostring(err) }))
      powerKey = powerKey + 1
      load()
    end
    render()
  end)
end
-- ── View ───────────────────────────────────────────────────────────────────

local function detail(glyph, text)
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
    ui.label({ text = text, fontSize = 12, color = "on_surface_variant", maxLines = 1, maxWidth = 340 }),
  })
end

-- The tile above already carries the connector, so the card leads with the
-- panel's own name and falls back to the connector only when the display
-- reports no make or model.
local function displayTitle(output)
  local name = noctalia.string.trim(output.make .. " " .. output.model)
  if name == "" then
    return output.name
  end
  return name
end

local function summary(output)
  local rows = {
    controls.heading(displayTitle(output), ui.toggle({
      key = string.format("power-%s-%d", output.name, powerKey),
      checked = output.enabled,
      onChange = "onEnabledChange",
    })),
  }
  local mode = output.currentMode
  if mode ~= nil then
    table.insert(rows, detail("app-window", string.format("%s · %s Hz · %gx",
      displays.resolutionOf(mode), displays.hzLabel(mode), output.scale)))
  end
  -- Which name the section is tied to, since that is what decides whether these
  -- settings survive a different port on the next plug.
  table.insert(rows, detail("plug-connected", output.key))
  return ui.column({ gap = 8, padding = controls.PADDING, radius = controls.RADIUS, fill = "surface_variant" }, rows)
end

-- A dynamic output keeps at least this many workspaces, so a bar always shows
-- them. One is the floor Umbriel already applies, so stepping down to it is the
-- same as leaving the key out.
--
-- A static inventory replaces that floor rather than sitting beside it: Umbriel
-- rejects the two together. So this one control edits whichever of the two the
-- display actually has, and Advanced is where the choice between them is made.
-- Three equal segments on the chip grid's rhythm, with the count wearing the
-- same tint a picked chip does.
local function stepper(value, low, high, onSet)
  local function step(label, to, enabled)
    return ui.button({
      text = label,
      controlSize = "sm",
      variant = "outline",
      flexGrow = 1,
      enabled = enabled,
      onClick = function()
        onSet(to)
      end,
    })
  end

  return ui.row({ gap = 8, align = "center" }, {
    step("-", value - 1, value > low),
    ui.row({ justify = "center", align = "center", flexGrow = 1, paddingV = 8, radius = 8, fill = "primary" }, {
      ui.label({ text = tostring(value), fontSize = 13, fontWeight = "bold", color = "on_primary" }),
    }),
    step("+", value + 1, value < high),
  })
end

local function modeCard(output)
  if output.currentMode == nil then
    return nil
  end

  local resLabels = {}
  for _, entry in ipairs(displays.resolutions(output)) do
    table.insert(resLabels, entry.res)
  end
  local currentRes = displays.resolutionOf(output.currentMode)

  local hzLabels = {}
  for _, entry in ipairs(displays.refreshRates(output, currentRes)) do
    table.insert(hzLabels, entry.label)
  end
  local currentHz = displays.hzLabel(output.currentMode)

  local scaleLabels = {}
  for _, step in ipairs(scaleSteps(output)) do
    table.insert(scaleLabels, string.format("%gx", step))
  end
  local currentScale = string.format("%gx", math.floor(output.scale * 100 + 0.5) / 100)

  local refresh
  if #hzLabels <= controls.CHIP_LIMIT then
    refresh = controls.chips(hzLabels, currentHz, applyRefresh)
  else
    refresh = ui.select({
      options = hzLabels,
      selectedIndex = optionIndex(hzLabels, currentHz),
      enabled = output.enabled,
      onChange = "onRefreshChange",
    })
  end

  return controls.card({
    controls.control(
      staticCount(output) ~= nil and tr("field.workspaces_count") or tr("field.workspaces"),
      controls.stepper(workspaceCount(output), WORKSPACES_MIN, WORKSPACES_MAX, 1, applyWorkspaces)
    ),
    controls.control(tr("field.resolution"), ui.select({
      options = resLabels,
      selectedIndex = optionIndex(resLabels, currentRes),
      enabled = output.enabled,
      onChange = "onResolutionChange",
    })),
    controls.control(tr("field.refresh"), refresh),
    controls.control(tr("field.scale"), controls.chips(scaleLabels, currentScale, applyScale)),
  })
end

local function headerButtons()
  return {
    ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("action.refresh"), onClick = "onRefresh" }),
    ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClick" }),
  }
end

-- Arranging is the reason the panel exists, so it leads and sits above the
-- tiles: everything under a display's name belongs to that display. The rest
-- lives behind Advanced, at the bottom.
render = function()
  if not noctalia.commandExists("umbriel") then
    panel.render(ui.column({ flexGrow = 1, gap = 14 }, { controls.header(tr("title"), headerButtons()), controls.message(tr("status.missing_umbriel")) }))
    return
  end

  local output = selected()
  if output == nil then
    panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
      controls.header(tr("title"), headerButtons()),
      controls.message(status ~= "" and status or tr("status.no_outputs")),
    }))
    return
  end

  local body = {
    controls.tiles(outputs, selectedName, function(name)
      selectedName = name
      status, statusIsError = "", false
      render()
    end),
    summary(output),
  }
  local modes = modeCard(output)
  if modes ~= nil then
    table.insert(body, modes)
  end
  if status ~= "" then
    table.insert(body, ui.label({
      text = status,
      fontSize = 11,
      color = statusIsError and "error" or "on_surface_variant",
      maxLines = 2,
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    controls.header(tr("title"), headerButtons()),
    controls.hero(tr("action.arrange"), "layout-grid", "onArrange"),
    ui.scroll({ flexGrow = 1, gap = 10 }, body),
    controls.hero(tr("action.advanced"), "settings", "onAdvanced"),
  }))
end

-- ── Callbacks ──────────────────────────────────────────────────────────────

function onOpen(_context)
  opened = true
  status = ""
  statusIsError = false
  render()
  load()
end

function onClose()
  opened = false
end

function onRefresh()
  status = ""
  statusIsError = false
  load()
end

function onCloseClick()
  panel.close()
end

function onAdvanced()
  noctalia.togglePanel("prponkshe/umbriel-displays:advanced")
end

function onArrange()
  noctalia.togglePanel("prponkshe/umbriel-displays:arrange")
end

local function enabledCount()
  local count = 0
  for _, entry in ipairs(outputs) do
    if entry.enabled then
      count = count + 1
    end
  end
  return count
end

function onEnabledChange(value)
  local output = selected()
  if output == nil then
    return
  end
  local on = value == "true"
  -- The service would switch it straight back on, and between the two writes
  -- there is nothing to draw the panel that asked for it.
  if not on and output.enabled and enabledCount() == 1 then
    fail(tr("status.last_output"))
    powerKey = powerKey + 1
    render()
    return
  end
  output.enabled = on
  commit(output)
end

local function applyMode(output, mode)
  output.currentMode = mode
  commit(output, function(section)
    section.mode = string.format("%q", displays.modeString(mode))
  end)
end

applyRefresh = function(hz)
  local output = selected()
  if output == nil then
    return
  end
  local mode = displays.findMode(output, displays.resolutionOf(output.currentMode), hz)
  if mode ~= nil then
    applyMode(output, mode)
  end
end

applyScale = function(label)
  local output = selected()
  local scale = tonumber(string.match(label, "^([%d.]+)"))
  if output == nil or scale == nil then
    return
  end
  output.scale = scale
  commit(output, function(section)
    section.scale = string.format("%g", scale)
  end)
end

applyWorkspaces = function(count)
  local output = selected()
  if output == nil then
    return
  end
  local key = staticCount(output) ~= nil and "workspaces" or "min_workspaces"
  output.section[key] = tostring(count)
  commit(output, function(section)
    section[key] = tostring(count)
  end)
end

function onResolutionChange(_index, text)
  local output = selected()
  if output == nil then
    return
  end
  local mode = displays.findMode(output, text, displays.hzLabel(output.currentMode))
  if mode ~= nil then
    applyMode(output, mode)
  end
end

function onRefreshChange(_index, text)
  applyRefresh(string.match(text, "^(%S+)") or text)
end
