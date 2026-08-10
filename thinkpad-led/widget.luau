--!nonstrict
-- ThinkPad lid logo LED — bar widget
-- Controls /sys/class/leds/tpacpi::lid_logo_dot/brightness

local LED_PATH = "/sys/class/leds/tpacpi::lid_logo_dot/brightness"[cite: 1]

-- State can be "on", "off", or "error"
local state = "error"

local function statusColor()
  if state == "on" then
    return "error"
  elseif state == "off" then
    return "outline"
  else
    return "subtext"
  end
end

local function render()
  barWidget.render(ui.box({
    width = 10,
    height = 10,
    radius = 5,
    fill = statusColor(),
    border = "outline",
    borderWidth = 1,
  }))

  if state == "on" then
    barWidget.setTooltip("ThinkPad LED: ON (Left click: turn off)")
  elseif state == "off" then
    barWidget.setTooltip("ThinkPad LED: OFF (Left click: turn on)")
  else
    barWidget.setTooltip("ThinkPad LED: Unavailable or write error")
  end
end

local function syncHardwareState(callback)
  noctalia.runAsync(`cat {LED_PATH}`, function(exitCode, stdout)
    if exitCode == 0 and stdout then
      local val = tonumber(stdout:match("%d+"))
      if val and val > 0 then
        state = "on"
      else
        state = "off"
      end
    else
      state = "error"
    end
    render()
    if callback then
      callback(state ~= "error")
    end
  end)
end

function update()
  syncHardwareState()
end

function onClick()
  syncHardwareState(function(success)
    if not success then
      return
    end

    local targetVal = (state == "on") and "0" or "255"
    noctalia.runAsync(`sh -c "echo {targetVal} > {LED_PATH}"`, function(exitCode)
      if exitCode == 0 then
        state = (targetVal == "255") and "on" or "off"
      else
        state = "error"
      end
      render()
    end)
  end)
end