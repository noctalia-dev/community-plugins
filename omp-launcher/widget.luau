--!nonstrict
-- Oh My Pi (omp) Launcher Button for Noctalia Bar
-- Native vector UI rendering with Pi glyph, active process detection, and recent project context.

local dir = noctalia.pluginDir()
local SCRIPT_PATH = dir .. "/status.py"
local LAUNCH_PATH = dir .. "/omp-launch"
local LOGO_PATH   = dir .. "/omp-logo.svg"

local function render(data)
  local isRunning = data and data.running == true
  local tooltip = data and data.tooltip or "Oh My Pi (omp) — left: pick project · middle: resume · right: home"

  local children = {
    ui.image({ path = LOGO_PATH, width = 16, height = 16, fit = "contain" }),
    ui.label({ text = "omp", fontSize = 11, color = "#FFFFFF", fontWeight = "bold" }),
  }

  if isRunning then
    table.insert(children, ui.box({
      width = 5,
      height = 5,
      radius = 3,
      fill = "#38BDF8", -- Sky blue active session dot matching logo gradient
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(tooltip)
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
      render(data)
    else
      render(nil)
    end
  end)
end

-- Initial setup
render(nil)
noctalia.setUpdateInterval(10000) -- Refresh status every 10s
refresh()

function update()
  refresh()
end

function onClick()
  noctalia.runAsync("'" .. LAUNCH_PATH .. "'")
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
