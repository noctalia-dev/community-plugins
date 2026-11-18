--!nonstrict

local STATUS_KEY = "niri_media_idle_status"
local COMMAND_KEY = "niri_media_idle_command"
local status = noctalia.state.get(STATUS_KEY) or {
  unitState = "unknown",
  protectionState = "unknown",
  busy = false,
  error = "",
}
local requestId = 0

local function render()
  if status.busy == true then
    barWidget.setGlyph("loader-2")
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(noctalia.tr("tooltip.busy"))
  elseif status.unitState == "active" then
    if status.protectionState == "loading" then
      barWidget.setGlyph("loader-2")
      barWidget.setGlyphColor("primary")
      barWidget.setTooltip(noctalia.tr("tooltip.loading"))
    elseif status.protectionState == "protected" then
      barWidget.setGlyph("player-stop")
      barWidget.setGlyphColor("tertiary")
      barWidget.setTooltip(noctalia.tr("tooltip.protected"))
    elseif status.protectionState == "normal" then
      barWidget.setGlyph("player-stop")
      barWidget.setGlyphColor("tertiary")
      barWidget.setTooltip(noctalia.tr("tooltip.normal"))
    elseif status.protectionState == "music_sleep" then
      barWidget.setGlyph("player-stop")
      barWidget.setGlyphColor("tertiary")
      barWidget.setTooltip(noctalia.tr("tooltip.music_sleep"))
    elseif status.protectionState == "unknown" then
      barWidget.setGlyph("player-stop")
      barWidget.setGlyphColor("tertiary")
      barWidget.setTooltip(noctalia.tr("tooltip.protection_unknown"))
    elseif status.protectionState == "incomplete" then
      barWidget.setGlyph("alert-circle")
      barWidget.setGlyphColor("error")
      barWidget.setTooltip(noctalia.tr("tooltip.incomplete"))
    elseif status.protectionState == "music_sleep_incomplete" then
      barWidget.setGlyph("alert-circle")
      barWidget.setGlyphColor("error")
      barWidget.setTooltip(noctalia.tr("tooltip.music_sleep_incomplete"))
    else
      barWidget.setGlyph("alert-circle")
      barWidget.setGlyphColor("error")
      barWidget.setTooltip(noctalia.tr("tooltip.unknown"))
    end
  elseif status.unitState == "failed" then
    barWidget.setGlyph("alert-circle")
    barWidget.setGlyphColor("error")
    barWidget.setTooltip(noctalia.tr("tooltip.failed"))
  elseif status.unitState == "inactive" then
    barWidget.setGlyph("player-play")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(noctalia.tr("tooltip.inactive"))
  else
    barWidget.setGlyph("alert-circle")
    barWidget.setGlyphColor("error")
    local tooltipKey = type(status.error) == "string" and status.error ~= ""
      and "tooltip.status_error" or "tooltip.unknown"
    barWidget.setTooltip(noctalia.tr(tooltipKey))
  end
end

noctalia.state.watch(STATUS_KEY, function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function onClick()
  if status.busy == true then return end
  requestId += 1
  noctalia.state.set(COMMAND_KEY, {
    action = "toggle",
    requestId = `widget-{requestId}`,
  })
end

function onRightClick()
  requestId += 1
  noctalia.state.set(COMMAND_KEY, {
    action = "refresh",
    requestId = `widget-refresh-{requestId}`,
  })
end
