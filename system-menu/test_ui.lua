-- Run with `lua test_ui.lua` from this directory; no shell instance is needed.
local function environment()
    local state = { renders = 0, launches = {}, copied = nil, files = {}, icons = {}, iconLookups = {},
        config = { terminal = "kitty", terminal_args = {}, terminal_exec_args = { "-e" }, aur_helper = "paru" } }
    local env = setmetatable({}, { __index = _G })
    env.ui = setmetatable({}, { __index = function(_, kind)
        return function(props, children) return { kind = kind, props = props, children = children or {} } end
    end })
    env.panel = {
        render = function(tree) state.tree = tree; state.renders = state.renders + 1 end,
        close = function() state.closed = true end,
    }
    env.noctalia = {
        readFile = function(path) return state.files[path] end,
        fileExists = function(path) return state.files[path] ~= nil end,
        appIconPath = function(name, size)
            table.insert(state.iconLookups, { name = name, size = size })
            return state.icons[name]
        end,
        getConfig = function(key) return state.config[key] end,
        expandPath = function(path) return path:gsub("~", "/home/test") end,
        pluginDir = function() return "/test/plugin" end,
        togglePanel = function(id) state.toggled = id end,
        notifyError = function() state.error = true end,
        log = function() end,
        runAsync = function(argv, callback)
            table.insert(state.launches, { argv = argv, callback = callback })
            return not state.reject
        end,
        copyToClipboard = function(text, mime) state.copied = text; assert(mime == "text/plain"); return true end,
        json = { decode = function() return state.profile end },
    }
    local modules = {}
    env.require = function(path)
        assert(path == "./distro_icon.luau")
        if not modules[path] then modules[path] = assert(loadfile(path, "t", env))() end
        return modules[path]
    end
    return env, state
end

local function contains(tree, text)
    if tree.props.text == text then return true end
    for _, child in ipairs(tree.children) do if contains(child, text) then return true end end
    return false
end

local function checkColumns(tree)
    local checked = 0
    if tree.kind == "row" and tree.props.paddingV == 8 then
        local label, value = tree.children[1], tree.children[2]
        assert(label.kind == "column" and label.props.width == 136 and label.props.minWidth == 136)
        assert(value.kind == "column" and value.props.width == 0 and value.props.flexGrow == 1)
        checked = 1
    end
    for _, child in ipairs(tree.children) do checked = checked + checkColumns(child) end
    return checked
end

local function hasImage(tree, path, size)
    if tree.kind == "image" and tree.props.path == path and tree.props.width == size then return true end
    for _, child in ipairs(tree.children) do if hasImage(child, path, size) then return true end end
    return false
end

local function distroEnvironment(release, files, icons)
    local env, state = environment()
    state.files = files or {}
    state.files["/etc/os-release"] = release
    state.icons = icons or {}
    return env, state
end

local iconCases = {
    { release = 'ID=cachyos\nID_LIKE=arch\nLOGO="cachyos"\n',
        files = { ["/usr/share/icons/cachyos.svg"] = "svg", ["/usr/share/pixmaps/archlinux-logo.svg"] = "svg" },
        expected = "/usr/share/icons/cachyos.svg" },
    { release = 'ID=arch\nLOGO=archlinux-logo\n', files = { ["/usr/share/pixmaps/archlinux-logo.svg"] = "svg" },
        expected = "/usr/share/pixmaps/archlinux-logo.svg" },
    { release = "ID='artix'\nID_LIKE='arch'\n", files = { ["/usr/share/icons/artixlinux-logo.svg"] = "svg" },
        expected = "/usr/share/icons/artixlinux-logo.svg" },
    { release = 'ID=example\nLOGO=example-logo\n', files = { ["/theme/example.svg"] = "svg", ["/usr/share/icons/example-logo.svg"] = "svg" },
        icons = { ["example-logo"] = "/theme/example.svg" }, expected = "/theme/example.svg" },
    { release = 'ID=derivative\nID_LIKE="artix arch"\n', files = { ["/usr/share/pixmaps/artix-logo.png"] = "png" },
        expected = "/usr/share/pixmaps/artix-logo.png" },
    { files = { ["/usr/lib/os-release"] = 'ID=arch\nLOGO=archlinux-logo\n', ["/usr/share/icons/archlinux-logo.svg"] = "svg" },
        expected = "/usr/share/icons/archlinux-logo.svg" },
    { release = 'ID=unknown\n', files = { ["/theme/distributor.svg"] = "svg" },
        icons = { ["distributor-logo"] = "/theme/distributor.svg" }, expected = "/theme/distributor.svg" },
    { release = 'ID=arch\n', files = { ["/usr/share/pixmaps/archlinux-logo.svg"] = "svg" },
        icons = { arch = "/missing/icon.svg" }, expected = "/usr/share/pixmaps/archlinux-logo.svg" },
    { release = 'ID=unknown\nLOGO="../../etc/passwd"\nID_LIKE="../../arch"\n' },
    { release = 'ID=$(touch /tmp/never)\nLOGO="unterminated\n' },
    { release = "", files = { ["/usr/lib/os-release"] = 'ID=arch\n', ["/usr/share/pixmaps/archlinux-logo.svg"] = "svg" } },
    {},
}
for _, example in ipairs(iconCases) do
    local env, state = distroEnvironment(example.release, example.files, example.icons)
    assert(env.require("./distro_icon.luau").path(24) == example.expected)
    for _, lookup in ipairs(state.iconLookups) do
        assert(lookup.size == 24)
        assert(not lookup.name:find("/", 1, true) and not lookup.name:find("$", 1, true))
    end
    assert(#state.launches == 0, "Distro detection must never launch subprocesses")
end

local menu, menuState = environment()
assert(loadfile("menu.luau", "t", menu))()
menu.onOpen()
for _, text in ipairs({ "Packages", "Task Manager", "Terminal", "About This System" }) do
    assert(contains(menuState.tree, text), text)
end
menu.openTaskManager()
assert(menuState.closed)
assert(menuState.launches[1].argv[1] == "kitty")
assert(menuState.launches[1].argv[#menuState.launches[1].argv] == "btop")
menu.openPackages()
assert(menuState.launches[2].argv[1] == "kitty")
assert(menuState.launches[2].argv[5] == "/test/plugin/packages/app.py")
assert(menuState.launches[2].argv[6] == "--aur-helper")
assert(menuState.launches[2].argv[7] == "paru")
menu.openTerminal()
assert(menuState.launches[3].argv[1] == "kitty")
menuState.closed = false
menu.openAbout()
assert(menuState.closed, "The transient menu must close before opening persistent About")
assert(menuState.toggled == "ajsem1337/system-menu:about")

local function equalArgs(actual, expected)
    assert(#actual == #expected)
    for index, value in ipairs(expected) do assert(actual[index] == value, tostring(index)) end
end

for _, example in ipairs({
    { terminal = "foot", exec = { "-e" } },
    { terminal = "alacritty", exec = { "-e" } },
    { terminal = "gnome-terminal", exec = { "--" } },
    { terminal = "/opt/my terminal/bin/terminal", exec = {} },
}) do
    local custom, customState = environment()
    customState.config = { terminal = example.terminal, terminal_args = { "--custom", "value with spaces;$(literal)" },
        terminal_exec_args = example.exec, aur_helper = "/opt/custom helper/yay" }
    assert(loadfile("menu.luau", "t", custom))()
    custom.openTerminal()
    equalArgs(customState.launches[1].argv, { example.terminal, "--custom", "value with spaces;$(literal)" })
    local expected = { example.terminal, "--custom", "value with spaces;$(literal)" }
    for _, arg in ipairs(example.exec) do table.insert(expected, arg) end
    table.insert(expected, "btop")
    custom.openTaskManager()
    equalArgs(customState.launches[2].argv, expected)
    table.remove(expected)
    for _, arg in ipairs({ "python3", "-I", "/test/plugin/packages/app.py", "--aur-helper", "/opt/custom helper/yay" }) do
        table.insert(expected, arg)
    end
    custom.openPackages()
    equalArgs(customState.launches[3].argv, expected)
end

for _, key in ipairs({ "terminal", "aur_helper" }) do
    for _, value in ipairs({ "", "   ", "bad\ncommand", "--invalid" }) do
        local invalid, invalidState = environment()
        invalidState.config[key] = value
        assert(loadfile("menu.luau", "t", invalid))()
        invalid.openPackages()
        assert(invalidState.error and not invalidState.closed and #invalidState.launches == 0)
    end
end
local rejected, rejectedState = environment()
rejectedState.reject = true
assert(loadfile("menu.luau", "t", rejected))()
rejected.openTerminal()
assert(rejectedState.error)

local widget, widgetState = environment()
widget.noctalia.setUpdateInterval = function(interval) assert(interval == 3600000) end
widget.barWidget = {
    setGlyph = function(glyph) assert(glyph == "device-desktop") end,
    setText = function(text) assert(text == "") end,
    setTooltip = function(text) assert(text == "System Menu") end,
}
assert(loadfile("widget.luau", "t", widget))()
widget.update()
widget.onClick()
assert(widgetState.toggled == "ajsem1337/system-menu:menu")

local branded, brandedState = distroEnvironment('ID=cachyos\nLOGO=cachyos\n', { ["/usr/share/icons/cachyos.svg"] = "svg" })
branded.noctalia.setUpdateInterval = function() end
branded.barWidget = {
    setGlyph = function() brandedState.image = nil end,
    setImage = function(path, watch, width, height)
        assert(watch and width == 24 and height == 24)
        brandedState.image = path
    end,
    setText = function() end,
    setTooltip = function() end,
}
assert(loadfile("widget.luau", "t", branded))()
branded.update()
assert(brandedState.image == "/usr/share/icons/cachyos.svg")
assert(loadfile("menu.luau", "t", branded))()
branded.onOpen()
assert(hasImage(brandedState.tree, "/usr/share/icons/cachyos.svg", 24))
brandedState.profile = { hostname = "test", subtitle = "CachyOS", logo = "fallback.svg", sections = {}, details = { rows = {} }, report = "test", warnings = {} }
assert(loadfile("about.luau", "t", branded))()
branded.onOpen()
brandedState.launches[1].callback({ exitCode = 0, stdout = "profile" })
assert(hasImage(brandedState.tree, "/usr/share/icons/cachyos.svg", 64))
brandedState.files["/usr/share/icons/cachyos.svg"] = nil
branded.update()
assert(brandedState.image == nil, "An unavailable logo must reset the bar to its fallback glyph")

local about, state = environment()
state.profile = {
    hostname = "desktop", subtitle = "Linux", logo = "logo.svg", warnings = {}, report = "System report",
    sections = {{ title = "Hardware", icon = "cpu", rows = {
        { label = "Motherboard", value = "A very long motherboard model name", detail = "Vendor" },
        { label = "CPU", value = "Test CPU", detail = "8 cores" },
    } }},
    details = { title = "Details", icon = "settings", rows = {{ label = "Firmware", value = "UEFI" }} },
}
assert(loadfile("about.luau", "t", about))()
about.onOpen()
assert(#state.launches == 1)
state.launches[1].callback({ exitCode = 0, stdout = "profile" })
assert(contains(state.tree, "Test CPU"))
assert(hasImage(state.tree, "logo.svg", 64), "About must retain its bundled fallback logo")
assert(checkColumns(state.tree) == 2, "Every information row must use the same two columns")
assert(not contains(state.tree, "UEFI"))
about.toggleDetails()
assert(contains(state.tree, "UEFI"))
assert(checkColumns(state.tree) == 3)
about.copyInformation()
assert(state.copied == "System report")
assert(contains(state.tree, "Copied"))
about.refresh()
local stale = state.launches[2].callback
about.onClose()
local previousRenders = state.renders
stale({ exitCode = 0, stdout = "profile" })
assert(state.renders == previousRenders, "A late result rendered a closed panel")
about.onOpen()
state.launches[3].callback({ exitCode = 1, stderr = "test failure" })
assert(contains(state.tree, "Could not collect system information. Please try again."))
assert(contains(state.tree, "Refresh"))
state.reject = true
about.refresh()
assert(contains(state.tree, "Could not start collecting system information."))
print("PASS: distro icons and fallbacks, configurable terminals/helpers, menu actions, about rendering, copy, details, error recovery and stale callbacks")
