--!nonstrict

local iio_tool = noctalia.getConfig("iio")
local locked = false

-- Detect initial state by checking whether the IIO tool is running
local function refresh_state()
    noctalia.runAsync("pgrep -fx "..iio_tool, function(result)
        local pid = noctalia.string.trim(result.stdout)
        if pid ~= "" then
            noctalia.state.set("iio-state",false)
        else
            noctalia.state.set("iio-state",true)
        end
    end)
end

refresh_state()

local function kill_iio()
    noctalia.runAsync("pkill -x "..iio_tool)
end

local function start_iio()
    noctalia.runAsync(iio_tool)
end

local function apply_lock_state()
    if locked then
        kill_iio()
    else
        start_iio()
    end
end

noctalia.state.watch("iio-state", function (value)
    locked = value
    apply_lock_state()
end)
