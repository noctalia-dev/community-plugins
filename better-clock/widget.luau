local settings = noctalia.settings
local root = ui.box({ direction = "column", hAlign = "center", vAlign = "center", spacing = 0 })

local time_label = ui.label({
  text = "",
  font = "monospace",
  fontSize = 14,
  color = "primary"
})

local date_label = ui.label({
  text = "",
  font = "monospace",
  fontSize = 10,
  color = "on_surface_variant"
})

local function update()
  time_label.text = noctalia.formatTime(settings.time_format)
  if settings.show_date then
    date_label.text = noctalia.formatTime(settings.date_format)
    date_label.visible = true
  else
    date_label.visible = false
  end
end

noctalia.createTimer(30000, function()
  update()
end)

update()
root:append(time_label)
root:append(date_label)

return root
