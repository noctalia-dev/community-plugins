--!nonstrict

local function launch(argv)
    panel.close()
    if not noctalia.runAsync(argv) then
        noctalia.notifyError("System Menu", "Could not start the application. Check its dependencies.")
    end
end

function openPackages()
    launch({ "kitty", "--class", "system-menu-packages", "--title", "Packages",
        "--override", "initial_window_width=148c", "--override", "initial_window_height=44c",
        "--override", "remember_window_size=no", "--override", "background_opacity=1",
        "--override", "window_padding_width=8", "python3", "-I", noctalia.pluginDir() .. "/packages/app.py" })
end

function openTaskManager()
    launch({ "kitty", "--class", "system-menu-btop", "--title", "Task Manager", "btop" })
end

function openTerminal()
    launch({ "kitty", "--detach" })
end

function openAbout()
    panel.close()
    noctalia.togglePanel("ajsem1337/system-menu:about")
end

function onOpen()
    panel.render(ui.column({ gap = 6 }, {
        ui.row({ gap = 10, align = "center", paddingH = 10, paddingV = 8 }, {
            ui.glyph({ name = "device-desktop", size = 24 }),
            ui.label({ text = "System", fontWeight = "bold", fontSize = 17 }),
        }),
        ui.separator({ spacing = 4 }),
        ui.button({ text = "Packages", glyph = "package", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Find, install, uninstall and downgrade packages", onClick = "openPackages" }),
        ui.button({ text = "Task Manager", glyph = "activity", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "btop — resource and process management", onClick = "openTaskManager" }),
        ui.button({ text = "Terminal", glyph = "terminal", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Open Kitty", onClick = "openTerminal" }),
        ui.separator({ spacing = 4 }),
        ui.button({ text = "About This System", glyph = "info-circle", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Hardware and software information", onClick = "openAbout" }),
    }))
end
