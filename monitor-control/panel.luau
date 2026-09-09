--!nonstrict
-- Monitor Control panel - pick a monitor, set its resolution and refresh rate,
-- and place it left/right/above/below the others.
--
-- Every change becomes one "monitor.request" on the plugin's shared state: the
-- service patches the Umbriel config, validates and reloads it, and answers
-- with a fresh "monitor.state" snapshot. The panel owns no compositor calls.
--
-- Resolution and refresh are drafted per monitor (two selects that must agree
-- on one mode line), and only an explicit "Apply" writes the config - so
-- fiddling with the dropdowns never re-modes a live display.

local snapshot = { available = false, outputs = {} }

-- connector -> { width, height, refresh_mhz, index } draft selections, kept
-- across renders and refreshed from the live mode when the panel opens.
local drafts = {}

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function hzText(refreshMhz)
  local hz = refreshMhz / 1000
  local rounded = math.floor(hz + 0.5)
  if math.abs(hz - rounded) < 0.02 then
    return tostring(rounded)
  end
  return string.format("%.2f", hz)
end

local function modeId(mode)
  return `{mode.width}x{mode.height}@{hzText(mode.refresh_mhz)}`
end

-- The modes a draft selects, deduplicated: widths for the resolution list, and
-- refreshes for the selected resolution.
local function resolutions(modes)
  local seen, list = {}, {}
  for _, mode in ipairs(modes) do
    local key = `{mode.width}x{mode.height}`
    if not seen[key] then
      seen[key] = true
      table.insert(list, key)
    end
  end
  return list
end

local function refreshesFor(modes, resolution)
  local seen, list = {}, {}
  for _, mode in ipairs(modes) do
    if `{mode.width}x{mode.height}` == resolution then
      local key = hzText(mode.refresh_mhz)
      if not seen[key] then
        seen[key] = true
        table.insert(list, { label = key, mode = mode })
      end
    end
  end
  return list
end

local function draftFor(output)
  local draft = drafts[output.name]
  if draft ~= nil then
    return draft
  end
  local modes = output.modes or {}
  local current = nil
  for _, mode in ipairs(modes) do
    if mode.current == true then
      current = mode
      break
    end
  end
  current = current or modes[1]
  draft = {}
  if current ~= nil then
    draft.resolution = `{current.width}x{current.height}`
    draft.mode = modeId(current)
  end
  drafts[output.name] = draft
  return draft
end

local function request(value)
  noctalia.state.set("monitor.request", value)
end

-- Forward declaration: the outputCard closures re-render the panel, and a
-- plain `local function render` below would not be visible to them.
local render

local function sectionTitle(text)
  return ui.label({ text = text, fontWeight = "bold", fontSize = 13 })
end

local PLACE_BUTTONS = {
  { side = "left", glyph = "arrow-bar-to-left", key = "panel.place_left" },
  { side = "right", glyph = "arrow-bar-to-right", key = "panel.place_right" },
  { side = "up", glyph = "arrow-bar-to-up", key = "panel.place_up" },
  { side = "down", glyph = "arrow-bar-to-down", key = "panel.place_down" },
}

local function outputCard(output)
  local modes = output.modes or {}
  local draft = draftFor(output)
  local resolutionsList = resolutions(modes)

  local resolutionIndex = 0
  for index, label in ipairs(resolutionsList) do
    if label == draft.resolution then
      resolutionIndex = index - 1
    end
  end

  local refreshList = refreshesFor(modes, draft.resolution or resolutionsList[1] or "")
  local refreshIndex = 0
  for index, entry in ipairs(refreshList) do
    if modeId(entry.mode) == draft.mode then
      refreshIndex = index - 1
    end
  end

  local currentText = nil
  for _, mode in ipairs(modes) do
    if mode.current == true then
      currentText = `{mode.width}x{mode.height} @ {hzText(mode.refresh_mhz)}Hz`
    end
  end

  local placeRow = {}
  for _, button in ipairs(PLACE_BUTTONS) do
    table.insert(placeRow, ui.button({
      glyph = button.glyph,
      tooltip = tr(button.key),
      variant = "outline",
      flexGrow = 1,
      enabled = snapshot.busy ~= true,
      onClick = function()
        request({ action = "arrange", name = output.name, side = button.side })
      end,
    }))
  end

  return ui.column({ gap = 8, padding = 10, radius = 8, border = "outline/0.4", borderWidth = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "device-desktop", size = 18, color = output.enabled == true and "primary" or "on_surface_variant" }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = output.name, fontWeight = "bold", fontSize = 13 }),
        ui.label({
          text = (output.description ~= nil and output.description ~= "") and output.description
            or (output.make or "") .. " " .. (output.model or ""),
          color = "on_surface_variant", fontSize = 11, maxWidth = 300, maxLines = 1,
        }),
      }),
      ui.label({ text = currentText or tr("panel.off"), color = "on_surface_variant", fontSize = 11 }),
    }),

    ui.row({ gap = 6, align = "center" }, {
      ui.select({
        key = `res-{output.name}`,
        options = resolutionsList,
        selectedIndex = resolutionIndex,
        placeholder = tr("panel.resolution"),
        flexGrow = 1,
        enabled = snapshot.busy ~= true and #resolutionsList > 0,
        onChange = function(index, text)
          local fresh = draftFor(output)
          fresh.resolution = tostring(text)
          local options = refreshesFor(modes, tostring(text))
          fresh.mode = #options > 0 and modeId(options[1].mode) or nil
          drafts[output.name] = fresh
          render()
        end,
      }),
      ui.select({
        key = `hz-{output.name}`,
        options = (function()
          local labels = {}
          for _, entry in ipairs(refreshList) do
            table.insert(labels, entry.label .. " Hz")
          end
          return labels
        end)(),
        selectedIndex = refreshIndex,
        placeholder = tr("panel.refresh"),
        width = 120,
        enabled = snapshot.busy ~= true and #refreshList > 0,
        onChange = function(index, text)
          local entry = refreshList[tonumber(index) + 1]
          if entry ~= nil then
            local fresh = draftFor(output)
            fresh.mode = modeId(entry.mode)
            drafts[output.name] = fresh
            render()
          end
        end,
      }),
      ui.button({
        glyph = "check",
        tooltip = tr("panel.apply"),
        variant = "primary",
        enabled = snapshot.busy ~= true and draft.mode ~= nil,
        onClick = function()
          if draft.mode ~= nil then
            request({ action = "set-mode", name = output.name, mode = draft.mode })
          end
        end,
      }),
    }),

    ui.row({ gap = 6 }, placeRow),
  })
end

function render()
  local header = ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "device-desktop", size = 20, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh_state"), onClick = "onRefresh" }),
    ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
  })

  if snapshot.available ~= true then
    panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, {
      header,
      ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "surface_variant/0.35" }, {
        ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
        ui.label({ text = tr("panel.unavailable"), color = "on_surface_variant", fontSize = 12, flexGrow = 1 }),
      }),
    }))
    return
  end

  local children = { header }
  if snapshot.busy == true then
    table.insert(children, ui.label({ text = tr("panel.busy"), color = "primary", fontSize = 12 }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(children, ui.label({ text = snapshot.error, color = "error", fontSize = 11 }))
  end

  table.insert(children, sectionTitle(tr("panel.monitors")))
  local shown = 0
  for _, output in ipairs(snapshot.outputs or {}) do
    table.insert(children, outputCard(output))
    shown += 1
  end
  if shown == 0 then
    table.insert(children, ui.label({ text = tr("panel.no_outputs"), color = "on_surface_variant", fontSize = 12 }))
  end

  table.insert(children, ui.label({
    text = tr("panel.persist_note"), color = "on_surface_variant", fontSize = 10, opacity = 0.8,
  }))

  panel.render(ui.scroll({ flexGrow = 1, gap = 10, padding = 10 }, children))
end

function onRefresh()
  request({ action = "refresh" })
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  snapshot = noctalia.state.get("monitor.state") or snapshot
  drafts = {}
  request({ action = "refresh" })
  render()
end

noctalia.state.watch("monitor.state", function(value)
  if type(value) == "table" then
    local wasBusy = snapshot.busy
    snapshot = value
    if wasBusy == true and value.busy ~= true then
      -- An apply landed (or failed): re-read drafts from the new live state.
      drafts = {}
    end
    render()
  end
end)
