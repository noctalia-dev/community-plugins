--!nonstrict
-- Oh My Pi (omp) Launcher Button for Noctalia Bar
-- Vector Pi glyph with dynamic pulse dot and click-to-toggle dropdown panel (hover tooltip disabled).

local dir = noctalia.pluginDir()
local SCRIPT_PATH = dir .. "/status.py"
local LAUNCH_PATH = dir .. "/omp-launch"
local LOGO_PATH   = dir .. "/omp-logo.svg"

local function render(data)
  local isRunning = data and data.running == true
  local pulse = data and data.pulse or "idle"
  local pulseColor = data and data.pulse_color or "#38BDF8"

  local children = {
    ui.image({ path = LOGO_PATH, width = 16, height = 16, fit = "contain" }),
    ui.label({ text = "omp", fontSize = 11, color = "#FFFFFF", fontWeight = "bold" }),
  }

  -- Visual Effect Dot:
  -- Sky Blue (#38BDF8) when thinking / running tools
  -- Clean White (#FFFFFF) when waiting for user prompt / input
  if isRunning then
    table.insert(children, ui.box({
      width = 5,
      height = 5,
      radius = 3,
      fill = pulseColor,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(nil)
end

local function refresh()
  noctalia.runAsync("python3 '" .. SCRIPT_PATH .. "'", function(r)
    if not r or r.exitCode ~= 0 or not r.stdout or r.stdout == "" then
      render(nil)
      return
    end

    local ok, data = pcall(function()
      return noctalia.json.decode(r.stdout)
    end)

    if ok and type(data) == "table" then
      noctalia.state.set("omp_launcher", data)
      render(data)
    else
      render(nil)
    end
  end)
end

-- Initial setup
render(nil)
noctalia.setUpdateInterval(1200) -- Refresh status every 1.2s for instant pulse responsiveness
refresh()

function update()
  refresh()
end

function onClick()
  noctalia.togglePanel("emiliovenegas/omp-launcher:panel")
  refresh()
end

function onMiddleClick()
  noctalia.runAsync("'" .. LAUNCH_PATH .. "' --continue")
  refresh()
end

function onRightClick()
  noctalia.runAsync("'" .. LAUNCH_PATH .. "' --home")
  refresh()
end
