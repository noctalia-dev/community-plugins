--!nonstrict
-- Oh My Pi (omp) Launcher Button for Noctalia Bar
-- Vector Pi glyph, white by default and orange while a session awaits input.

local dir = noctalia.pluginDir()
local SCRIPT_PATH = dir .. "/status.py"
local LAUNCH_PATH = dir .. "/omp-launch"
local ICON_PATH       = dir .. "/omp-logo.svg"
local ICON_ALERT_PATH = dir .. "/omp-logo-alert.svg"

local function render(data)
  local needsInput = type(data) == "table" and data.needs_input == true
  local showLabel = noctalia.getConfig("show_label") ~= false

  local children = {
    ui.image({
      path = needsInput and ICON_ALERT_PATH or ICON_PATH,
      width = 16,
      height = 16,
      fit = "contain",
    }),
  }

  if showLabel then
    table.insert(children, ui.label({ text = "omp", fontSize = 11, color = "#FFFFFF", fontWeight = "bold" }))
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
