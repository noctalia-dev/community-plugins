--!nonstrict
-- Bar widget: a glyph (+ optional short caption text) reflecting today's
-- wallpaper. Pure view over daily_wallpaper.luau's "today"/"status" state.
-- Click opens the panel with the full caption, credit, and "learn more" link.

local function tr(key, args) return noctalia.tr(key, args) end

local glyph = noctalia.getConfig("glyph") or "photo"
local showText = noctalia.getConfig("show_text")
local maxChars = tonumber(noctalia.getConfig("max_chars")) or 28

local today = noctalia.state.get("today")
local status = noctalia.state.get("status")

local function truncate(text)
  if #text <= maxChars then
    return text
  end
  return text:sub(1, maxChars - 1) .. "…"
end

local function render()
  barWidget.setGlyph(glyph)

  if type(today) == "table" and type(today.title) == "string" and today.title ~= "" then
    barWidget.setText(showText and truncate(today.title) or "")
    barWidget.setTooltip(today.title)
  else
    barWidget.setText(showText and tr("widget.loading_short") or "")
    local msg = (type(status) == "table" and status.state == "error")
        and (status.message or tr("widget.tooltip_error"))
        or tr("widget.tooltip_loading")
    barWidget.setTooltip(msg)
  end
end

noctalia.state.watch("today", function(value)
  today = value
  render()
end)
noctalia.state.watch("status", function(value)
  status = value
  render()
end)

function onClick()
  if not noctalia.runAsync("noctalia msg panel-toggle 'nzlov/daily-wallpaper:panel'") then
    noctalia.notifyError(tr("widget.title"), tr("widget.panel_launch_failed"))
  end
end

render()
