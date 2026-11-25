--!nonstrict
--[[
  widget.luau - the bar widget: one glyph, plus a tooltip that answers "which
  provider, which model, what is it doing".

  The glyph is the user's setting; while a request is in flight it is replaced
  by a spinner, and while a tool call waits for approval by a warning, so the
  bar shows at a glance that the plugin wants attention.
]]

local DEFAULT_GLYPH = "sparkles"

local function configured_glyph()
  local glyph = noctalia.getConfig("glyph")
  if type(glyph) == "string" and glyph ~= "" then
    return glyph
  end
  return DEFAULT_GLYPH
end

local function apply()
  local status = noctalia.state.get("hub.status") or "idle"
  local info = noctalia.state.get("hub.info") or {}

  if status == "thinking" or status == "streaming" then
    barWidget.setGlyph("loader")
    barWidget.setText("")
  elseif status == "waiting" then
    barWidget.setGlyph("alert-triangle")
    barWidget.setText("")
  else
    barWidget.setGlyph(configured_glyph())
    barWidget.setText("")
  end

  local model = info.model
  if type(model) ~= "string" or model == "" then
    model = noctalia.tr("widget.no_model")
  end

  barWidget.setTooltip({
    { key = noctalia.tr("widget.provider"), value = tostring(info.provider_label or "-") },
    { key = noctalia.tr("widget.model"), value = model },
    { key = noctalia.tr("widget.status"), value = noctalia.tr("status." .. tostring(status)) },
  })
end

function update()
  apply()
end

function onClick()
  noctalia.togglePanel("robpidev/ai-hub:chat")
end

noctalia.state.watch("hub.status", apply)
noctalia.state.watch("hub.info", apply)
noctalia.state.watch("hub.model", apply)

apply()
