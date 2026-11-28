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

local PROTECTION_VIEW = {
  loading = { glyph = "loader-2", color = "primary", tooltip = "tooltip.loading" },
  protected = { glyph = "player-stop", color = "tertiary", tooltip = "tooltip.protected" },
  normal = { glyph = "player-stop", color = "tertiary", tooltip = "tooltip.normal" },
  music_sleep = { glyph = "player-stop", color = "tertiary", tooltip = "tooltip.music_sleep" },
  unknown = { glyph = "player-stop", color = "tertiary", tooltip = "tooltip.protection_unknown" },
  incomplete = { glyph = "alert-circle", color = "error", tooltip = "tooltip.incomplete" },
  music_sleep_incomplete = { glyph = "alert-circle", color = "error", tooltip = "tooltip.music_sleep_incomplete" },
}
local FALLBACK_PROTECTION_VIEW = {
  glyph = "alert-circle",
  color = "error",
  tooltip = "tooltip.unknown",
}

local function render()
  if status.busy == true then
    barWidget.setGlyph("loader-2")
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(noctalia.tr("tooltip.busy"))
  elseif status.unitState == "active" then
    local view = PROTECTION_VIEW[status.protectionState] or FALLBACK_PROTECTION_VIEW
    barWidget.setGlyph(view.glyph)
    barWidget.setGlyphColor(view.color)
    barWidget.setTooltip(noctalia.tr(view.tooltip))
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
