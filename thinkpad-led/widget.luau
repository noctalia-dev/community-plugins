--!nonstrict
-- ThinkPad lid logo LED — bar widget
-- A red dot in the bar that directly controls the /sys/class/leds/tpacpi::lid_logo_dot LED.
--   Left click : toggle on / off

local LED_PATH = "/sys/class/leds/tpacpi::lid_logo_dot/brightness"

local ledOn = false

local function statusColor()
  if ledOn then
    return "error"
  else
    return "outline"
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

  if ledOn then
    barWidget.setTooltip("ThinkPad LED: ON (Left click: turn off)")
  else
    barWidget.setTooltip("ThinkPad LED: OFF (Left click: turn on)")
  end
end

function update()
  render()
end

function onClick()
  ledOn = not ledOn
  local val = ledOn and "255" or "0"
  noctalia.runAsync(`sh -c "echo {val} > {LED_PATH}"`)
  render()
end
