--!nonstrict
-- Minimal Noctalia host used by the standalone Luau parser tests.

local files = {}
local stateValues = {}
local stateWatchers = {}
local fileExistsOverrides = {}
local configValues = {}
local availableCommands = {}
local asyncRequests = {}
local renderCount = 0
local renderedTree = nil
local readCounts = {}
local writeCounts = {}
local wantsSecondTicks = false
local encodedValues = {}
local encodedIndex = 0
local errorNotifications = 0
local updateInterval = nil

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function normalize(path)
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= "." and part ~= "" then
      table.insert(parts, part)
    end
  end
  return (absolute and "/" or "") .. table.concat(parts, "/")
end

local function directory(path)
  local prefix = path:gsub("/+$", "") .. "/"
  local names = {}
  for file in pairs(files) do
    if file:sub(1, #prefix) == prefix then
      local rest = file:sub(#prefix + 1)
      local name = rest:match("^([^/]+)")
      if name ~= nil then names[name] = true end
    end
  end
  local result = {}
  for name in pairs(names) do table.insert(result, name) end
  table.sort(result)
  return result
end

local function translation(key, substitutions)
  local value = key
  for name, replacement in pairs(substitutions or {}) do
    value = value:gsub("{" .. name .. "}", tostring(replacement))
  end
  return value
end

local noctalia = {
  tr = translation,
  getenv = function(name) return name == "HOME" and "/home/test" or nil end,
  expandPath = function(path) return normalize(path:gsub("^~", "/home/test")) end,
  fileExists = function(path)
    path = normalize(path)
    if fileExistsOverrides[path] ~= nil then return fileExistsOverrides[path] end
    if files[path] ~= nil then return true end
    return #directory(path) > 0
  end,
  fileInfo = function(path)
    path = normalize(path)
    if files[path] ~= nil then return { size = #files[path], mtime = 0, isDir = false } end
    if #directory(path) > 0 then return { size = 0, mtime = 0, isDir = true } end
    return nil, "missing"
  end,
  listDir = function(path)
    local values = directory(normalize(path))
    if #values > 0 then return values, nil end
    return nil, "missing"
  end,
  readFile = function(path)
    path = normalize(path)
    readCounts[path] = (readCounts[path] or 0) + 1
    local content = files[path]
    if content ~= nil then return content, nil end
    return nil, "missing"
  end,
  writeFile = function(path, content)
    path = normalize(path)
    files[path] = content
    writeCounts[path] = (writeCounts[path] or 0) + 1
    return true
  end,
  renameFile = function(from, to)
    from = normalize(from)
    to = normalize(to)
    if files[from] == nil then return false, "missing" end
    files[to] = files[from]
    files[from] = nil
    return true
  end,
  removeFile = function(path)
    files[normalize(path)] = nil
    return true
  end,
  pluginDir = function() return "/plugin" end,
  pluginDataDir = function() return "/data" end,
  commandExists = function(name) return availableCommands[name] == true end,
  getConfig = function(key) return configValues[key] end,
  outputs = function() return {} end,
  focusedOutputName = function() return nil end,
  clipboardText = function() return nil end,
  openColorPicker = function() return false end,
  notify = function() end,
  notifyError = function() errorNotifications += 1 end,
  log = function() end,
  togglePanel = function() end,
  setUpdateInterval = function(value) updateInterval = value end,
  runAsync = function(command, callback, timeoutMs)
    table.insert(asyncRequests, { command = command, callback = callback, timeoutMs = timeoutMs, completed = false })
    return true
  end,
  string = { trim = function(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end },
  json = {
    decode = function(raw)
      local value = encodedValues[raw]
      if value == nil then return nil, "invalid mock JSON" end
      return copy(value), nil
    end,
    encode = function(value)
      encodedIndex += 1
      local token = "__mock_json_" .. tostring(encodedIndex)
      encodedValues[token] = copy(value)
      return token, nil
    end,
  },
  state = {
    get = function(key) return copy(stateValues[key]) end,
    set = function(key, value)
      stateValues[key] = copy(value)
      for _, watcher in ipairs(stateWatchers[key] or {}) do watcher(copy(value)) end
    end,
    watch = function(key, callback)
      stateWatchers[key] = stateWatchers[key] or {}
      table.insert(stateWatchers[key], callback)
    end,
  },
}

local function node(kind)
  return function(props, children) return { type = kind, props = props or {}, children = children or {} } end
end

local ui = {}
for _, kind in ipairs({ "column", "row", "box", "label", "glyph", "image", "separator", "spacer", "progress", "button", "graph", "input", "select", "slider", "toggle", "scroll" }) do
  ui[kind] = node(kind)
end

return {
  noctalia = noctalia,
  ui = ui,
  panel = {
    render = function(_tree)
      renderCount += 1
      renderedTree = _tree
    end,
    close = function() end,
    setWantsSecondTicks = function(value)
      wantsSecondTicks = value == true
    end,
  },
  setFiles = function(value)
    files = {}
    fileExistsOverrides = {}
    for path, content in pairs(value) do files[normalize(path)] = content end
  end,
  setFileExists = function(path, value)
    fileExistsOverrides[normalize(path)] = value
  end,
  resetRuntime = function()
    stateValues = {}
    configValues = {}
    availableCommands = {}
    asyncRequests = {}
    renderCount = 0
    renderedTree = nil
    readCounts = {}
    writeCounts = {}
    wantsSecondTicks = false
    errorNotifications = 0
    updateInterval = nil
  end,
  setFile = function(path, content)
    files[normalize(path)] = content
  end,
  setConfig = function(values) configValues = values or {} end,
  setAvailableCommands = function(values) availableCommands = values or {} end,
  asyncLaunchCount = function() return #asyncRequests end,
  completeAsync = function(index, result)
    local request = asyncRequests[index]
    if request == nil or request.completed then return false end
    request.completed = true
    if request.callback ~= nil then request.callback(result) end
    return true
  end,
  renderCount = function() return renderCount end,
  renderedTree = function() return renderedTree end,
  readCount = function(path) return readCounts[normalize(path)] or 0 end,
  writeCount = function(path) return writeCounts[normalize(path)] or 0 end,
  fileContent = function(path) return files[normalize(path)] end,
  wantsSecondTicks = function() return wantsSecondTicks end,
  errorNotificationCount = function() return errorNotifications end,
  stateValue = function(key) return copy(stateValues[key]) end,
  updateInterval = function() return updateInterval end,
}
