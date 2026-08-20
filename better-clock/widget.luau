local settings = noctalia.settings

local function update()
  local time_text = noctalia.formatTime(settings.time_format)
  local date_text = ""
  if settings.show_date then
    date_text = noctalia.formatTime(settings.date_format)
  end

  local content = {
    ui.label({
      text = time_text,
      fontFamily = "monospace",
      fontSize = 14,
      color = "primary"
    })
  }

  if settings.show_date and date_text ~= "" then
    table.insert(content, ui.label({
      text = date_text,
      fontFamily = "monospace",
      fontSize = 10,
      color = "on_surface_variant"
    }))
  end

  desktopWidget.render(ui.column({
    gap = 0,
    align = "center"
  }, content))
end

noctalia.setUpdateInterval(1000)

update()