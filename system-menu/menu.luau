--!nonstrict

local distroIcon = require("./distro_icon.luau")
local launcher = require("./launcher.luau")

function openPackages()
    launcher.open("Packages", noctalia.getConfig("packages_mode"),
        noctalia.getConfig("packages_command"), noctalia.getConfig("packages_args"))
end

function openTaskManager()
    launcher.open("Task Manager", noctalia.getConfig("monitor_mode"),
        noctalia.getConfig("monitor_command"), noctalia.getConfig("monitor_args"))
end

function openTerminal()
    launcher.openTerminal()
end

function openAbout()
    panel.close()
    noctalia.togglePanel("ajsem1337/system-menu:about")
end

function onOpen()
    local icon = distroIcon.path(24)
    panel.render(ui.column({ gap = 6 }, {
        ui.row({ gap = 10, align = "center", paddingH = 10, paddingV = 8 }, {
            icon and ui.image({ path = icon, width = 24, height = 24 })
                or ui.glyph({ name = "device-desktop", size = 24 }),
            ui.label({ text = "System", fontWeight = "bold", fontSize = 17 }),
        }),
        ui.separator({ spacing = 4 }),
        ui.button({ text = "Packages", glyph = "package", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Open your chosen package manager", onClick = "openPackages" }),
        ui.button({ text = "Task Manager", glyph = "activity", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Open your chosen system monitor", onClick = "openTaskManager" }),
        ui.button({ text = "Terminal", glyph = "terminal", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Open your configured terminal", onClick = "openTerminal" }),
        ui.separator({ spacing = 4 }),
        ui.button({ text = "About This System", glyph = "info-circle", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Hardware and software information", onClick = "openAbout" }),
    }))
end
