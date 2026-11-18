local time_format = noctalia.getConfig("time_format") or "{:%H:%M}"
local date_format = noctalia.getConfig("date_format") or "{:%A, %B %d}"
local show_date = noctalia.getConfig("show_date")

function update()
  noctalia.setUpdateInterval(1000)

  local time_text = noctalia.formatTime(time_format)
  local date_text = ""
  if show_date then
    date_text = noctalia.formatTime(date_format)
  end

  local content = {
    ui.label({
      text = time_text,
      fontFamily = "Sarasa Mono SC",
      fontSize = 14,
      color = "primary"
    })
  }

  if show_date and date_text ~= "" then
    table.insert(content, ui.label({
      text = date_text,
      fontFamily = "Sarasa Mono SC",
      fontSize = 10,
      color = "on_surface_variant"
    }))
  end

  desktopWidget.render(ui.column({
    gap = 0,
    align = "center"
  }, content))
end

update()