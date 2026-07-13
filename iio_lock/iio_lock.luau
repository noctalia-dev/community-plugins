local label = barWidget.getConfig("label")
local glyph = barWidget.getConfig("unlocked")
local glyph_unlocked = barWidget.getConfig("unlocked")
local glyph_locked = barWidget.getConfig("locked")
local iio_tool = barWidget.getConfig("iio")

local function start_set_state()
    noctalia.runAsync("pgrep -fx "..iio_tool, function(result)
        local pid = noctalia.string.trim(result.stdout)

        if pid ~= "" then
            locked = false
            noctalia.state.set("iio-state",false)
            glyph = glyph_unlocked
        else
            locked = true
            glyph = glyph_locked
            noctalia.state.set("iio-state",true)
        end

        return locked
    end)
end

local locked = start_set_state()

local function kill_iio()
    noctalia.runAsync("pkill -x "..iio_tool)
end

local function start_iio()
    noctalia.runAsync(iio_tool.." &")
end


local function render()
  barWidget.setGlyph(glyph)
end

local function change_lock_state()
    if locked then
        glyph = glyph_locked
        kill_iio()
    else
        glyph = glyph_unlocked
        start_iio()
    end
end

function onClick()
    locked = not locked
    noctalia.state.set("iio-state",locked)
    render()
end

noctalia.state.watch("iio-state", function (value)
    locked = value
    change_lock_state()
    render()
end)


function onRightClick()
     noctalia.togglePanel("my_plugins/iio_lock:panel")
end