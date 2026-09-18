--!nonstrict
-- The rest of what an [output.*] section can say: rotation, sync policy, HDR,
-- workspace inventory and the scrolling default.
--
-- These are set once for a display and then forgotten, so they live behind
-- their own window rather than in the panel that opens on a click. Every value
-- is written to the same include file the main panel and the arrangement write.

local displays = require("./outputs.luau")
local controls = require("./controls.luau")

local TRANSFORMS = { "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }
local VRR = { "disabled", "always", "fullscreen" }
local HDR = { "off", "on", "auto", "fullscreen" }
local AXIS = { "vertical", "horizontal" }
local WIDTHS = { "inherit", "0.3", "0.4", "0.5", "0.6", "0.8", "1.0" }

local SDR_WHITE = { default = 203, low = 80, high = 1000, step = 5 }
-- The count itself is the main panel's stepper, which edits whichever
-- inventory is active; this window only chooses between them.
local STATIC_DEFAULT = 4

local opened = false
local outputs = {}
local selectedName = ""
local status = ""
local statusIsError = false
local preview = nil
-- Same as the panel's power switch: a rejected write has to redraw the toggle
-- from the value that stands, not the one the pointer left it at.
local toggleKey = 0

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- ── Model ──────────────────────────────────────────────────────────────────

local function selected()
  for _, output in ipairs(outputs) do
    if output.name == selectedName then
      return output
    end
  end
  return nil
end

local function load()
  displays.query(function(result)
    if result == nil then
      outputs = {}
      status, statusIsError = tr("status.query_failed"), true
    else
      outputs = result
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

local function value(output, key, fallback)
  return displays.text(output.section[key]) or fallback
end

-- Writing one key still lays the arrangement out again, since a rotation
-- changes the logical box every display to the right of it sits against.
local function commit(output, changes)
  local sections = displays.apply(outputs, displays.rows(outputs))
  local section = displays.sectionFor(sections, output)
  for key, raw in pairs(changes) do
    section[key] = raw ~= false and raw or nil
    output.section[key] = section[key]
  end

  displays.write(sections, function(ok, err, unsupported)
    if ok then
      status, statusIsError = tr("status.applied"), false
    else
      status, statusIsError = unsupported ~= nil and tr("status.unsupported", { key = unsupported })
        or tr("status.write_failed", { error = tostring(err) }), true
      toggleKey = toggleKey + 1
      load()
    end
    render()
  end)
end

-- ── View ───────────────────────────────────────────────────────────────────

local function enumControl(output, key, options, fallback)
  return controls.control(tr("field." .. key), controls.chips(options, value(output, key, fallback), function(picked)
    commit(output, { [key] = displays.quoted(picked) })
  end))
end

local function boolControl(output, key, fallback)
  return controls.toggleRow(tr("field." .. key), value(output, key, fallback) == "true", function(on)
    commit(output, { [key] = tostring(on) })
  end, string.format("%s-%d", key, toggleKey))
end

-- `preview` is what the handle sits at mid-drag; the stored value only catches
-- up on release, when the write happens.
local function sliderControl(output, key, range)
  local stored = tonumber(value(output, key, tostring(range.default))) or range.default
  local shown = preview or stored
  return controls.control(tr("field." .. key),
    controls.slider(shown, range.low, range.high, range.step, function(next)
      if next ~= preview then
        preview = next
        render()
      end
    end, function(next)
      preview = nil
      commit(output, { [key] = tostring(next) })
    end),
    tostring(shown))
end

-- A static inventory and a dynamic floor cannot both apply, so choosing one
-- clears the other rather than letting Umbriel reject the pair.
local function workspaceControls(output)
  local static = tonumber(value(output, "workspaces", ""))
  local modes = { tr("field.dynamic"), tr("field.static") }
  local mode = static ~= nil and modes[2] or modes[1]

  local nodes = {
    controls.control(tr("field.workspaces_mode"), controls.chips(modes, mode, function(picked)
      if picked == modes[2] then
        commit(output, { workspaces = tostring(STATIC_DEFAULT), min_workspaces = false })
      else
        commit(output, { workspaces = false })
      end
    end)),
  }

  table.insert(nodes, enumControl(output, "workspace_axis", AXIS, "vertical"))
  return nodes
end

local function scrollingControl(output)
  local current = value(output, "layout.scrolling.default_width_fraction", nil)
  return controls.control(tr("field.scrolling_width"),
    controls.chips(WIDTHS, current or WIDTHS[1], function(picked)
      commit(output, {
        ["layout.scrolling.default_width_fraction"] = picked ~= WIDTHS[1] and picked or false,
      })
    end))
end

render = function()
  local output = selected()
  local nodes = {
    controls.header(tr("advanced.title"), {
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("action.refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClick" }),
    }),
  }

  if output == nil then
    table.insert(nodes, controls.message(status ~= "" and status or tr("status.no_outputs")))
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
    return
  end

  local workspaces = { controls.heading(tr("advanced.workspaces")) }
  for _, node in ipairs(workspaceControls(output)) do
    table.insert(workspaces, node)
  end
  table.insert(workspaces, scrollingControl(output))

  local body = {
    controls.tiles(outputs, selectedName, function(name)
      selectedName = name
      status = ""
      render()
    end),
    controls.card({
      controls.heading(tr("advanced.picture")),
      enumControl(output, "transform", TRANSFORMS, "normal"),
      enumControl(output, "vrr", VRR, "disabled"),
      enumControl(output, "hdr", HDR, "off"),
      sliderControl(output, "sdr_white", SDR_WHITE),
    }),
    controls.card(workspaces),
    controls.card({
      controls.heading(tr("advanced.flips")),
      boolControl(output, "tearing", "false"),
      boolControl(output, "direct_scanout", "true"),
    }),
  }

  if status ~= "" then
    table.insert(body, ui.label({
      text = status,
      fontSize = 11,
      color = statusIsError and "error" or "on_surface_variant",
      maxLines = 2,
    }))
  end

  table.insert(nodes, ui.scroll({ flexGrow = 1, gap = 10 }, body))
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
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

-- Escape walks back to the panel this window was opened from, rather than
-- leaving the user on the desktop.
function onKey(chord, pressed)
  if pressed and chord == "escape" then
    panel.close()
    noctalia.togglePanel("prponkshe/umbriel-displays:panel")
  end
end
