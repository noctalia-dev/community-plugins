-- Behaviour tests for the bar widget, driven through a mock of the Noctalia
-- runtime and the `barWidget.*` namespace.
--
--   lua5.4 tests/test-widget.lua

local function scriptDir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    return source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
  end
  return "."
end

-- The tests live in `tests/`, so the plugin root is the directory above them.
local function pluginRoot()
  local dir = scriptDir()
  local parent = dir:match("^(.*)[/\\]tests$")
  if parent and parent ~= "" then
    return parent
  end
  if dir == "tests" or parent == "" then
    return "."
  end
  return dir
end

local DIR = pluginRoot()
local loaded = {}
local function pluginRequire(path)
  local relative = path:gsub("^%./", "")
  if loaded[relative] == nil then
    loaded[relative] = assert(loadfile(DIR .. "/" .. relative))()
  end
  return loaded[relative]
end

local FAILED = 0
local PASSED = 0
local function check(name, expected, actual)
  if expected == actual then
    PASSED = PASSED + 1
    print(string.format("  ok    %-58s %s", name, tostring(actual)))
  else
    FAILED = FAILED + 1
    print(string.format("  FAIL  %-58s expected=%s actual=%s", name, tostring(expected), tostring(actual)))
  end
end

local function section(name)
  print("\n== " .. name)
end

local PT = {
  TODAY = 4,
  TODAY_DATE = "2026-02-14",
  WINDOW_TOTAL = 812,
  CURRENT_STREAK = 6,
  BEST_STREAK = 31,
  LAST_WPM = 101,
  LAST_ACC = 96,
  FETCHED_AT = 1771027200,
}

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deepCopy(item)
  end
  return copy
end

local function sampleData()
  return {
    rows = { "", "", "", "", "", "", "" },
    details = { "", "", "", "", "", "", "" },
    columns = 1,
    thresholds = { 1, 2, 3 },
    windowTotal = PT.WINDOW_TOTAL,
    firstDate = "2025-02-08",
    lastDate = "2026-02-14",
    today = PT.TODAY,
    todayDate = PT.TODAY_DATE,
    currentStreak = PT.CURRENT_STREAK,
    bestStreak = PT.BEST_STREAK,
    lastResultTimestamp = 1771027000,
    completedTests = 900,
    startedTests = 950,
    timeTyping = 7200,
    lastWpm = PT.LAST_WPM,
    lastAcc = PT.LAST_ACC,
    lastMode = "time",
    lastMode2 = "60",
    lastTestAt = 1771027000,
    fetchedAt = PT.FETCHED_AT,
  }
end

local function newMock(config, data, status, stale)
  local mock = {
    config = config or {},
    state = {},
    watchers = {},
    glyph = nil,
    text = nil,
    tooltip = nil,
    visible = nil,
    panelToggled = nil,
    settingsOpened = false,
    tr_keys = {},
  }

  if data ~= nil then
    mock.state.data = deepCopy(data)
  end
  mock.state.status = status or "ready"
  mock.state.stale = stale == true

  local noctalia = {}
  noctalia.state = {}
  noctalia.getConfig = function(key)
    return mock.config[key]
  end
  noctalia.tr = function(key, subst)
    table.insert(mock.tr_keys, key)
    if subst ~= nil then
      local names = {}
      for name in pairs(subst) do
        table.insert(names, name)
      end
      table.sort(names)
      return key .. "[" .. table.concat(names, ",") .. "]"
    end
    return key
  end
  noctalia.state.get = function(key)
    return deepCopy(mock.state[key])
  end
  noctalia.state.set = function(key, value)
    mock.state[key] = deepCopy(value)
    local watchers = mock.watchers[key]
    if watchers ~= nil then
      for _, watcher in ipairs(watchers) do
        watcher(deepCopy(value))
      end
    end
  end
  noctalia.state.watch = function(key, callback)
    mock.watchers[key] = mock.watchers[key] or {}
    table.insert(mock.watchers[key], callback)
  end
  noctalia.togglePanel = function(id)
    mock.panelToggled = id
  end
  noctalia.openSettings = function()
    mock.settingsOpened = true
  end
  noctalia.nowMs = function()
    return 1700000000000
  end
  noctalia.formatTime = function(pattern, timestamp)
    return pattern .. "@" .. tostring(timestamp)
  end
  -- Mirrors the manifest default for `[shell].time_format`.
  noctalia.timeFormat = function()
    return "%H:%M"
  end
  mock.noctalia = noctalia

  mock.barWidget = {
    setGlyph = function(name)
      mock.glyph = name
    end,
    setText = function(text)
      mock.text = text
    end,
    setTooltip = function(content)
      mock.tooltip = content
    end,
    setVisible = function(visible)
      mock.visible = visible
    end,
  }

  return mock
end

local function loadWidget(mock)
  local env = setmetatable({
    noctalia = mock.noctalia,
    barWidget = mock.barWidget,
    require = pluginRequire,
  }, { __index = _G })
  assert(loadfile(DIR .. "/widget.luau", "t", env))()
  return env
end

section("icon and value, no data yet")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "today" }, nil, "loading")
  loadWidget(mock)
  check("glyph", "keyboard", mock.glyph)
  check("placeholder text", "—", mock.text)
  check("visible", true, mock.visible)
  check("tooltip explains the state", "status.loading", mock.tooltip)
end

section("today's tests")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "today" }, sampleData())
  loadWidget(mock)
  check("text", tostring(PT.TODAY), mock.text)
  check("tooltip is translated", "widget.tooltip[accuracy,freshness,refresh,streak,today,total,wpm]", mock.tooltip)
end

section("current streak")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "current_streak" }, sampleData())
  loadWidget(mock)
  check("text", tostring(PT.CURRENT_STREAK), mock.text)
end

section("yearly total")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "year_total" }, sampleData())
  loadWidget(mock)
  check("text", tostring(PT.WINDOW_TOTAL), mock.text)
end

section("last test wpm")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "last_wpm" }, sampleData())
  loadWidget(mock)
  check("text", tostring(PT.LAST_WPM), mock.text)
end

section("icon only")
do
  local mock = newMock({ display_mode = "icon_only", display_metric = "today" }, sampleData())
  loadWidget(mock)
  check("no text", "", mock.text)
end

section("unknown metric falls back to today")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "pace" }, sampleData())
  loadWidget(mock)
  check("text", tostring(PT.TODAY), mock.text)
end

section("missing key: click opens the settings")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "today" }, nil, "no_key")
  local widget = loadWidget(mock)
  check("tooltip names the key", "status.no_key", mock.tooltip)
  widget.onClick()
  check("settings opened", true, mock.settingsOpened)
  check("panel not toggled", nil, mock.panelToggled)
end

section("invalid or disabled key: the click opens the panel")
do
  local invalid = newMock({ display_mode = "icon_and_value", display_metric = "today" }, sampleData(), "invalid_key")
  local invalidWidget = loadWidget(invalid)
  invalidWidget.onClick()
  check("invalid key opens the panel", "faminec/monkeytype-activity:calendar", invalid.panelToggled)
  check("invalid key keeps settings closed", false, invalid.settingsOpened)

  local disabled = newMock({ display_mode = "icon_and_value", display_metric = "today" }, nil, "inactive_key")
  local disabledWidget = loadWidget(disabled)
  check("disabled key names the toggle", "status.inactive_key", disabled.tooltip)
  disabledWidget.onClick()
  check("disabled key opens the panel", "faminec/monkeytype-activity:calendar", disabled.panelToggled)
end

section("with a key: click toggles the calendar")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "today" }, sampleData())
  local widget = loadWidget(mock)
  widget.onClick()
  check("panel id", "faminec/monkeytype-activity:calendar", mock.panelToggled)
  check("settings untouched", false, mock.settingsOpened)
end

section("right click asks for a refresh")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "today" }, sampleData())
  local widget = loadWidget(mock)
  widget.onRightClick()
  check("refresh request published", 1700000000000, mock.state.refresh_request)
end

section("watching the shared state")
do
  local mock = newMock({ display_mode = "icon_and_value", display_metric = "today" }, nil, "no_key")
  loadWidget(mock)
  check("starts empty", "—", mock.text)
  mock.noctalia.state.set("data", sampleData())
  check("data updates the text", tostring(PT.TODAY), mock.text)
  local before = #mock.tr_keys
  mock.noctalia.state.set("stale", true)
  local sawCached = false
  for index = before + 1, #mock.tr_keys do
    if mock.tr_keys[index] == "widget.cached" then
      sawCached = true
    end
  end
  check("stale data is named in the tooltip", true, sawCached)
end

print(string.format("\n%d passed, %d failed", PASSED, FAILED))
os.exit(FAILED == 0 and 0 or 1)
