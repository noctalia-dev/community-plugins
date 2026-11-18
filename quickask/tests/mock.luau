local mock = {}
local function copy(value) return json.decode(json.encode(value)) end
local function resetMock()
  mock = {
    now = 1000000, tree = nil, renders = 0, ticks = false, closed = 0,
    commandExists = true, processStarted = true, lookups = {}, requests = {},
    clipboard = nil, clipboardOK = true, httpMode = "normal", maxActive = 0,
    settings = copy(settingDefaults), lookupArgs = {}, settingsOpened = 0,
  }
end
resetMock()
local noctalia = {
  tr = function(key, substitutions)
    local value = translations
    for segment in key:gmatch("[^.]+") do value = type(value) == "table" and value[segment] or nil end
    assert(type(value) == "string", "Missing English translation: " .. key)
    for name, replacement in pairs(substitutions or {}) do
      value = value:gsub("{" .. name .. "}", function() return tostring(replacement) end)
    end
    return value
  end,
  getConfig = function(key)
    assert(settingDefaults[key] ~= nil, "Undeclared config key")
    return mock.settings[key]
  end,
  openSettings = function() mock.settingsOpened = mock.settingsOpened + 1 end,
  nowMs = function() return mock.now end,
  commandExists = function(name) assert(name == "secret-tool"); return mock.commandExists end,
  json = json,
  runAsync = function(argv, callback)
    assert(type(argv) == "table", "Credentials must never use a shell")
    local equalPrefix = table.concat({argv[1], argv[2], argv[3], argv[4], argv[5]}, "|")
    assert(equalPrefix == "secret-tool|lookup|application|quickask|provider")
    assert(argv[6] == "opencode-go" or argv[6] == "openai-compatible")
    assert(#argv == (argv[6] == "opencode-go" and 6 or 8))
    if argv[6] == "openai-compatible" then assert(argv[7] == "endpoint") end
    table.insert(mock.lookupArgs, copy(argv))
    if not mock.processStarted then return false end
    table.insert(mock.lookups, callback)
    return true
  end,
  copyToClipboard = function(value, mime)
    assert(mime == "text/plain")
    if mock.clipboardOK then mock.clipboard = value end
    return mock.clipboardOK
  end,
  httpStream = function(request, onLine, onClose)
    if mock.httpMode == "throw" then error("synthetic native failure") end
    if mock.httpMode == "nil" then return nil end
    local record = { request = copy(request), onLine = onLine, onClose = onClose, stopped = 0, active = true }
    local handle = { stop = function() record.stopped = record.stopped + 1; record.active = false end }
    table.insert(mock.requests, record)
    local active = 0
    for _, r in ipairs(mock.requests) do if r.active then active = active + 1 end end
    mock.maxActive = math.max(mock.maxActive, active)
    if mock.httpMode == "syncError" then
      record.active = false
      onClose({ ok = true, status = 401 })
    end
    return handle
  end,
}
local panel = {
  render = function(tree) mock.tree = tree; mock.renders = mock.renders + 1 end,
  setNeedsFrameTick = function(enabled) mock.ticks = enabled end,
  close = function() mock.closed = mock.closed + 1 end,
}
local ui = {}
for _, name in ipairs({ "column", "row", "scroll", "label", "button", "input", "markdown", "spacer" }) do
  ui[name] = function(props, children) return { kind = name, props = props, children = children or {} } end
end
