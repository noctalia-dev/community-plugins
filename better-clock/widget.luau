local settings = noctalia.settings

local function update()
  local time_text = noctalia.formatTime(settings.time_format)
  local date_text = ""
  if settings.show_date then
    date_text = noctalia.formatTime(settings.date_format)
  end

  desktopWidget.render(ui.column({
    direction = "column",
    h_align = "center",
    v_align = "center",
    spacing = 0
  }, {
    ui.label({
      text = time_text,
      font = "monospace",
      font_size = 14,
      color = "primary"
    }),
    ui.label({
      text = date_text,
      font = "monospace",
      font_size = 10,
      color = "on_surface_variant",
      visible = settings.show_date and date_text ~= ""
    })
  }))
end

noctalia.setUpdateInterval(1000)

update()