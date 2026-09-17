--!nonstrict
-- Desktop widget: a small always-visible card showing today's wallpaper
-- caption and credit. Pure view over daily_wallpaper.luau's "today"/"status"
-- state — static, so no onFrameTick is needed.

local function tr(key, args) return noctalia.tr(key, args) end

local WRAP = 220

local function render()
  local today = noctalia.state.get("today")
  local status = noctalia.state.get("status")

  local rows = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "photo", size = 16, color = "secondary" }),
      ui.label({ text = tr("widget.title"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    }),
  }

  if type(today) == "table" and type(today.title) == "string" and today.title ~= "" then
    rows[#rows + 1] = ui.label({ text = today.title, fontSize = 14, fontWeight = "medium", maxWidth = WRAP, maxLines = 4 })
    if today.credit and today.credit ~= "" then
      rows[#rows + 1] = ui.label({ text = today.credit, fontSize = 11, opacity = 0.7, maxWidth = WRAP, maxLines = 2 })
    end
  else
    local msg = (type(status) == "table" and status.state == "error")
        and tr("widget.tooltip_error") or tr("widget.tooltip_loading")
    rows[#rows + 1] = ui.label({ text = msg, fontSize = 12, opacity = 0.7, maxWidth = WRAP })
  end

  desktopWidget.render(ui.column({ gap = 4, padding = 10 }, rows))
end

noctalia.state.watch("today", render)
noctalia.state.watch("status", render)
render()
