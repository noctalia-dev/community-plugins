local widgetPath = "widget.luau"

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function runCase(scope, names, connector)
  local rendered, tooltip
  local snapshot = {
    status = "ok",
    message = "",
    outputs = {
      { name = "DP-1", width = 1920, height = 1080, x = 0, y = 0, focused = false },
      { name = "HDMI-A-1", width = 2560, height = 1440, x = 1920, y = 0, focused = true },
      { name = "eDP-1", width = 1920, height = 1080, x = 4480, y = 0, focused = false },
    },
    workspaces = {},
    windows = {},
  }

  noctalia = {
    getConfig = function(key)
      if key == "output_scope" then return scope end
      if key == "output_names" then return names end
      return nil
    end,
    state = {
      get = function(key)
        if key == "workspace_preview_snapshot" then return snapshot end
        return nil
      end,
      set = function() end,
      watch = function() end,
    },
    setUpdateInterval = function() end,
    runAsync = function() return true end,
    nowMs = function() return 0 end,
    removeFile = function() end,
  }
  ui = setmetatable({}, {
    __index = function(_, kind)
      return function(props, children)
        return { kind = kind, props = props or {}, children = children or {} }
      end
    end,
  })
  barWidget = {
    outputName = connector and function() return connector end or nil,
    isVertical = function() return false end,
    render = function(tree) rendered = tree end,
    setTooltip = function(value) tooltip = value end,
  }

  assert(loadfile(widgetPath))()
  return rendered, tooltip
end

local all = runCase("all", "", "DP-1")
assertEqual(#all.children, 3, "all outputs")
assertEqual(all.children[1].props.key, "output-DP-1", "physical order is preserved")

local current = runCase("current", "", "HDMI-A-1")
assertEqual(#current.children, 1, "current output")
assertEqual(current.children[1].props.key, "output-HDMI-A-1", "bar connector is selected")

local fallback = runCase("current", "", nil)
assertEqual(#fallback.children, 1, "current output fallback")
assertEqual(fallback.children[1].props.key, "output-HDMI-A-1", "focused output is fallback")

local custom = runCase("custom", " eDP-1; DP-1\nmissing ", "HDMI-A-1")
assertEqual(#custom.children, 2, "manual output selection")
assertEqual(custom.children[1].props.key, "output-DP-1", "manual selection keeps physical order")
assertEqual(custom.children[2].props.key, "output-eDP-1", "manual selection supports delimiters")

local empty, emptyTooltip = runCase("custom", "missing", "DP-1")
assertEqual(#empty.children, 1, "empty selection renders status glyph")
assertEqual(empty.children[1].kind, "glyph", "empty selection does not silently show all outputs")
assertEqual(emptyTooltip, "No outputs match this widget's output scope", "empty selection tooltip")

print("output scope tests passed")
