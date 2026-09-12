--!nonstrict

local layout = require("./layout.luau")
local controls = require("./controls.luau")

local TRANSFORMS = { "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }
local HDR_INPUTS = { "hdr_min_lum", "hdr_max_lum", "hdr_max_avg_lum" }
local DRAFT_FIELDS = { "hdr_min_lum", "hdr_max_lum", "hdr_max_avg_lum", "icc" }

local outputs = {}
local selectedName = ""
local status = ""
local statusIsError = false
local busy = false
local drafts = {}
local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function selectedOutput()
  for _, output in ipairs(outputs) do
    if output.name == selectedName then
      return output
    end
  end
  return nil
end

local function draftKey(output, key)
  return output.name .. ":" .. key
end

local function advancedValue(output, key)
  local extra = type(output.ruleFields) == "table" and output.ruleFields or {}
  return extra[key] or ""
end

local function syncDraft(output, key)
  drafts[draftKey(output, key)] = advancedValue(output, key)
end

local function loadOutputs()
  layout.query(function(found)
    if found == nil then
      outputs = {}
      status = tr("status.query_failed")
      statusIsError = true
      render()
      return
    end

    outputs = found
    layout.attachRuleFields(outputs)
    for _, output in ipairs(outputs) do
      for _, key in ipairs(DRAFT_FIELDS) do
        syncDraft(output, key)
      end
    end
    if selectedOutput() == nil then
      selectedName = outputs[1] and outputs[1].name or ""
    end
    render()
  end)
end

local function save()
  if layout.rulesPath() == nil then
    busy = false
    status = tr("status.no_profile_path")
    statusIsError = true
    render()
    return
  end

  local ok, err = layout.save(outputs, function()
    busy = false
    status = tr("status.saved")
    statusIsError = false
    loadOutputs()
  end)
  if not ok then
    busy = false
    status = tr("status.save_failed", { error = tostring(err) })
    statusIsError = true
    render()
  end
end

local function commit(output, changes)
  if busy then
    return
  end
  output.ruleFields = type(output.ruleFields) == "table" and output.ruleFields or {}
  for key, value in pairs(changes) do
    if key == "transform" then
      output.transform = value
    elseif key == "vrr" then
      output.adaptiveSync = value == "1"
    else
      output.ruleFields[key] = value ~= "" and value or nil
    end
  end

  busy = true
  status = ""
  render()
  save()
end

local function boolControl(output, key, checked)
  return controls.toggleRow(tr("field." .. key), checked, function(on)
    commit(output, { [key] = on and "1" or "0" })
  end, key, not busy)
end

local function inputControl(output, key)
  local id = draftKey(output, key)
  return controls.control(tr("field." .. key), ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = id,
      value = drafts[id] or "",
      placeholder = tr("advanced.unset"),
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(value)
        drafts[id] = value or ""
      end,
    }),
    ui.button({
      text = tr("action.apply"),
      controlSize = "sm",
      enabled = not busy,
      onClick = function()
        commit(output, { [key] = noctalia.string.trim(drafts[id] or "") })
      end,
    }),
  }))
end

local function transformControl(output)
  return controls.control(tr("field.rr"), controls.chips(TRANSFORMS, output.transform or "normal", function(label)
    commit(output, { transform = label })
  end))
end

local function statusLine()
  if status == "" then
    return nil
  end
  return ui.label({
    text = status,
    fontSize = 11,
    color = statusIsError and "error" or "on_surface_variant",
    maxLines = 2,
  })
end

render = function()
  local output = selectedOutput()
  local nodes = {
    controls.header(tr("advanced.title"), {
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("rescan"), enabled = not busy, onClick = "onRefresh" }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClick" }),
    }),
  }

  if output == nil then
    table.insert(nodes, controls.message(status ~= "" and status or tr("status.no_outputs")))
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
    return
  end

  local picture = { controls.heading(tr("advanced.picture")), transformControl(output) }
  table.insert(picture, boolControl(output, "vrr", output.adaptiveSync == true))
  table.insert(picture, boolControl(output, "custom", advancedValue(output, "custom") == "1"))

  local hdr = {
    controls.heading(tr("advanced.hdr")),
    boolControl(output, "hdr", advancedValue(output, "hdr") == "1"),
    boolControl(output, "hdr_force", advancedValue(output, "hdr_force") == "1"),
  }
  for _, key in ipairs(HDR_INPUTS) do
    table.insert(hdr, inputControl(output, key))
  end

  local body = {
    controls.tiles(outputs, selectedName, function(name)
      selectedName = name
      status = ""
      render()
    end),
    controls.card(picture),
    controls.card(hdr),
    controls.card({ controls.heading(tr("advanced.color")), inputControl(output, "icc") }),
  }
  local note = statusLine()
  if note ~= nil then
    table.insert(body, note)
  end
  table.insert(nodes, ui.scroll({ flexGrow = 1, gap = 10 }, body))
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
end

function onOpen(_context)
  status = ""
  statusIsError = false
  busy = false
  render()
  loadOutputs()
end

function onRefresh()
  status = ""
  statusIsError = false
  loadOutputs()
end

function onCloseClick()
  panel.close()
end

function onKey(chord, pressed)
  if pressed and chord == "escape" then
    panel.close()
    noctalia.togglePanel("prponkshe/mango-displays:panel")
  end
end
