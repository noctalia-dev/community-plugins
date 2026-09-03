function onClick()
	noctalia.runAsync("noctalia msg wallpaper-next")
	noctalia.notify("Wallpaper Switch", "Wallpaper switched")
end

shortcut.setLabel("Next Wallpaper")
shortcut.setIcon("image")
