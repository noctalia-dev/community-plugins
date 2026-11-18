function update()
	barWidget.setGlyph("image")
end

function onClick()
	noctalia.runAsync("noctalia msg wallpaper-next")
	noctalia.notify("Wallpaper Switch", "Wallpaper switched")
end
