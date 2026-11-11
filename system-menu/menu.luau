--!nonstrict

local distroIcon = require("./distro_icon.luau")

local function launch(argv)
    panel.close()
    if not noctalia.runAsync(argv) then
        noctalia.notifyError("System Menu", "Could not start the application. Check its dependencies.")
    end
end

local function executable(key)
    local value = noctalia.getConfig(key)
    if type(value) ~= "string" then value = "" end
    value = value:match("^%s*(.-)%s*$")
    if value == "" or value:find("%c") or value:sub(1, 1) == "-" then
        noctalia.notifyError("System Menu", "Set a valid " .. key .. " executable in the plugin settings.")
        return nil
    end
    return value
end

local function launchTerminal(program)
    local terminal = executable("terminal")
    if not terminal then return end
    local argv = { terminal }
    for _, arg in ipairs(noctalia.getConfig("terminal_args") or {}) do table.insert(argv, arg) end
    if program then
        for _, arg in ipairs(noctalia.getConfig("terminal_exec_args") or {}) do table.insert(argv, arg) end
        for _, arg in ipairs(program) do table.insert(argv, arg) end
    end
    launch(argv)
end

function openPackages()
    local helper = executable("aur_helper")
    if not helper then return end
    launchTerminal({ "python3", "-I", noctalia.pluginDir() .. "/packages/app.py", "--aur-helper", helper })
end

function openTaskManager()
    launchTerminal({ "btop" })
end

function openTerminal()
    launchTerminal()
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
            controlSize = "lg", tooltip = "Find, install, uninstall and downgrade packages", onClick = "openPackages" }),
        ui.button({ text = "Task Manager", glyph = "activity", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "btop — resource and process management", onClick = "openTaskManager" }),
        ui.button({ text = "Terminal", glyph = "terminal", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Open your configured terminal", onClick = "openTerminal" }),
        ui.separator({ spacing = 4 }),
        ui.button({ text = "About This System", glyph = "info-circle", variant = "ghost", contentAlign = "start",
            controlSize = "lg", tooltip = "Hardware and software information", onClick = "openAbout" }),
    }))
end
