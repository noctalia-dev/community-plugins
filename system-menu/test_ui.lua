-- Run with `lua test_ui.lua` from this directory; no shell instance is needed.
local function environment()
    local state = { renders = 0, launches = {}, copied = nil }
    local env = setmetatable({}, { __index = _G })
    env.ui = setmetatable({}, { __index = function(_, kind)
        return function(props, children) return { kind = kind, props = props, children = children or {} } end
    end })
    env.panel = {
        render = function(tree) state.tree = tree; state.renders = state.renders + 1 end,
        close = function() state.closed = true end,
    }
    env.noctalia = {
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
assert(menuState.launches[2].argv[#menuState.launches[2].argv] == "/test/plugin/packages/app.py")
menu.openTerminal()
assert(menuState.launches[3].argv[1] == "kitty")
menuState.closed = false
menu.openAbout()
assert(menuState.closed, "The transient menu must close before opening persistent About")
assert(menuState.toggled == "ajsem1337/system-menu:about")

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
print("PASS: menu actions, about rendering, copy, details, error recovery and stale callbacks")
