--!nonstrict
-- Noctalia state.watch registers future notifications; it does not replay state.
-- Verify UI entries opened after the service see the existing state immediately.
local uiPassed, uiFailed = 0, 0
local function uiTest(name, fn)
    local ok, err = pcall(fn)
    if ok then
        uiPassed = uiPassed + 1
        print("PASS " .. name)
    else
        uiFailed = uiFailed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function openEntry(source)
    local state = {
        wayvibes_playing = true, wayvibes_pack = "Cream", wayvibes_volume = 7,
        wayvibes_device = "USB Keyboard",
        wayvibes_packs = { { name = "Cream", folder = "cream", path = "/packs/cream" } },
        wayvibes_devices = { { name = "USB Keyboard", path = "/dev/input/event7" } },
    }
    local output = {}
    noctalia = {
        state = {
            get = function(key) return state[key] end,
            set = function(key, value) state[key] = value end,
            watch = function() end,
        },
        getConfig = function() return "keyboard" end,
        tr = function(key) return key end,
        setUpdateInterval = function() end,
    }
    ui = setmetatable({}, { __index = function(_, kind)
        return function(props, children) return { kind = kind, props = props, children = children or {} } end
    end })
    panel = { render = function(tree) output.tree = tree end }
    barWidget = {
        setGlyph = function(value) output.glyph = value end,
        setGlyphColor = function(value) output.color = value end,
        setTooltip = function(value) output.tooltip = value end,
    }
    assert(loadstring(source))()
    return output
end

local function findNode(node, key)
    if node.props.key == key then return node end
    for _, child in ipairs(node.children) do
        local found = findNode(child, key)
        if found then return found end
    end
end

uiTest("panel opened after service startup shows current packs, playback, and volume", function()
    local output = openEntry(PANEL_SOURCE)
    onOpen()
    assert(findNode(output.tree, "volume_slider").props.value == 7, "volume reset on first open")
    local play = findNode(output.tree, "play_cream")
    assert(play and play.props.glyph == "check", "current pack missing or not selected")
    findNode(output.tree, "tab_devices").props.onClick()
    assert(findNode(output.tree, "sel_1").props.text == "active", "selected keyboard missing on first open")
end)

uiTest("widget created during playback immediately shows the current status", function()
    local output = openEntry(WIDGET_SOURCE)
    assert(output.color == "primary", "widget shows playback as off")
    assert(output.tooltip[1].value == "Cream")
    assert(output.tooltip[2].value == "7/10")
end)

print(tostring(uiPassed) .. " UI tests passed, " .. tostring(uiFailed) .. " failed")
assert(uiFailed == 0, "UI regression tests failed")
