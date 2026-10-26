--!nonstrict
-- LOQ RGB: bar widget.
-- Left click: open / close the panel.  Right click: lights on / off.  Scroll: brightness (5 % steps).
-- Event driven: it redraws only when the service publishes a change (no update loop).
local function T(key, subst)
  return noctalia.tr(key, subst)
end

local profile = nil
local status = nil
local counter = 0
local targetBrightness = nil

local function request(name, arg)
  counter = counter + 1
  noctalia.state.set("kb_req_widget", { name = name, arg = arg, id = counter })
end

local function ready()
  return status ~= nil and status.state == "ready"
end

local function render()
  if profile == nil or status == nil then
    barWidget.setGlyph("keyboard")
    barWidget.setText("")
    barWidget.setTooltip(T("widget.waiting"))
    return
  end

  if targetBrightness ~= nil and profile.br == targetBrightness then
    targetBrightness = nil
  end

  local rows = {}
  if not ready() then
    barWidget.setGlyph("alert-circle")
    barWidget.setGlyphColor("error")
    barWidget.setText("")
    table.insert(rows, { T("widget.status"), T("widget.state." .. tostring(status.state)) })
    barWidget.setTooltip(rows)
    return
  end

  if not profile.on then
    barWidget.setGlyph("keyboard-off")
    barWidget.setGlyphColor("on_surface")
  elseif profile.mode == "firmware" then
    barWidget.setGlyph("sparkles")
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyph("keyboard")
    barWidget.setGlyphColor("primary")
  end

  local showLabel = noctalia.getConfig("show_label") == true
  if showLabel and profile.on and profile.mode ~= "firmware" then
    barWidget.setText(tostring(profile.br) .. "%")
  else
    barWidget.setText("")
  end

  local mode = profile.mode
  if not profile.on then
    mode = "off"
  end
  table.insert(rows, { T("widget.mode"), T("mode." .. mode) })
  if profile.on and profile.mode ~= "firmware" then
    table.insert(rows, { T("widget.brightness"), tostring(profile.br) .. " %" })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("kb_profile", function(v)
  if type(v) == "table" then
    profile = v
    render()
  end
end)

noctalia.state.watch("kb_status", function(v)
  if type(v) == "table" then
    status = v
    render()
  end
end)

function onClick()
  noctalia.togglePanel("arthur/loq-rgb:panel")
end

function onRightClick()
  if profile == nil or not ready() then
    return
  end
  if profile.on then
    request("set", "off")
  else
    request("set", "on")
  end
end

function onScroll(axis, steps)
  if axis ~= "vertical" or profile == nil or not ready() or not profile.on or profile.mode == "firmware" then
    return
  end
  if targetBrightness == nil then
    targetBrightness = profile.br
  end
  -- scrolling up means a negative step count = brighter
  targetBrightness = math.max(0, math.min(100, targetBrightness - steps * 5))
  request("bright", targetBrightness)
end

local p0 = noctalia.state.get("kb_profile")
local s0 = noctalia.state.get("kb_status")
if type(p0) == "table" then profile = p0 end
if type(s0) == "table" then status = s0 end
render()
