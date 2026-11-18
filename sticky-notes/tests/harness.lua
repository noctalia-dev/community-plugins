-- Shared Lua 5.4 test harness for the Sticky Notes plugin.
--
-- The plugin scripts target the Noctalia Luau runtime, so tests load the
-- transformed Lua 5.4 copies and supply a fake `noctalia` host API plus a
-- tree-capturing `ui` stub. Tests drive real persistence, real state watches
-- and real re-renders instead of mocking the plugin's own functions.

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

-- Minimal JSON encoder/decoder for the harness. Lua 5.4 has no JSON library
-- and the plugin's host API is replaced in tests, so the harness needs enough
-- fidelity to round-trip note arrays (the JSON file format) and the per-note
-- metadata objects inside Markdown files.
local ESCAPE_NAMES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
  ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}
local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
  n = "\n", r = "\r", t = "\t",
}

local function isArray(value)
  local entries = 0
  for key in pairs(value) do
    if type(key) ~= "number" then return false end
    entries = entries + 1
  end
  return entries > 0
end

local function encodeString(value)
  local escaped = value:gsub('[%z\1-\31\\"]', function(char)
    return ESCAPE_NAMES[char] or string.format("\\u%04x", char:byte())
  end)
  return '"' .. escaped .. '"'
end

local function encode(value)
  local kind = type(value)
  if kind == "string" then return encodeString(value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind ~= "table" then return "null" end
  local parts = {}
  if isArray(value) then
    for _, item in ipairs(value) do parts[#parts + 1] = encode(item) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    parts[#parts + 1] = encodeString(tostring(key)) .. ":" .. encode(item)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function decode(text)
  if type(text) ~= "string" then return nil end
  local position = 1
  local function skipSpace()
    while true do
      local char = text:sub(position, position)
      if char ~= " " and char ~= "\t" and char ~= "\n" and char ~= "\r" then return end
      position = position + 1
    end
  end
  local parseValue
  local function parseString()
    position = position + 1
    local buffer = {}
    while true do
      local char = text:sub(position, position)
      if char == "" then return nil end
      if char == '"' then position = position + 1; return table.concat(buffer) end
      if char == "\\" then
        local escape = text:sub(position + 1, position + 1)
        if escape == "u" then
          local code = tonumber(text:sub(position + 2, position + 5), 16)
          if code == nil then return nil end
          buffer[#buffer + 1] = utf8.char(code)
          position = position + 6
        else
          local mapped = ESCAPES[escape]
          if mapped == nil then return nil end
          buffer[#buffer + 1] = mapped
          position = position + 2
        end
      else
        buffer[#buffer + 1] = char
        position = position + 1
      end
    end
  end
  local function parseObject()
    position = position + 1
    local result = {}
    skipSpace()
    if text:sub(position, position) == "}" then position = position + 1; return result end
    while true do
      skipSpace()
      if text:sub(position, position) ~= '"' then return nil end
      local key = parseString()
      if key == nil then return nil end
      skipSpace()
      if text:sub(position, position) ~= ":" then return nil end
      position = position + 1
      local value = parseValue()
      if value == nil then return nil end
      result[key] = value
      skipSpace()
      local separator = text:sub(position, position)
      if separator == "," then position = position + 1
      elseif separator == "}" then position = position + 1; return result
      else return nil end
    end
  end
  local function parseArray()
    position = position + 1
    local result = {}
    skipSpace()
    if text:sub(position, position) == "]" then position = position + 1; return result end
    while true do
      local value = parseValue()
      if value == nil then return nil end
      result[#result + 1] = value
      skipSpace()
      local separator = text:sub(position, position)
      if separator == "," then position = position + 1
      elseif separator == "]" then position = position + 1; return result
      else return nil end
    end
  end
  parseValue = function()
    skipSpace()
    local char = text:sub(position, position)
    if char == "{" then return parseObject() end
    if char == "[" then return parseArray() end
    if char == '"' then return parseString() end
    if text:sub(position, position + 3) == "true" then position = position + 4; return true end
    if text:sub(position, position + 4) == "false" then position = position + 5; return false end
    local number = text:match("^%-?%d+%.?%d*", position)
    if number ~= nil then position = position + #number; return tonumber(number) end
    return nil
  end
  local value = parseValue()
  if value == nil then return nil end
  return value
end

local saved = '## Note 1\n\n<!-- sticky-notes {"id":"saved","color":"pink","createdAt":1,"pinned":true,"blurred":true} -->\n\nKeep this note\n'
local empty = '\n---\n\n## Note 2\n\n<!-- sticky-notes {"id":"empty","color":"blue","createdAt":2,"pinned":false,"blurred":false} -->\n\n\n'

-- options:
--   raw       -> file contents the service loads (default: the `saved` fixture)
--   format    -> "md" | "txt" | "json" (also selects the file extension)
--   autoBlur  -> value returned by the auto_blur setting
--   delayed   -> hold the async save-path setup so tests can step through it
--   config    -> overrides merged into the plugin settings
local function newHarness(servicePath, panelPath, options)
  options = options or {}
  local h = { state = {}, watchers = {}, queue = {}, processes = {}, writes = 0, open = false }
  local format = options.format or "md"
  local notesPath = "/notes/notes." .. format
  local raw = options.raw or saved
  local clock = 1789200000000
  local function enqueue(fn) h.queue[#h.queue + 1] = fn end
  local function set(key, value)
    h.state[key] = copy(value)
    for _, fn in ipairs(h.watchers[key] or {}) do
      local snapshot = copy(value)
      enqueue(function() fn(snapshot) end)
    end
  end
  local function watch(key, fn)
    h.watchers[key] = h.watchers[key] or {}
    table.insert(h.watchers[key], fn)
  end
  function h.flush()
    local calls = 0
    while #h.queue > 0 do
      calls = calls + 1
      assert(calls < 500, "state callbacks should settle")
      table.remove(h.queue, 1)()
    end
  end
  function h.step() assert(#h.queue > 0, "expected a pending host callback"); table.remove(h.queue, 1)() end
  local config = {
    save_path = "/notes",
    file_format = format,
    default_color = "green",
    auto_blur = options.autoBlur,
  }
  for key, value in pairs(options.config or {}) do config[key] = value end
  local function runAsync(argv, callback)
    h.processes[#h.processes + 1] = copy(argv)
    if argv[1] == "sh" then
      h.finishHome = function() callback({ stdout = "/home/test" }) end
      if not options.delayed then enqueue(h.finishHome) end
    elseif argv[1] == "mkdir" then
      enqueue(function() callback({ exitCode = 0 }) end)
    elseif argv[1] == "noctalia" then
      assert(table.concat(argv, " ") == "noctalia msg panel-open ahmedhossamdev/sticky-notes:panel new-note",
        "quick capture must open the panel with context, without toggling it closed")
      enqueue(function()
        h.loadPanel()
        h.open = true
        h.panel.onOpen(argv[5])
        if callback then callback({ exitCode = 0, stdout = "ok\n" }) end
      end)
    else
      error("unexpected process: " .. argv[1])
    end
    return true
  end
  local api = {
    state = { set = set, get = function(key) return copy(h.state[key]) end, watch = watch },
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    json = { encode = encode, decode = decode },
    getConfig = function(key) return config[key] end,
    setUpdateInterval = function() end,
    nowMs = function() clock = clock + 1; return clock end,
    pluginDataDir = function() return "/data" end,
    readFile = function(path) assert(path == notesPath); return raw end,
    writeFile = function(path, data)
      assert(path == notesPath)
      raw = data; h.writes = h.writes + 1; return true
    end,
    tr = function(key) return key end,
    focusedOutputName = function() return "test-output" end,
  }
  api.runAsync = runAsync
  h.service = setmetatable({ noctalia = api }, { __index = _G })
  assert(loadfile(servicePath, "t", h.service))()
  function h.loadPanel()
    if h.panel then return end
    local ui = setmetatable({}, { __index = function(_, kind)
      return function(props, children) return { kind = kind, props = props or {}, children = children or {} } end
    end })
    local palette = { refresh = function() end, setOnChanged = function() end }
    h.panel = setmetatable({
      noctalia = api, ui = ui,
      require = function(name) assert(name == "./palette.luau"); return palette end,
      panel = { render = function(tree) h.tree = tree end, close = function() h.open = false; h.panel.onClose() end },
    }, { __index = _G })
    assert(loadfile(panelPath, "t", h.panel))()
  end
  function h.find(predicate)
    local function visit(node)
      if not node then return end
      if predicate(node) then return node end
      for _, child in ipairs(node.children) do
        local found = visit(child)
        if found then return found end
      end
    end
    return visit(h.tree)
  end
  function h.input() return h.find(function(node) return node.kind == "input" end) end
  function h.ipc(event)
    assert(type(h.service.onIpc) == "function", "service should expose the public new-note IPC event")
    h.service.onIpc(event or "new-note", nil)
    h.flush()
  end
  -- Drive the service through the same channel the panel uses.
  function h.cmd(command) set("sticky_notes.cmd", command); h.flush() end
  function h.notes() return h.state["sticky_notes.notes"] end
  function h.archived() return h.state["sticky_notes.archived"] end
  function h.raw() return raw end
  h.flush()
  return h
end

return { new = newHarness, saved = saved, empty = empty }
