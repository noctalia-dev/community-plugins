--!nonstrict
-- A fake Noctalia host: the noctalia.*, ui.*, barWidget.* and panel.* globals
-- with in-memory files, a controllable clock, scripted HTTP and synchronous
-- state watchers. Every plugin entry under test gets these as its globals.

local json = require("./json")

local M = {}

local function lookup(tree, key: string)
  local node = tree
  for part in string.gmatch(key, "[^.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[part]
  end
  return if type(node) == "string" then node else nil
end

function M.new(sources)
  local translations = assert(json.decode(sources["translations/en.json"]))

  local host = {
    clock = 1_790_000_000, -- Unix seconds
    config = {},
    env = {},
    files = {},
    mtimes = {}, -- path -> mtime; set when a file is written through a helper
    dirs = {}, -- folders made with mkdirAll
    requests = {},
    httpHandler = nil, -- function(req) -> response | nil (nil = never answers)
    pending = {}, -- callbacks of unanswered requests
    notifications = {},
    stateValues = {},
    watchers = {},
    toggledPanels = {},
    commands = { ["xdg-open"] = true },
    spawned = {},
    terminals = {}, -- commands passed to runInTerminal
    terminalWorks = true,
    clipboard = nil,
    vertical = false,
    barTree = nil,
    tooltip = nil,
    panelTree = nil,
  }

  local function tr(key: string, subst)
    local text = lookup(translations, key)
    if text == nil then
      return key
    end
    if subst then
      text = text:gsub("{([%w_]+)}", function(name)
        local v = subst[name]
        return if v ~= nil then tostring(v) else nil
      end)
    end
    return text
  end

  local function expand(path: string): string
    if path == "~" then
      return "/home/test"
    elseif path:sub(1, 2) == "~/" then
      return "/home/test/" .. path:sub(3)
    end
    return path
  end

  local noctalia = {
    log = function() end,
    nowMs = function()
      return host.clock * 1000
    end,
    getenv = function(name)
      return host.env[name]
    end,
    expandPath = expand,
    getConfig = function(key)
      return host.config[key]
    end,
    isDarkMode = function()
      return true
    end,
    getColor = function(role)
      local palette = { on_surface = "#E0E0E0", surface_variant = "#303030", primary = "#88AAFF", error = "#FF6666", tertiary = "#FFCC66" }
      return palette[role]
    end,
    tr = tr,
    trp = function(key: string, count: number, subst)
      local all = { count = count }
      for k, v in subst or {} do
        all[k] = v
      end
      return tr(`{key}.{if count == 1 then "one" else "other"}`, all)
    end,
    readFile = function(path)
      local content = host.files[expand(path)]
      if content == nil then
        return nil, "not found"
      end
      return content, nil
    end,
    writeFile = function(path, content)
      host.files[expand(path)] = content
      return true, nil
    end,
    renameFile = function(from, to)
      host.files[expand(to)] = host.files[expand(from)]
      host.files[expand(from)] = nil
      return true, nil
    end,
    removeFile = function(path)
      host.files[expand(path)] = nil
      return true, nil
    end,
    fileExists = function(path)
      return host.files[expand(path)] ~= nil
    end,
    fileInfo = function(path)
      local content = host.files[expand(path)]
      if content == nil then
        return nil, "not found"
      end
      return { size = #content, mtime = host.mtimes[expand(path)] or 0, isDir = false }
    end,
    mkdirAll = function(path)
      host.dirs[expand(path)] = true
      return true, nil
    end,
    -- Names directly inside `path`, from the files and folders the host holds.
    listDir = function(path)
      local prefix = expand(path):gsub("/$", "") .. "/"
      local names, seen = {}, {}
      local function visit(full)
        if full:sub(1, #prefix) == prefix then
          local name = full:sub(#prefix + 1):match("^[^/]+")
          if name and not seen[name] then
            seen[name] = true
            table.insert(names, name)
          end
        end
      end
      for full in host.files do
        visit(full)
      end
      for full in host.dirs do
        visit(full)
      end
      return names, nil
    end,
    pluginDataDir = function()
      return "/data", nil
    end,
    pluginDir = function()
      return "/plugin"
    end,
    http = function(req, cb)
      table.insert(host.requests, req)
      local response = if host.httpHandler then host.httpHandler(req) else nil
      if response then
        cb(response)
      else
        table.insert(host.pending, cb)
      end
      return true
    end,
    notify = function(title, body)
      table.insert(host.notifications, { title = title, body = body })
    end,
    notifyError = function(title, body)
      table.insert(host.notifications, { title = title, body = body, error = true })
    end,
    runInTerminal = function(cmd)
      table.insert(host.terminals, cmd)
      return host.terminalWorks
    end,
    copyToClipboard = function(text)
      host.clipboard = text
      return true
    end,
    string = {
      trim = function(text)
        return (text:match("^%s*(.-)%s*$"))
      end,
    },
    setUpdateInterval = function() end,
    togglePanel = function(id)
      table.insert(host.toggledPanels, id)
    end,
    openSettings = function() end,
    commandExists = function(name)
      return host.commands[name] == true
    end,
    -- host.runHandler(argv) -> CommandResult-ish table; unscripted commands fail.
    runAsync = function(argv, onResult, _timeoutMs)
      table.insert(host.spawned, argv)
      if onResult then
        local result = host.runHandler and host.runHandler(argv) or nil
        result = result or { exitCode = 127, stdout = "", stderr = "" }
        result.timedOut = result.timedOut or false
        result.stderr = result.stderr or ""
        onResult(result)
      end
      return true
    end,
    timeFormat = function()
      return "{:%H:%M}"
    end,
    dateFormat = function()
      return "%a"
    end,
    -- UTC, enough of strftime for the patterns the plugin uses.
    formatTime = function(pattern, unix)
      unix = unix or host.clock
      local days = unix // 86400
      local secs = unix % 86400
      local weekdays = { "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" }
      pattern = pattern:gsub("^{:(.*)}$", "%1")
      return (pattern:gsub("%%(%a)", function(c)
        if c == "H" then return string.format("%02d", secs // 3600) end
        if c == "M" then return string.format("%02d", secs % 3600 // 60) end
        if c == "a" then return weekdays[days % 7 + 1] end
        return "%" .. c
      end))
    end,
    json = {
      decode = json.decode,
      encode = function(value)
        return json.encode(value), nil
      end,
    },
    state = {
      get = function(key)
        return host.stateValues[key]
      end,
      -- Like the host: values cross entries as JSON, which refuses invalid UTF-8.
      set = function(key, value)
        local text = json.encode(value)
        assert(utf8.len(text) ~= nil, "noctalia.state.set: invalid UTF-8")
        value = json.decode(text)
        host.stateValues[key] = value
        for _, fn in host.watchers[key] or {} do
          fn(value)
        end
      end,
      watch = function(key, fn)
        host.watchers[key] = host.watchers[key] or {}
        table.insert(host.watchers[key], fn)
      end,
    },
  }

  local function node(kind)
    return function(props, children)
      return { type = kind, props = props or {}, children = children or {} }
    end
  end
  local ui = {}
  for _, kind in { "column", "row", "scroll", "label", "glyph", "image", "separator", "progress", "button", "input" } do
    ui[kind] = node(kind)
  end

  host.globals = {
    os = {
      time = function(t)
        return if t then os.time(t) else host.clock
      end,
    },
    utf8 = utf8,
    noctalia = noctalia,
    ui = ui,
    barWidget = {
      render = function(tree)
        host.barTree = tree
      end,
      setTooltip = function(t)
        host.tooltip = t
      end,
      isVertical = function()
        return host.vertical
      end,
    },
    panel = {
      render = function(tree)
        host.panelTree = tree
      end,
      close = function() end,
      setWantsSecondTicks = function() end,
    },
  }

  return host
end

-- Depth-first search of a ui tree.
function M.find(tree, predicate)
  local found = {}
  local function walk(n)
    if type(n) ~= "table" then
      return
    end
    if predicate(n) then
      table.insert(found, n)
    end
    for _, child in n.children or {} do
      walk(child)
    end
  end
  walk(tree)
  return found
end

-- All label texts in a ui tree, in order.
function M.texts(tree): { string }
  local out = {}
  for _, n in M.find(tree, function(n) return n.type == "label" end) do
    table.insert(out, n.props.text)
  end
  return out
end

return M
