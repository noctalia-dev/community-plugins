-- Test suite for the `faminec/terminal-widgets` plugin.
--
--   lua5.4 test-panel.lua                       # tests the copy in this repo
--   lua5.4 test-panel.lua /path/to/other        # tests another copy (the installed one)
--
-- Two parts:
--
--   1. `lib/` modules: with a simulated Noctalia API, checks the widget-list
--      merge, tombstones, manifest parser, position parser, occupied areas,
--      thumbnail cleanup and the five rotation permutations.
--
--   2. Panel (`panel.luau`): loaded with the simulated UI, checks that cards,
--      grid, edit mode and IPC handlers do what they should. This is the part
--      that catches "attempt to call a nil value" (in Luau a `local` only
--      exists from its declaration onward).
--
-- Exits with a non-zero code if any case fails.


-- The real runtime is Luau, which does include `math.atan2`; Lua 5.4 does not
-- (only since 5.4.9). Lua 5.4's `math.atan(y, x)` is atan2, so it is used as a
-- fallback when missing, so the documented command works on any Lua 5.4
-- (Ubuntu's 5.4.4, other systems' 5.4.8) without touching the plugin runtime.

if type(math.atan2) ~= "function" then
  math.atan2 = math.atan
end

local function scriptDir()
  local self = arg and arg[0] or ""
  return self:match("^(.*)[/\\][^/\\]+$") or "."
end

local DIR = (arg and arg[1]) or (scriptDir() .. "/")
if DIR:sub(-1) ~= "/" then
  DIR = DIR .. "/"
end

local FAILED = 0
local PASSED = 0

local function check(name, expected, got)
  if expected == got then
    PASSED = PASSED + 1
    print(string.format("  ok   %-58s %s", name, tostring(got)))
  else
    FAILED = FAILED + 1
    print(string.format("  FAIL %-58s expected=%s got=%s", name, tostring(expected), tostring(got)))
  end
end

-- A check that does not apply in this run (neither a failure nor a pass):
-- it is reported, but not scored.
local function skip(name, reason)
  print(string.format("  --   %-58s %s", name, tostring(reason or "skipped")))
end

-- --------------------------------------------------------------- simulator --

local files = {}
local TESTDATA = os.tmpname()
local config = {
  terminal = "kitty",
  width = 900,
  height = 520,
  x = 120,
  y = 140,
  margin = 16,
  output = "",
  close_on_launch = false,
  reuse_existing = true,
  rotation = "clockwise",
  rotation_sizes = false,
  columns = 2,
  card_preview = "auto",
  avoid_collisions = true,
  commands = {},
  layouts = {},
}

local clients = {}
local notifications = {}
local rendered = 0
local clock = 0

local function jsonQuote(value)
  return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

-- Recursive encoder (objects, arrays, booleans and numbers) so the store can
-- save maps inside the root map and the brain toggle.
local function jsonEncode(value)
  if type(value) == "string" then
    return jsonQuote(value)
  elseif type(value) == "boolean" or type(value) == "number" then
    return tostring(value)
  elseif type(value) ~= "table" then
    return "null"
  end
  local parts = {}
  if value[1] ~= nil then
    for _, item in ipairs(value) do
      parts[#parts + 1] = jsonEncode(item)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    parts[#parts + 1] = jsonQuote(key) .. ":" .. jsonEncode(item)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- `hyprctl clients -j` JSON from the `clients` table. Accepts both forms used
-- by the sections: the raw hyprctl one (`at` and `size` as positional arrays,
-- what actually comes from the compositor) and the normalized one (`x`, `y`,
-- `w`, `h`). The callback receives the host's real `CommandResult`: a single
-- table `{ exitCode, stdout, stderr }`.
local function clientsJson()
  local parts = {}
  for _, client in ipairs(clients) do
    local at = client.at or { client.x or 0, client.y or 0 }
    local size = client.size or { client.w or 0, client.h or 0 }
    parts[#parts + 1] = string.format(
      '{"address":"%s","class":"%s","title":"%s","at":[%d,%d],"size":[%d,%d],"monitor":"%s"}',
      client.address or "0x0",
      client.class or "",
      client.title or "",
      math.floor(tonumber(at[1]) or 0),
      math.floor(tonumber(at[2]) or 0),
      math.floor(tonumber(size[1]) or 0),
      math.floor(tonumber(size[2]) or 0),
      client.monitor or "1"
    )
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local mock = {
  getConfig = function(key)
    return config[key]
  end,
  pluginDir = function()
    return DIR
  end,
  pluginDataDir = function()
    -- Temporary path: the simulator does not actually write to disk.
    return TESTDATA
  end,
  readFile = function(path)
    return files[path]
  end,
  writeFile = function(path, content)
    files[path] = content
    return true
  end,
  mkdirAll = function()
    return true
  end,
  listDir = function()
    local names = {}
    for name in pairs(files) do
      names[#names + 1] = name
    end
    return names
  end,
  removeFile = function(path)
    files[path] = nil
    return true
  end,
  fileExists = function(path)
    return files[path] ~= nil
  end,
  fileInfo = function()
    return { size = 10, mtime = os.time(), isDir = false }
  end,
  json = {
    encode = jsonEncode,
    decode = function(text)
      -- Only the format produced by the simulator is needed: a list of
      -- objects with strings and numbers, and the store's flat map.
      local trimmed = text:match("^%s*(.-)%s*$")
      if trimmed:sub(1, 1) == "[" then
        local out = {}
        for object in trimmed:gmatch("{(.-)}") do
          local item = {}
          -- In Lua patterns, alternation "|" only exists at the top level:
          -- inside a group it does not work. That is why there is one pass for
          -- texts and another for numbers.
          for key, value in object:gmatch('"([^"]+)":"([^"]*)"') do
            item[key] = value
          end
          for key, value in object:gmatch('"([^"]+)":(-?%d+)') do
            if item[key] == nil then
              item[key] = tonumber(value)
            end
          end
          -- Numeric arrays ("at":[x,y], "size":[w,h]): without this the
          -- simulator would not see the window geometry.
          for key, array in object:gmatch('"([^"]+)":%[([^%]]*)%]') do
            local numbers = {}
            for number in array:gmatch("-?%d+") do
              numbers[#numbers + 1] = tonumber(number)
            end
            item[key] = numbers
          end
          out[#out + 1] = item
        end
        return out
      end
      -- Objects: with nested values (the store saves maps inside the root
      -- map) and booleans. Minimal recursive parser.
      local src = trimmed
      local pos = 1

      local function skipSpaces()
        while src:sub(pos, pos):match("%s") do pos = pos + 1 end
      end

      local function parseString()
        pos = pos + 1
        local out = {}
        while pos <= #src do
          local ch = src:sub(pos, pos)
          if ch == '"' then
            pos = pos + 1
            return table.concat(out)
          elseif ch == "\\" then
            local esc = src:sub(pos + 1, pos + 1)
            if esc == "n" then
              out[#out + 1] = "\n"
              pos = pos + 2
            elseif esc == "t" then
              out[#out + 1] = "\t"
              pos = pos + 2
            elseif esc == "r" then
              out[#out + 1] = "\r"
              pos = pos + 2
            elseif esc == "u" then
              out[#out + 1] = "?"
              pos = pos + 6
            elseif esc == "" then
              pos = pos + 1
            else
              out[#out + 1] = esc
              pos = pos + 2
            end
          else
            out[#out + 1] = ch
            pos = pos + 1
          end
        end
        return table.concat(out)
      end

      local parseValue

      local function parseArray()
        pos = pos + 1
        local out = {}
        skipSpaces()
        if src:sub(pos, pos) == "]" then
          pos = pos + 1
          return out
        end
        while true do
          out[#out + 1] = parseValue()
          skipSpaces()
          local ch = src:sub(pos, pos)
          if ch == "," then
            pos = pos + 1
          elseif ch == "]" then
            pos = pos + 1
            return out
          else
            return out
          end
        end
      end

      local function parseObject()
        pos = pos + 1
        local out = {}
        skipSpaces()
        if src:sub(pos, pos) == "}" then
          pos = pos + 1
          return out
        end
        while true do
          skipSpaces()
          local key = parseString()
          if key == nil then
            return out
          end
          skipSpaces()
          if src:sub(pos, pos) == ":" then
            pos = pos + 1
          end
          out[key] = parseValue()
          skipSpaces()
          local ch = src:sub(pos, pos)
          if ch == "," then
            pos = pos + 1
          elseif ch == "}" then
            pos = pos + 1
            return out
          else
            return out
          end
        end
      end

      function parseValue()
        skipSpaces()
        local ch = src:sub(pos, pos)
        if ch == '"' then
          return parseString()
        elseif ch == "{" then
          return parseObject()
        elseif ch == "[" then
          return parseArray()
        elseif src:sub(pos, pos + 4) == "false" then
          pos = pos + 5
          return false
        elseif src:sub(pos, pos + 3) == "true" then
          pos = pos + 4
          return true
        elseif src:sub(pos, pos + 3) == "null" then
          pos = pos + 4
          return nil
        else
          local from = pos
          while src:sub(pos, pos):match("[%d%.%+%-eE]") do
            pos = pos + 1
          end
          return tonumber(src:sub(from, pos - 1))
        end
      end

      local value = parseValue()
      if type(value) == "table" then
        return value
      end
      return {}
    end,
  },
  log = function() end,
  tr = function(key, args)
    local out = tostring(key)
    if type(args) == "table" then
      for name, value in pairs(args) do
        out = out:gsub("{" .. name .. "}", tostring(value))
      end
    end
    return out
  end,
  notify = function(title, body)
    notifications[#notifications + 1] = { title = title, body = body }
  end,
  notifyError = function(title, body)
    notifications[#notifications + 1] = { title = title, body = body, error = true }
  end,
  -- Clock controlled by the test: the 700 ms debounce depends on it.
  nowMs = function()
    return clock
  end,
  outputs = function()
    return { { name = "DP-1", width = 3440, height = 1440, x = 0, y = 0, scale = 1, focused = true } }
  end,
  commandExists = function()
    return true
  end,
  runInTerminal = function()
    return true
  end,
  runAsync = function(argv, callback)
    local command = table.concat(argv, " ")
    if command:find("hyprctl clients", 1, true) then
      if callback ~= nil then
        callback({ exitCode = 0, stdout = clientsJson(), stderr = "" })
      end
      return true
    end
    if command:find("hyprctl monitors", 1, true) then
      if callback ~= nil then
        callback({
          exitCode = 0,
          stdout = '[{"id":1,"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1}]',
          stderr = "",
        })
      end
      return true
    end
    if callback ~= nil then
      callback({ exitCode = 0, stdout = "", stderr = "" })
    end
    return true
  end,
}

-- In-memory shared state (`noctalia.state`), atomic rename and service tick.
-- `serviceUpdatedMs` is a test-file global: the service section reads it.

local sharedState = {}
mock.state = {
  get = function(key) return sharedState[key] end,
  set = function(key, value) sharedState[key] = value end,
  watch = function(_key, _callback) end,
}
mock.renameFile = function(from, to)
  local content = files[from]
  if content == nil then return false end
  files[to] = content
  files[from] = nil
  return true
end
serviceUpdatedMs = nil
mock.setUpdateInterval = function(ms) serviceUpdatedMs = ms return true end

local function makeNode(kind)
  return function(props, children)
    return { type = kind, props = props or {}, children = children or {} }
  end
end

local uiMock = {
  column = makeNode("column"),
  row = makeNode("row"),
  label = makeNode("label"),
  glyph = makeNode("glyph"),
  image = makeNode("image"),
  box = makeNode("box"),
  button = makeNode("button"),
  input = makeNode("input"),
  scroll = makeNode("scroll"),
  separator = makeNode("separator"),
  spacer = makeNode("spacer"),
}

local lastTree = nil
local panelMock = {
  render = function(tree)
    rendered = rendered + 1
    lastTree = tree
  end,
  close = function() end,
  openContextMenu = function()
    return true
  end,
  setNeedsFrameTick = function() end,
  setWantsSecondTicks = function() end,
}

-- Dispatched expressions are collected here (shared by the rotation and panel
-- sections).
local dispatched = {}

-- ----------------------------------------------------------------- environment --

local env = setmetatable({
  noctalia = mock,
  panel = panelMock,
  ui = uiMock,
}, { __index = _G })

env.require = function(path)
  local name = path:match("([^/]+)$")
  local chunk = assert(loadfile(DIR .. "lib/" .. name, "t", env))
  return chunk()
end

local function loadModule(name)
  local chunk = assert(loadfile(DIR .. "lib/" .. name, "t", env))
  return chunk()
end

local util = loadModule("util.luau")
local store = loadModule("store.luau")
local layout = loadModule("layout.luau")
local defaults = loadModule("defaults.luau")
local win = loadModule("windows.luau")
local preview = loadModule("preview.luau")

-- --------------------------------------------------------------- utilities --

print("== utilities ==")
check("slug", util.slug("Mi Widget!"), "mi-widget")
check("empty slug", util.slug("!!!"), "app")
check("class", util.classFor("Cava"), "noctalia-term-cava")
check("trim", util.trim("  hello  "), "hello")

-- ------------------------------------------------------------ widget merge --

print("\n== widget merge ==")
local base = { a = "a-cmd", b = "b-cmd" }
local configMap = { b = "b-cmd-editado", c = "c-cmd" }
local storeMap = { d = "d-cmd" }
local removed = { "a" }

local merged = store.merge(base, configMap, storeMap, removed)
check("config overrides the default", merged.b, "b-cmd-editado")
check("new config entry", merged.c, "c-cmd")
check("new store entry", merged.d, "d-cmd")
check("tombstone deletes the default", merged.a, nil)
check("without a tombstone the default is kept", store.merge({ a = "x" }, {}, {}, {}).a, "x")
check("empty Settings value is ignored", store.merge({ a = "x" }, { a = "" }, {}, {}).a, "x")
check("empty store value is respected", store.merge({ a = "x" }, {}, { a = "" }, {}).a, "")
check("store overrides the default", store.merge({ a = "x" }, {}, { a = "y" }, {}).a, "y")

-- Tree node keys in pre-order (used to check the relative order of cards when
-- rendering). It is a global on purpose: the sections below use it.

function nodeKeys(tree, out)
  out = out or {}
  if type(tree) ~= "table" then return out end
  if tree.key ~= nil then table.insert(out, tree.key) end
  for _, child in ipairs(tree.children or {}) do nodeKeys(child, out) end
  return out
end

-- --- harness: shared state, atomic rename and service tick ---
check("noctalia.state reads and writes", "hello", (function()
  mock.state.set("k", "hello")
  return mock.state.get("k")
end)())
check("missing noctalia.state is nil", nil, mock.state.get("does-not-exist"))
files["/tmp/a.tmp"] = "contenido"
check("renameFile returns true", true, mock.renameFile("/tmp/a.tmp", "/tmp/a.json"))
check("renameFile moves the contents", "contenido", files["/tmp/a.json"])
check("renameFile deletes the source", nil, files["/tmp/a.tmp"])
check("renameFile without a source returns false", false, mock.renameFile("/tmp/nada", "/tmp/otro"))
check("setUpdateInterval exists", "function", type(mock.setUpdateInterval))
check("nodeKeys traverses in pre-order", "root/child1/child2", (function()
  local tree = { key = "root", children = { { key = "child1" }, { key = "child2" } } }
  return table.concat(nodeKeys(tree), "/")
end)())

-- -------------------------------------------------------------- store --

print("\n== store: add and delete ==")
local st = { commands = {}, layouts = {}, removed = {} }
store.upsert(st, "new", "echo hello", "center, 800x400")
check("widget added", st.commands.new, "echo hello")
check("position added", st.layouts.new, "center, 800x400")
store.remove(st, "new")
check("widget deleted", st.commands.new, nil)
check("tombstone created", st.removed[1], "new")
store.upsert(st, "new", "echo hello")
check("tombstone cleared when adding again", #st.removed, 0)

local stClear = { commands = {}, layouts = {}, thumbs = {}, removed = {} }
store.upsert(stClear, "x", "cmd", "center, 800x400", "/tmp/thumbnail.png")
store.upsert(stClear, "x", nil, "", "")
check("empty layout removes the position", stClear.layouts.x, nil)
check("empty thumb removes the thumbnail", stClear.thumbs.x, nil)

-- Brain memory (toggle and remembered geometries) lives in the same
-- store.json: an old store does not have it, and every partial write must
-- keep what is on disk.
local storeLib = store
local storePath = storeLib.path()

-- new fields with default values in an old store
files[storePath] = '{"commands":{"a":"one"},"layouts":{"a":"center, 100x100"}}'
local legacy = storeLib.load()
check("store: brain defaults to false", false, legacy.brain)
check("store: brainGeometry defaults to empty", 0, (function() local n = 0 for _ in pairs(legacy.brainGeometry) do n = n + 1 end return n end)())

-- saveWidgets preserves the memory on disk
files[storePath] = '{"commands":{},"layouts":{},"thumbs":{},"removed":{},"brain":true,"brainGeometry":{"noctalia-term-a":"center, 100x100"}}'
storeLib.saveWidgets({ commands = { a = "one" }, layouts = {}, thumbs = {}, removed = {} })
local afterWidgets = storeLib.load()
check("saveWidgets: writes commands", "one", afterWidgets.commands.a)
check("saveWidgets: preserves brain", true, afterWidgets.brain)
check("saveWidgets: preserves brainGeometry", "center, 100x100", afterWidgets.brainGeometry["noctalia-term-a"])
check("saveWidgets: temporary file deleted", nil, files[storePath .. ".tmp"])

-- saveBrainToggle preserves the widgets
storeLib.saveBrainToggle(false)
local afterToggle = storeLib.load()
check("saveBrainToggle: turns off", false, afterToggle.brain)
check("saveBrainToggle: preserves commands", "one", afterToggle.commands.a)

-- saveBrainGeometry changes only what it receives
storeLib.saveBrainGeometry({ ["noctalia-term-b"] = "top-right, 200x200" })
local afterGeometry = storeLib.load()
check("saveBrainGeometry: adds", "top-right, 200x200", afterGeometry.brainGeometry["noctalia-term-b"])
check("saveBrainGeometry: keeps the others", "center, 100x100", afterGeometry.brainGeometry["noctalia-term-a"])
check("saveBrainGeometry: preserves brain", false, afterGeometry.brain)

-- saveBrainForget deletes only one
storeLib.saveBrainForget("noctalia-term-a")
local afterForget = storeLib.load()
check("saveBrainForget: deletes the requested one", nil, afterForget.brainGeometry["noctalia-term-a"])
check("saveBrainForget: leaves the others", "top-right, 200x200", afterForget.brainGeometry["noctalia-term-b"])

-- loadBrain re-reads the disk even if the in-memory state is old
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{"noctalia-term-c":"center, 50x50"}}'
local fresh = storeLib.loadBrain()
check("loadBrain: brain from disk", true, fresh.brain)
check("loadBrain: memory from disk", "center, 50x50", fresh.brainGeometry["noctalia-term-c"])

-- -------------------------------------------------------------- positions --

print("\n== positions ==")
local spec = layout.parseLayout("bottom-center, 1610x584")
check("anchor", spec.anchor, "bottom-center")
check("width", spec.width, 1610)
check("height", spec.height, 584)

spec = layout.parseLayout("right-center 869x1424")
check("anchor without comma", spec.anchor, "right-center")
check("width without comma", spec.width, 869)

spec = layout.parseLayout("bottom-left, 802x582, 0, -24")
check("offset x", spec.dx, 0)
check("offset y", spec.dy, -24)

spec = layout.parseLayout("custom, 900x520, 120, 140")
check("absolute", spec.custom, true)
check("absolute x", spec.dx, 120)
check("absolute y", spec.dy, 140)

spec = layout.parseLayout("x=120 y=140 w=900 h=520")
check("key=value x", spec.dx, 120)
check("key=value width", spec.width, 900)

spec = layout.parseLayout("auto, 900x520")
check("auto", spec.auto, true)
check("Spanish anchor", layout.parseLayout("abajo-izquierda, 100x100").anchor, "bottom-left")
check("invalid", layout.parseLayout("not a position").valid, false)
check("empty", layout.parseLayout(""), nil)
check("anchor only", layout.parseLayout("center").anchor, "center")
check("extra spaces", layout.parseLayout("bottom-center , 1610x584").anchor, "bottom-center")
check("size with spaces", layout.parseLayout("bottom-center , 1610x584").width, 1610)
check("custom without coordinates", layout.parseLayout("custom, 900x520").valid, false)
check("auto without size", layout.parseLayout("auto").auto, true)
check("anchor with underscore", layout.parseLayout("bottom_center").anchor, "bottom-center")
check("negative size", layout.parseLayout("bottom-center, -10x-10").width, nil)

local ax, ay = layout.anchorPosition("bottom-right", 900, 520, 3440, 1440, 16)
check("anchor bottom-right x", ax, 3440 - 900 - 16)
check("anchor bottom-right y", ay, 1440 - 520 - 16)

-- -------------------------------------------------------------- manifest --

print("\n== manifest ==")
files[DIR .. "plugin.toml"] = [==[
[[setting]]
key = "commands"
type = "string_map"
label_key = "settings.commands.label"
description_key = "settings.commands.description"
default = { cava = "cava", cbonsai = "cbonsai -l -i", unimatrix = "unimatrix -s 96 -l o" }

[[setting]]
key = "layouts"
type = "string_map"
label_key = "settings.layouts.label"
description_key = "settings.layouts.description"
default = { cava = "bottom-center, 1610x584", cbonsai = "top-center, 801x582" }
]==]
defaults.reset()
local base2 = defaults.load()
check("manifest commands", base2.commands.cava, "cava")
check("command with spaces", base2.commands.cbonsai, "cbonsai -l -i")
check("command with hyphens", base2.commands.unimatrix, "unimatrix -s 96 -l o")
check("manifest position", base2.layouts.cava, "bottom-center, 1610x584")
check("position with commas", base2.layouts.cbonsai, "top-center, 801x582")

files[DIR .. "plugin.toml"] = "[[setting]]\nkey = \"commands\"\ndefault = { a = \"x\" }\n"
defaults.reset()
local base3 = defaults.load()
check("minimal manifest", base3.commands.a, "x")
check("fallback positions", base3.layouts.cava, "bottom-center, 1610x584")

files[DIR .. "plugin.toml"] = nil
defaults.reset()
local base4 = defaults.load()
check("no manifest: fallback", base4.commands.cava, "cava")
check("no manifest: fallback positions", base4.layouts.unimatrix, "right-center, 869x1424")

-- The manifest must declare everything the plugin launches: the upstream
-- reviewer checks it against `dependencies` and the README. The real
-- `plugin.toml` is read from disk (the simulator only intercepts `noctalia.readFile`).
local function readRealFile(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local manifestText = readRealFile(DIR .. "plugin.toml")
if manifestText == nil then
  -- The README documents running the harness against another copy
  -- (`lua5.4 test-panel.lua /path/to/other`), and that copy may not include
  -- `plugin.toml`: then there is no manifest to validate and the checks are
  -- skipped instead of failing.
  skip("the declared dependencies", "this copy has no plugin.toml")
else
  local declared = {}
  local block = manifestText:match("dependencies%s*=%s*%[(.-)%]")
  if block ~= nil then
    for name in block:gmatch('"([^"]+)"') do
      declared[name] = true
    end
  end

  check("the manifest declares dependencies", true, next(declared) ~= nil)
  check("declares hyprctl", true, declared["hyprctl"] == true)

  -- Every command of the default cards must be declared: the executable is
  -- the first word of the command. The list is the factory values from
  -- `lib/defaults.luau` (`base4`, the fallback used when there is no
  -- manifest): the manifest does not define commands, so it is the list of
  -- cards installed out of the box.
  for name, command in pairs(base4.commands) do
    local executable = tostring(command):match("^(%S+)")
    check(
      "the default command '" .. name .. "' is declared in dependencies",
      true,
      executable ~= nil and declared[executable] == true
    )
  end
end

-- ------------------------------------------------------------ occupied areas --

print("\n== occupied areas ==")
local clientList = {
  { address = "0xa", class = "noctalia-term-cava", x = 915, y = 840, w = 1610, h = 584, monitor = "1" },
  { address = "0xb", class = "noctalia-term-btop", x = 16, y = 16, w = 928, h = 800, monitor = "1" },
  { address = "0xc", class = "kitty", x = 0, y = 0, w = 800, h = 600, monitor = "1" },
}
local monitors = {
  ["1"] = { id = "1", name = "DP-1", x = 0, y = 0, width = 3440, height = 1440 },
}
local occupied = win.occupiedRects(clientList, monitors, "DP-1", nil)
check("counts only plugin windows", #occupied, 2)
check("the first area", occupied[1].x, 915)
check("the second area", occupied[2].y, 16)
local without = win.occupiedRects(clientList, monitors, "DP-1", "0xa")
check("excludes the window being repositioned", #without, 1)
check("the remaining one is the other", without[1].x, 16)

-- --------------------------------------------------------------- thumbnails --

print("\n== thumbnails ==")
local fs = {
  ["btop-aaa.png"] = true,
  ["btop-bbb.png"] = true,
  ["cava-ccc.png"] = true,
  ["batch-1.json"] = true,
}
mock.listDir = function()
  local names = {}
  for name in pairs(fs) do
    names[#names + 1] = name
  end
  return names
end
mock.removeFile = function(path)
  local name = path:match("([^/]+)$")
  fs[name] = nil
  return true
end
mock.fileInfo = function()
  return { size = 10, mtime = os.time() - 7200, isDir = false }
end

local used = preview.currentPaths({
  { name = "btop", x = 10, y = 20, w = 300, h = 200 },
})
local usedCount = 0
for _ in pairs(used) do
  usedCount = usedCount + 1
end
check("currentPaths returns two paths per window (frame + current)", usedCount, 2)
local framePath = nil
for path in pairs(used) do
  if path:match("btop%-v2%-[0-9a-f]+%.png$") then
    framePath = path
    break
  end
end
check("one path carries the name and signature (frame)", framePath ~= nil, true)

local fromMap = preview.currentPaths({ btop = { name = "btop", x = 10, y = 20, w = 300, h = 200 } })
local mapCount = 0
for _ in pairs(fromMap) do
  mapCount = mapCount + 1
end
check("currentPaths accepts a map", mapCount, 2)

preview.pruneUnused({ [TESTDATA .. "/thumbs/btop-aaa.png"] = true })
check("keeps the thumbnail in use", fs["btop-aaa.png"], true)
check("deletes the unused one", fs["btop-bbb.png"], nil)
check("deletes the other widget's one", fs["cava-ccc.png"], nil)
check("deletes old batches", fs["batch-1.json"], nil)

fs["btop-bbb.png"] = true
fs["btop-ccc.png"] = true
mock.fileInfo = function(path)
  local name = path:match("([^/]+)$")
  if name == "btop-ccc.png" then
    return { size = 10, mtime = os.time() - 7200, isDir = false }
  end
  return { size = 10, mtime = os.time(), isDir = false }
end
preview.pruneUnused({ [TESTDATA .. "/thumbs/btop-bbb.png"] = true }, 1800)
check("keeps the thumbnail in use", fs["btop-aaa.png"], true)
check("keeps the recent one even if unused", fs["btop-bbb.png"], true)
check("deletes the old unused one", fs["btop-ccc.png"], nil)

-- ----------------------------------------------------------------- rotation --

print("\n== rotation: permutations ==")
local function fakeWindow(name, x, y, w, h)
  return {
    address = "0x" .. name,
    class = "noctalia-term-" .. name,
    name = name,
    x = x,
    y = y,
    w = w,
    h = h,
    monitor = { id = "1", name = "DP-1", x = 0, y = 0, width = 3440, height = 1440 },
  }
end

local group = {
  fakeWindow("top-left", 16, 16, 900, 800),
  fakeWindow("top-right", 2524, 16, 900, 800),
  fakeWindow("bottom-left", 16, 624, 900, 800),
  fakeWindow("bottom-right", 2524, 624, 900, 800),
}

-- Process simulator: returns the window list when asked, records dispatched
-- expressions and completes calls immediately.
mock.runAsync = function(argv, callback)
  local command = table.concat(argv, " ")
  if command:find("hyprctl dispatch", 1, true) then
    dispatched[#dispatched + 1] = argv[3]
  end
  if command:find("hyprctl clients", 1, true) then
    if callback ~= nil then
      callback({ exitCode = 0, stdout = clientsJson(), stderr = "" })
    end
    return true
  end
  if command:find("hyprctl monitors", 1, true) then
    if callback ~= nil then
      callback({
        exitCode = 0,
        stdout = '[{"id":1,"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1}]',
        stderr = "",
      })
    end
    return true
  end
  if callback ~= nil then
    callback({ exitCode = 0, stdout = "", stderr = "" })
  end
  return true
end

local function movedTo(address)
  for _, expression in ipairs(dispatched) do
    if expression:find("address:" .. address, 1, true) then
      local mx, my = expression:match("x = (%-?%d+), y = (%-?%d+)")
      return tonumber(mx), tonumber(my)
    end
  end
  return nil, nil
end

win.rotate(group, "clockwise", false, function() end)
local mx, my = movedTo("0xtop-left")
check("clockwise: top-left takes top-right", mx, 2524)
check("clockwise: top-left takes top-right (y)", my, 16)
mx, my = movedTo("0xbottom-right")
check("clockwise: bottom-right takes bottom-left", mx, 16)
check("clockwise: bottom-right takes bottom-left (y)", my, 624)

dispatched = {}
win.rotate(group, "counterclockwise", false, function() end)
mx, my = movedTo("0xtop-left")
check("counterclockwise: top-left takes bottom-left", mx, 16)
check("counterclockwise: top-left takes bottom-left (y)", my, 624)

dispatched = {}
win.rotate(group, "pairs", false, function() end)
mx, my = movedTo("0xtop-left")
check("pairs: top-left takes top-right", mx, 2524)
check("pairs: top-left takes top-right (y)", my, 16)

dispatched = {}
win.rotate(group, "opposite", false, function() end)
mx, my = movedTo("0xtop-left")
check("opposite: top-left takes bottom-right", mx, 2524)
check("opposite: top-left takes bottom-right (y)", my, 624)

-- "opposite" rotation geometrically correct in any arrangement: a square
-- built in a single corner must rotate along diagonals.
local corner = {
  fakeWindow("c1", 10, 10, 100, 100),
  fakeWindow("c2", 10, 200, 100, 100),
  fakeWindow("c3", 200, 10, 100, 100),
  fakeWindow("c4", 200, 200, 100, 100),
}
dispatched = {}
win.rotate(corner, "opposite", false, function() end)
mx, my = movedTo("0xc1")
check("opposite in corner: c1 takes c4 (x)", mx, 200)
check("opposite in corner: c1 takes c4 (y)", my, 200)
mx, my = movedTo("0xc2")
check("opposite in corner: c2 takes c3 (x)", mx, 200)
check("opposite in corner: c2 takes c3 (y)", my, 10)

dispatched = {}
win.rotate(group, "shuffle", false, function() end)
local targets = {}
for _, expression in ipairs(dispatched) do
  local tx, ty = expression:match("x = (%-?%d+), y = (%-?%d+)")
  if tx ~= nil then
    targets[tx .. "," .. ty] = (targets[tx .. "," .. ty] or 0) + 1
  end
end
local unique = 0
for _, count in pairs(targets) do
  if count == 1 then
    unique = unique + 1
  end
end
check("random: each destination is used once", unique, #group)

local odd = {
  fakeWindow("top-left", 16, 16, 900, 800),
  fakeWindow("top-right", 2524, 16, 900, 800),
  fakeWindow("bottom-left", 16, 624, 900, 800),
}
dispatched = {}
win.rotate(odd, "pairs", false, function() end)
mx, my = movedTo("0xtop-left")
check("odd pairs: top-left takes top-right", mx, 2524)
mx, my = movedTo("0xbottom-left")
check("odd pairs: the extra one stays", mx, 16)
check("odd pairs: the extra one does not move (y)", my, 624)

dispatched = {}
win.rotate({ fakeWindow("solo", 16, 16, 900, 800) }, "clockwise", false, function() end)
check("a single window does not move", #dispatched, 0)

dispatched = {}
win.rotate(group, "clockwise", true, function() end)
local resized = false
for _, expression in ipairs(dispatched) do
  if expression:find("resize", 1, true) then
    resized = true
  end
end
check("with sizes it resizes", resized, true)

dispatched = {}
win.rotate(group, "clockwise", false, function() end)
resized = false
for _, expression in ipairs(dispatched) do
  if expression:find("resize", 1, true) then
    resized = true
  end
end
check("without sizes it does not resize", resized, false)

-- Atomic rotation lock.
win.rotating = true
local locked = win.rotate(group, "clockwise", false, function() end)
check("rotation locked while rotating", false, locked)
win.rotating = false

-- Focus without repositioning: a single focus dispatch, no resize or move.
dispatched = {}
win.focusOnly("noctalia-term-lavat", function() end)
check("focusOnly: a single dispatch", 1, #dispatched)
check("focusOnly: it is a focus", true, dispatched[1]:find("hl.dsp.focus") ~= nil)
check("focusOnly: does not resize", nil, dispatched[1]:find("resize"))
check("focusOnly: does not move", nil, dispatched[1]:find("move"))

-- ------------------------------------------------------------- lib/output.luau --

print("\n== lib/output.luau ==")

local outputLib = loadModule("output.luau")
local box = outputLib.outputBox({ output = "" })
check("outputBox: focused output box", 3440, box.width)
check("outputBox: height", 1440, box.height)
check("outputBox: name", "DP-1", box.name)
check("outputBox: origin", 0, box.x)
check("outputBox: origin y", 0, box.y)
check("outputBox: cfg.output wins", "DP-1", outputLib.outputBox({ output = "DP-1" }).name)
check("outputBox: missing cfg.output falls back to focused", "DP-1", outputLib.outputBox({ output = "HDMI-9" }).name)
-- box too small -> fallback
local savedOutputs = mock.outputs
mock.outputs = function() return { { name = "X", width = 100, height = 80, x = 0, y = 0, scale = 1, focused = true } } end
local tiny = outputLib.outputBox({ output = "" })
check("outputBox: tiny box -> 1920x1080", "1920x1080", tiny.width .. "x" .. tiny.height)
mock.outputs = savedOutputs

-- --------------------------------------------------------------- lib/brain.luau --

print("\n== lib/brain.luau ==")

local layoutLib = loadModule("layout.luau")
local brain = loadModule("brain.luau")
local SCREEN = { x = 0, y = 0, width = 3440, height = 1440, name = "DP-1" }

local function anchorOf(x, y, w, h)
  return brain.anchorFromRect({ x = x, y = y, w = w, h = h }, SCREEN, 0).anchor
end
check("anchor: bottom-left corner", "bottom-left", anchorOf(0, 800, 802, 582))
check("anchor: top-right corner", "top-right", anchorOf(2400, 0, 802, 582))
check("anchor: exact center", "center", anchorOf(1319, 429, 802, 582))
check("anchor: left band, center row", "left-center", anchorOf(10, 429, 802, 582))
check("anchor: right band, center row", "right-center", anchorOf(2600, 429, 802, 582))
check("anchor: center band, top row", "top-center", anchorOf(1319, 10, 802, 582))
check("anchor: center band, bottom row", "bottom-center", anchorOf(1319, 800, 802, 582))
-- remaining corners
check("anchor: top-left", "top-left", anchorOf(0, 0, 802, 582))
check("anchor: bottom-right", "bottom-right", anchorOf(2600, 800, 802, 582))

-- round trip: rebuilding returns the exact position (relative to the box)
local function roundTrip(rect, screen, margin)
  local memory = brain.anchorFromRect(rect, screen, margin)
  local baseX, baseY = layoutLib.anchorPosition(memory.anchor, memory.width, memory.height, screen.width, screen.height, margin)
  return (baseX + memory.dx) .. "," .. (baseY + memory.dy)
end
check("round trip: bottom-left", "0,800", roundTrip({ x = 0, y = 800, w = 802, h = 582 }, SCREEN, 0))
check("round trip: center", "1319,429", roundTrip({ x = 1319, y = 429, w = 802, h = 582 }, SCREEN, 0))
check("round trip: with margin 24", "24,24", roundTrip({ x = 24, y = 24, w = 802, h = 582 }, SCREEN, 24))
-- box with a shifted origin (second monitor): the offset is relative to the box
local OFFSET = { x = 1920, y = 0, width = 1920, height = 1080, name = "DP-2" }
check("round trip: shifted box", "0,0", roundTrip({ x = 1920, y = 0, w = 600, h = 400 }, OFFSET, 0))

check("layoutString: exact format", "bottom-left, 802x582, 0, -58", brain.layoutString({ x = 0, y = 800, w = 802, h = 582 }, SCREEN, 0))
-- positive offset: window 100 px from the left edge and level with the bottom base
local shifted = brain.anchorFromRect({ x = 100, y = 800, w = 802, h = 582 }, SCREEN, 0)
check("layoutString: offset in x", 100, shifted.dx)
check("layoutString: offset in y", -58, shifted.dy)
check("layoutString: string with offset", "bottom-left, 802x582, 100, -58", brain.layoutString({ x = 100, y = 800, w = 802, h = 582 }, SCREEN, 0))
check("geometryFromMemory: rebuilds", 800, (brain.geometryFromMemory("bottom-left, 802x582, 0, -58", 3440, 1440, 0) or {}).y)
check("geometryFromMemory: width", 802, (brain.geometryFromMemory("bottom-left, 802x582, 0, -58", 3440, 1440, 0) or {}).width)
check("geometryFromMemory: invalid string", nil, brain.geometryFromMemory("not a layout", 3440, 1440, 0))
check("geometryFromMemory: nil", nil, brain.geometryFromMemory(nil, 3440, 1440, 0))

-- Raw `hyprctl clients -j` client: `at` and `size` are positional arrays.
local function clientAt(class, x, y, w, h)
  return { class = class, at = { x, y }, size = { w, h }, address = "0x" .. x, monitor = 0 }
end

-- poll 1: nothing memorized, pending entry created
local rect = { x = 0, y = 800, w = 802, h = 582 }
local r1 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, {}, {})
check("capture: first poll does not memorize", nil, r1.memory["noctalia-term-lavat"])
check("capture: first poll leaves pending", 800, (r1.pending["noctalia-term-lavat"] or {}).y)
check("capture: first poll without changes", false, r1.changed)

-- identical poll 2: memorizes
local r2 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, {}, r1.pending)
check("capture: second poll memorizes", "bottom-left, 802x582, 0, -58", r2.memory["noctalia-term-lavat"])
check("capture: second poll marks a change", true, r2.changed)

-- different rect: resets the pending entry and does not memorize
local r3 = brain.capture({ clientAt("noctalia-term-lavat", 0, 700, 802, 582) }, SCREEN, 0, {}, {}, r2.pending)
check("capture: different rect does not memorize", nil, r3.memory["noctalia-term-lavat"])
check("capture: different rect resets pending", 700, (r3.pending["noctalia-term-lavat"] or {}).y)

-- recent matching imposition: suppresses and cancels the pending entry
clock = 10000
local imposed = { ["noctalia-term-lavat"] = { x = 0, y = 800, w = 802, h = 582, at = 9000 } }
local r4 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, imposed, r1.pending)
check("capture: recent imposition does not memorize", nil, r4.memory["noctalia-term-lavat"])
check("capture: imposition cancels pending", nil, r4.pending["noctalia-term-lavat"])
check("capture: imposition does not mark a change", false, r4.changed)

-- expired imposition: now counts as manual
local old = { ["noctalia-term-lavat"] = { x = 0, y = 800, w = 802, h = 582, at = 1000 } }
local r5 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, old, r1.pending)
check("capture: expired imposition memorizes", "bottom-left, 802x582, 0, -58", r5.memory["noctalia-term-lavat"])

-- windows not belonging to the plugin
local r6 = brain.capture({ clientAt("kitty", 0, 0, 100, 100) }, SCREEN, 0, {}, {}, {})
local foreign = 0
for _ in pairs(r6.pending) do foreign = foreign + 1 end
check("capture: ignores foreign windows", 0, foreign)

-- closed window: its pending entry disappears
local r7 = brain.capture({}, SCREEN, 0, {}, {}, r1.pending)
check("capture: closed window clears pending", nil, r7.pending["noctalia-term-lavat"])

-- no change from previous memory: does not mark a change
local prev = { ["noctalia-term-lavat"] = "bottom-left, 802x582, 0, -58" }
local r8 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, prev, {}, r1.pending)
check("capture: same memory does not mark a change", false, r8.changed)

-- -------------------------------------------------------------------- panel --

print("\n== panel ==")

-- The panel is loaded with the simulated UI. If it uses a global that does
-- not exist (a `local` declared further down, for example), it breaks here.
--
-- The panel caches the store in memory from its first open: a known store
-- (brain off and no memory) is left on disk so the section always starts in
-- the same state.
files[storePath] = '{"commands":{},"layouts":{},"thumbs":{},"removed":{},"brain":false,"brainGeometry":{}}'
local panelChunk, panelErr = loadfile(DIR .. "panel.luau", "t", env)
if not panelChunk then
  print("  FAIL could not load panel.luau: " .. tostring(panelErr))
  os.exit(1)
end
local loaded, loadErr = pcall(panelChunk)
check("panel loads without errors", true, loaded == true)
if not loaded then
  print("  " .. tostring(loadErr))
  os.exit(1)
end

-- Count nodes in the rendered tree.
local function countKeys(tree, prefix)
  local total = 0
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and type(node.props.key) == "string" then
      if node.props.key:sub(1, #prefix) == prefix then
        total = total + 1
      end
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return total
end

local function findNode(tree, key)
  local found = nil
  local function walk(node)
    if found ~= nil or type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and node.props.key == key then
      found = node
      return
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return found
end

local function findByPrefix(tree, prefix)
  local found = nil
  local function walk(node)
    if found ~= nil or type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and type(node.props.key) == "string"
      and node.props.key:sub(1, #prefix) == prefix then
      found = node
      return
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return found
end

-- Test widgets: those from the plugin's own manifest.
config.commands = {}
config.layouts = {}
local manifestDefaults = defaults.load()
for name, command in pairs(manifestDefaults.commands) do
  config.commands[name] = command
end
for name, position in pairs(manifestDefaults.layouts) do
  config.layouts[name] = position
end
local widgetCount = 0
for _ in pairs(config.commands) do
  widgetCount = widgetCount + 1
end

-- For the simulator to run the capture path (and with it thumbnail pruning),
-- the tools must be available: `preview.toolsAvailable()` checks the capture
-- script.
files[(DIR:gsub("/+$", "")) .. "/bin/snapshot.py"] = "#!/usr/bin/env python3\n"

-- Regression: pruning must not delete the file a card is drawing. With the
-- widget closed the card shows its "current" thumbnail, and if pruning
-- deletes it the host warns "image failed to load" and it goes black.
fs["cava-v2-current.png"] = true
mock.fileInfo = function(path)
  local name = path:match("([^/]+)$")
  if name == "cava-v2-current.png" or name == "btop-ccc.png" then
    return { size = 10, mtime = os.time() - 7200, isDir = false }
  end
  return { size = 10, mtime = os.time(), isDir = false }
end

env.onOpen("")
check("panel opens and renders", true, rendered > 0)
check("one card per widget", widgetCount, countKeys(lastTree, "card-"))
check("pruning does not delete the thumbnail being drawn", true, fs["cava-v2-current.png"])

-- The manifest is parsed once, but it is re-read when the panel opens: if the
-- .toml changes at runtime and there is no user config, the new defaults are used.
local manifestFixture = files[DIR .. "plugin.toml"]
files[DIR .. "plugin.toml"] = [==[
[[setting]]
key = "commands"
default = { new = "a-command --new" }
]==]
-- Simulate the user having no config in Settings (empty config)
local oldConfig = config
config = {}
defaults.reset()
env.onOpen("")
local freshCard = findNode(lastTree, "card-new")
check(
  "opening re-reads the manifest (no user config)",
  true,
  freshCard ~= nil and tostring(freshCard.props.tooltip):find("a-command --new", 1, true) ~= nil
)
files[DIR .. "plugin.toml"] = manifestFixture
config = oldConfig
defaults.reset()
env.onOpen("")
check("header has the open-all button", true, findNode(lastTree, "open-all") ~= nil)
check("header has the rotate button", true, findNode(lastTree, "rotate") ~= nil)
check("header has the close-all button", true, findNode(lastTree, "close-all") ~= nil)
check("header has the edit button", true, findNode(lastTree, "edit") ~= nil)
check("header has the settings button", true, findNode(lastTree, "open-settings") ~= nil)
check("header has the close button", true, findNode(lastTree, "close-panel") ~= nil)

local cardNode = findNode(lastTree, "card-" .. (config.commands and "btop" or "btop"))
if cardNode == nil then
  -- The first card is found by alphabetical order.
  local names = {}
  for name in pairs(config.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  cardNode = findNode(lastTree, "card-" .. names[1])
end
check("card has the command in the tooltip", true, cardNode ~= nil and cardNode.props.tooltip ~= nil and cardNode.props.tooltip:len() > 0)
check("card is clickable", true, cardNode ~= nil and cardNode.props.onClick ~= nil)
check("card has fixed width (uniform size)", true, cardNode ~= nil and cardNode.props.width ~= nil)
check("card does not grow in partial rows", nil, cardNode ~= nil and cardNode.props.flexGrow)

-- Edit mode: the form and delete buttons appear.
local editButton = findNode(lastTree, "edit")
check("edit button has a handler", true, editButton ~= nil and editButton.props.onClick ~= nil)
if editButton ~= nil and editButton.props.onClick ~= nil then
  editButton.props.onClick()
  check("form appears in edit mode", true, findNode(lastTree, "editor") ~= nil)
  check("there is a delete button in edit mode", true, countKeys(lastTree, "delete-") > 0)

  -- An existing widget's editor is placed where its card is.
  local firstName = nil
  do
    local names = {}
    for name in pairs(config.commands) do
      names[#names + 1] = name
    end
    table.sort(names)
    firstName = names[1]
  end
  local editWidget = findByPrefix(lastTree, "edit-" .. firstName)
  check("card has an edit button", true, editWidget ~= nil)
  if editWidget ~= nil and editWidget.props.onClick ~= nil then
    editWidget.props.onClick()
    check("editor replaces the edited card", nil, findNode(lastTree, "card-" .. firstName))
    check("editor stays visible while editing", true, findNode(lastTree, "editor") ~= nil)
    local thumbField = findByPrefix(lastTree, "form-thumb-")
    check(
      "thumbnail field starts empty",
      "",
      thumbField ~= nil and thumbField.props.value or "sin campo"
    )
    local headerEdit = findNode(lastTree, "edit")
    if headerEdit ~= nil and headerEdit.props.onClick ~= nil then
      headerEdit.props.onClick()
    end
    check("canceling restores the card", true, findNode(lastTree, "card-" .. firstName) ~= nil)

    -- Renaming to another existing widget is rejected (the other one is not overwritten).
    local names = {}
    for name in pairs(config.commands) do
      names[#names + 1] = name
    end
    table.sort(names)
    if names[2] ~= nil then
      editWidget.props.onClick()
      local nameField = findByPrefix(lastTree, "form-name-")
      local saveButton = findByPrefix(lastTree, "editor-save-")
      if nameField ~= nil and saveButton ~= nil then
        nameField.props.onChange(names[2])
        saveButton.props.onClick()
        check(
          "renaming to an existing widget is rejected",
          "name_exists",
          notifications[#notifications] ~= nil and notifications[#notifications].body or "sin aviso"
        )
        if headerEdit ~= nil and headerEdit.props.onClick ~= nil then
          headerEdit.props.onClick()
        end
      end
    end
  end
end

-- IPC handlers must not break.
local before = rendered
env.onIpc("refresh", "")
check("IPC refresh does not fail", true, rendered >= before)
env.onIpc("rotate", "")
check("IPC rotate does not fail", true, true)
env.onIpc("open-all", "")
check("IPC open-all does not fail", true, true)
env.onIpc("close-all", "")
check("IPC close-all does not fail", true, true)
env.onIpc("add", "test|echo hello|center, 500x300")
check("IPC add does not fail", true, true)
env.onIpc("remove", "test")
check("IPC remove does not fail", true, true)
env.onIpc("launch", "cava")
check("IPC launch does not fail", true, true)

-- ------------------------------------------------------------- the grid --

-- Count the card rows in the rendered tree.
local function cardRows(tree)
  local rows = 0
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    local isRow = false
    for _, child in ipairs(node.children or {}) do
      if type(child) == "table" and type(child.props) == "table"
        and type(child.props.key) == "string" and child.props.key:sub(1, 5) == "card-" then
        isRow = true
      end
    end
    if isRow then
      rows = rows + 1
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return rows
end

env.onOpen("")
config.columns = 2
env.onIpc("refresh", "")
check("2-column grid: 6 widgets = 3 rows", 3, cardRows(lastTree))
config.columns = 3
env.onIpc("refresh", "")
check("3-column grid: 6 widgets = 2 rows", 2, cardRows(lastTree))
config.columns = 1
env.onIpc("refresh", "")
check("1-column grid: 6 widgets = 6 rows", 6, cardRows(lastTree))
config.columns = 2
env.onIpc("refresh", "")

-- ------------------------------------------------- launch and reposition --

local function dispatchText()
  return table.concat(dispatched, "\n")
end

local function clickCard(name)
  local node = findNode(lastTree, "card-" .. name)
  if node ~= nil and node.props.onClick ~= nil then
    node.props.onClick()
  end
end

-- The debounce ignores a second click right after.
clock = clock + 5000
dispatched = {}
clickCard("btop")
local firstLaunch = dispatchText():find("noctalia%-term%-btop") ~= nil
dispatched = {}
clickCard("btop")
check("clicking a card launches its widget", true, firstLaunch)
check("a second click right after does not launch another window", false, dispatchText():find("exec_cmd") ~= nil)

clock = clock + 5000
dispatched = {}
clickCard("btop")
check("after the debounce it launches again", true, dispatchText():find("exec_cmd") ~= nil)
check("the window is placed at its configured position", true, dispatchText():find("move%({ x = 16, y = 16") ~= nil)

-- If the widget is already open, clicking it again must return it to its
-- place (not a random slot): collision avoidance must not count itself.
-- In "custom" mode it must return to its configured position.
config.fallback_mode = "custom"
clients = {
  { address = "0x1", class = "noctalia-term-btop", x = 2000, y = 900, w = 928, h = 800, monitor = "1" },
}
env.onOpen("")
clock = clock + 5000
dispatched = {}
clickCard("btop")
check("an already-open widget returns to its position", true, dispatchText():find("move%({ x = 16, y = 16") ~= nil)
check("and no second window is launched", true, dispatchText():find("exec_cmd") == nil)
check("close button on an open widget", true, (function()
    local closeBtn = findNode(lastTree, "close-btop")
    return closeBtn ~= nil and closeBtn.props and closeBtn.props.onClick ~= nil
  end)())
clients = {}

-- ---------------------------------------------- brain and geometry --

print("\n== brain ==")

-- Margin is set to 0 so the expected positions are exact (the default
-- margin, 16 px, shifts each anchor's base).
local savedMarginPanel = config.margin
config.margin = 0
env.onOpen("")

-- The button is first in its row: left of "open all".
local brainButton = findNode(lastTree, "brain")
check("panel: the brain button exists", true, brainButton ~= nil)
check("panel: brain glyph", "brain", brainButton ~= nil and brainButton.props.glyph or nil)
check("panel: ghost variant", "ghost", brainButton ~= nil and brainButton.props.variant or nil)
check("panel: starts off", false, brainButton ~= nil and brainButton.props.selected == true)
check("panel: off tooltip", "brain_off", brainButton ~= nil and brainButton.props.tooltip or nil)

-- Order of the rendered tree keys (keys live in `props.key`; `nodeKeys`
-- above is for raw trees).
local function keyOrder(tree, out)
  out = out or {}
  if type(tree) ~= "table" then return out end
  if type(tree.props) == "table" and tree.props.key ~= nil then
    table.insert(out, tree.props.key)
  end
  for _, child in ipairs(tree.children or {}) do keyOrder(child, out) end
  return out
end

local brainKeys = keyOrder(lastTree)
local brainIndex, openAllIndex
for index, key in ipairs(brainKeys) do
  if key == "brain" then brainIndex = index end
  if key == "open-all" then openAllIndex = index end
end
check("panel: brain is left of open-all", true,
  brainIndex ~= nil and openAllIndex ~= nil and brainIndex < openAllIndex)

-- Clicking it turns it on, repaints and persists.
if brainButton ~= nil and brainButton.props.onClick ~= nil then
  brainButton.props.onClick()
end
check("panel: turns the brain on", true, storeLib.loadBrain().brain == true)
local brainOn = findNode(lastTree, "brain")
check("panel: marked when turned on", true, brainOn ~= nil and brainOn.props.selected == true)
check("panel: on tooltip", "brain_on", brainOn ~= nil and brainOn.props.tooltip or nil)

-- Turning it off does not erase the memory.
storeLib.saveBrainGeometry({ ["noctalia-term-brain"] = "center, 10x10" })
env.onOpen("")
local brainOffButton = findNode(lastTree, "brain")
if brainOffButton ~= nil and brainOffButton.props.onClick ~= nil then
  brainOffButton.props.onClick()
end
check("panel: turns the brain off", false, storeLib.loadBrain().brain)
check("panel: turning it off does not erase memory", "center, 10x10",
  storeLib.loadBrain().brainGeometry["noctalia-term-brain"])

-- Both keys exist in both languages.
for _, lang in ipairs({ "en", "es" }) do
  local raw = readRealFile(DIR .. "translations/" .. lang .. ".json")
  check("translations " .. lang .. ": brain_on", true, raw ~= nil and raw:find('"brain_on"') ~= nil)
  check("translations " .. lang .. ": brain_off", true, raw ~= nil and raw:find('"brain_off"') ~= nil)
end

-- Test widget with an official layout and different memory.
env.onIpc("remove", "brain")
env.onIpc("add", "brain|brain --demo|bottom-left, 802x582")
storeLib.saveBrainToggle(false)
storeLib.saveBrainGeometry({ ["noctalia-term-brain"] = "top-right, 400x300, -10, 10" })
env.onOpen("")

-- Brain OFF: the official layout wins (the usual behavior).
clients = {
  { class = "noctalia-term-brain", at = { 100, 100 }, size = { 600, 400 }, address = "0x77", monitor = 0 },
}
clock = clock + 5000
dispatched = {}
clickCard("brain")
local offText = dispatchText()
check("without brain: resize to the layout size", true, offText:find("resize%({ x = 802, y = 582") ~= nil)
check("without brain: returns to its anchor", true, offText:find("move%({ x = 0, y = 858") ~= nil)

-- What the plugin imposes is published so the service does not memorize it.
local published = mock.state.get("imposed") or {}
local imposedEntry = published["noctalia-term-brain"]
check("imposed: publishes the class", true, imposedEntry ~= nil)
check("imposed: layout width", 802, imposedEntry ~= nil and imposedEntry.w or nil)
check("imposed: absolute position", 858, imposedEntry ~= nil and imposedEntry.y or nil)
check("imposed: carries a timestamp", true,
  imposedEntry ~= nil and (imposedEntry.at or 0) > 0)

-- Expired entries are pruned when publishing the next geometry.
mock.state.set("imposed", { ["noctalia-term-vieja"] = { x = 0, y = 0, w = 10, h = 10, at = 1 } })
clock = clock + 5000
clickCard("brain")
check("imposed: prunes expired ones", nil, (mock.state.get("imposed") or {})["noctalia-term-vieja"])

-- Brain ON and already open: focus only, no repositioning.
storeLib.saveBrainToggle(true)
env.onOpen("")
clients = {
  { class = "noctalia-term-brain", at = { 100, 100 }, size = { 600, 400 }, address = "0x77", monitor = 0 },
}
clock = clock + 5000
dispatched = {}
clickCard("brain")
check("with brain and open: a single dispatch", 1, #dispatched)
check("with brain and open: it is a focus", true,
  dispatched[1] ~= nil and dispatched[1]:find("hl.dsp.focus") ~= nil)
check("with brain and open: does not resize", nil,
  dispatched[1] ~= nil and dispatched[1]:find("resize") or nil)

-- Brain ON and closed: opening uses the memory.
clients = {}
clock = clock + 5000
dispatched = {}
clickCard("brain")
local onText = dispatched[1] or ""
check("with brain: opens with the remembered size", true, onText:find("size = { 400, 300") ~= nil)
check("with brain: opens at the remembered position", true, onText:find("move = { 3030, 10") ~= nil)

-- Saving a layout in the form clears the widget memory.
storeLib.saveBrainGeometry({ ["noctalia-term-brain"] = "top-right, 400x300, -10, 10" })
env.onIpc("add", "brain|brain --demo|center, 500x400")
check("form: clears the widget memory", nil,
  storeLib.loadBrain().brainGeometry["noctalia-term-brain"])

-- O5: leaving edit mode saves the geometry the user moved.
local function enterEditMode()
  local node = findNode(lastTree, "edit")
  if node ~= nil and node.props.onClick ~= nil then node.props.onClick() end
end

storeLib.saveBrainToggle(false)
env.onIpc("add", "brain|brain --demo|bottom-left, 802x582")
env.onOpen("")
clients = {}
clock = clock + 5000
clickCard("brain")  -- places the window and records what the plugin imposes

-- A window that stays where the plugin put it does not touch the layout.
clients = {
  { class = "noctalia-term-brain", at = { 0, 858 }, size = { 802, 582 }, address = "0x77", monitor = 0 },
}
enterEditMode()
enterEditMode()
check("O5: does not touch a still window", "bottom-left, 802x582", storeLib.load().layouts.brain)

-- A window moved by hand is saved as a permanent layout.
clients = {
  { class = "noctalia-term-brain", at = { 0, 0 }, size = { 700, 400 }, address = "0x77", monitor = 0 },
}
enterEditMode()
enterEditMode()
check("O5: saves the moved geometry", "top-left, 700x400, 0, 0", storeLib.load().layouts.brain)

-- And it works the same with brain ON.
storeLib.saveBrainToggle(true)
env.onOpen("")
clients = {}
env.onIpc("add", "brain|brain --demo|bottom-left, 802x582")
clock = clock + 5000
clickCard("brain")
clients = {
  { class = "noctalia-term-brain", at = { 0, 0 }, size = { 700, 400 }, address = "0x77", monitor = 0 },
}
enterEditMode()
enterEditMode()
check("O5: also saves with brain ON", "top-left, 700x400, 0, 0", storeLib.load().layouts.brain)

-- A layout written in the form wins over live geometry.
storeLib.saveBrainToggle(false)
env.onOpen("")
clients = {}
env.onIpc("add", "brain|brain --demo|bottom-left, 802x582")
clock = clock + 5000
clickCard("brain")
clients = {
  { class = "noctalia-term-brain", at = { 0, 0 }, size = { 700, 400 }, address = "0x77", monitor = 0 },
}
enterEditMode()
env.onIpc("add", "brain|brain --demo|bottom-center, 600x300")
enterEditMode()
check("O5: the form wins", "bottom-center, 600x300", storeLib.load().layouts.brain)

-- O4: the add editor goes after the last card.
clients = {}
env.onOpen("")
enterEditMode()
local editOrder = keyOrder(lastTree)
local lastCardIndex, addEditorIndex = nil, nil
for index, key in ipairs(editOrder) do
  if key:sub(1, 5) == "card-" then lastCardIndex = index end
  if key == "editor" then addEditorIndex = index end
end
check("edit: there is more than one card", true, countKeys(lastTree, "card-") > 1)
check("edit: the add editor goes last", true,
  addEditorIndex ~= nil and lastCardIndex ~= nil and addEditorIndex > lastCardIndex)
enterEditMode()  -- leave edit mode

config.margin = savedMarginPanel

-- ------------------------------------------------- delete from the panel --

env.onOpen("")
local editButton2 = findNode(lastTree, "edit")
if editButton2 ~= nil and editButton2.props.onClick ~= nil then
  editButton2.props.onClick()
end
local deleteButton = findNode(lastTree, "delete-btop")
check("there is a delete button per card", true, deleteButton ~= nil)
if deleteButton ~= nil and deleteButton.props.onClick ~= nil then
  deleteButton.props.onClick()
end
check("after deleting, the card disappears", false, findNode(lastTree, "card-btop") ~= nil)
check("and the widget is no longer in the list", false, (lastTree ~= nil) and findNode(lastTree, "card-btop") ~= nil)

-- ------------------------------------------- fallback: layout and random --

-- A widget's layout is respected when opening it (direction and size), but
-- when it is already open and its thumbnail is clicked in "random" mode, it
-- moves to a free slot keeping its current size.
config.fallback_mode = "random"
config.fallback_random_resize = false
clients = {}
env.onIpc("add", "loose|echo hello|")
env.onIpc("add", "anchored|echo hello|top-left, 928x800")
env.onOpen("")

-- "loose" has no layout: it opens in a free slot with the fallback size.
-- respaldo.
clock = clock + 5000
dispatched = {}
clickCard("loose")
local spawnText = dispatchText()
local openedSize = spawnText:match("size = { (%d+, %d+) }")
check("a widget without layout opens with the fallback size", "900, 520", openedSize)
check("and at a free position (not the fallback one)", false, spawnText:find("move = { 120, 140") ~= nil)

-- "anchored" has a layout: its direction and size are respected when opening.
clock = clock + 5000
dispatched = {}
clickCard("anchored")
local anchoredText = dispatchText()
check("a widget with layout opens at its position", true, anchoredText:find("move = { 16, 16") ~= nil)
check("with its defined size", true, anchoredText:find("size = { 928, 800") ~= nil)

-- If it is already open and clicked again, random mode repositions it to a
-- free slot, but keeps its current size (not the layout size).
clients = {
  { address = "0x1", class = "noctalia-term-anchored", x = 2000, y = 900, w = 600, h = 400, monitor = "1" },
}
env.onOpen("")
clock = clock + 5000
dispatched = {}
clickCard("anchored")
local movedText = dispatchText()
check("an open widget is repositioned in random mode", false, movedText:find("move = { 16, 16") ~= nil)
check("and keeps its current size", true, movedText:find("resize%({ x = 600, y = 400") ~= nil)

-- With "change size too" active, the size is also randomized.
config.fallback_random_resize = true
env.onOpen("")
clock = clock + 5000
dispatched = {}
clickCard("anchored")
local resizedText = dispatchText()
local randomSize = resizedText:match("resize%({ x = (%d+), y = (%d+)")
local sameSize = resizedText:find("resize%({ x = 600, y = 400") ~= nil
check("with resize active the size is randomized again", false, sameSize)
check("and the random size is within range", true, randomSize ~= nil)

config.fallback_random_resize = false
config.fallback_mode = "custom"
clients = {}


-- ------------------------------------------------------------- frame ticks --

print("\n== frame ticks ==")

-- The host only delivers `onFrameTick` when requested with
-- `panel.setNeedsFrameTick(true)`. In automatic mode closed cards animate
-- their captures, so they must request ticks: without them the animation
-- freezes on the first frame.
local frameTicks = {}
panelMock.setNeedsFrameTick = function(value)
  frameTicks[#frameTicks + 1] = value
end

-- A widget with two captures and no open window. The widget list lives in
-- the store, so it is added through IPC (the plugin's real path). The
-- captures existed before: the frame list is cached, and the simulator clock
-- does not advance.
fs["anim-1.png"] = true
fs["anim-2.png"] = true
local frameReads = 0
local previousFileInfo = mock.fileInfo
mock.fileInfo = function(path)
  local name = path:match("([^/]+)$")
  -- Each re-read of the frame list calls `fileInfo` once per frame: counting
  -- these calls shows how many times the disk was re-read for this widget.
  if name:match("^anim%-") then
    frameReads = frameReads + 1
  end
  -- Different mtimes: frame order does not depend on the `table.sort`
  -- tie-break (which is not stable).
  if name == "anim-1.png" then
    return { size = 10, mtime = os.time() - 10, isDir = false }
  end
  if name == "anim-2.png" then
    return { size = 10, mtime = os.time(), isDir = false }
  end
  return previousFileInfo(path)
end

-- The tick cases need to know exactly which widgets exist: those left by
-- previous sections are cleared.
local function cardNames()
  local names = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and type(node.props.key) == "string"
      and node.props.key:sub(1, 5) == "card-" then
      names[#names + 1] = node.props.key:sub(6)
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(lastTree)
  return names
end
for _, name in ipairs(cardNames()) do
  env.onIpc("remove", name)
end

frameTicks = {}
env.onOpen("")
check("without cards no frame ticks are requested", false, frameTicks[#frameTicks])

-- A card with a single capture has nothing to animate: there are no frames
-- to alternate, so requesting ticks would be an empty loop.
fs["uno-1.png"] = true
env.onIpc("add", "uno|uno|center, 500x300")
check("a card with a single capture does not request frame ticks", false, frameTicks[#frameTicks])

env.onIpc("add", "anim|anim|center, 500x300")

frameTicks = {}
env.onOpen("")
local lastTick = frameTicks[#frameTicks]
check("in auto mode with captures, frame ticks are requested", true, lastTick == true)

-- The image a card draws (to see which frame is shown).
local function cardImage(name)
  local card = findNode(lastTree, "card-" .. name)
  if card == nil then
    return nil
  end
  local found = nil
  local function walk(node)
    if found ~= nil or type(node) ~= "table" then
      return
    end
    if node.type == "image" and type(node.props) == "table" and node.props.path ~= nil then
      found = node.props.path
      return
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(card)
  return found
end

local frameBefore = cardImage("anim")
check("the card with captures draws a frame", true, frameBefore ~= nil)
env.onFrameTick(300)
local frameAfter = cardImage("anim")
check(
  "the closed card animation advances",
  true,
  frameAfter ~= nil and frameBefore ~= nil and frameAfter ~= frameBefore
)

-- Ticks must not re-read the disk every frame: the frame list is re-read
-- only when it is time to advance (every 250 ms). With 60 ticks of 16 ms
-- (almost a second) there are at most four 250 ms windows, so disk reads
-- tend to be a few, not one per tick.
--
-- The simulator clock advances on each tick on purpose: otherwise the
-- one-second cache in `preview.frames` would hide the reads being counted.
frameReads = 0
for _ = 1, 60 do
  clock = clock + 1000
  env.onFrameTick(16)
end
check(
  "ticks do not re-read the disk every frame",
  true,
  frameReads <= 24
)

-- When a card is deleted its entry in the animations table is garbage: if
-- it stays, the panel would keep requesting ticks for something that no longer exists.
env.onIpc("remove", "anim")
check("deleting an animated card turns off frame ticks", false, frameTicks[#frameTicks])
env.onIpc("remove", "one")
check("deleting the last card turns off frame ticks", false, frameTicks[#frameTicks])

-- In mock mode there is nothing to animate: ticks are turned off.
config.card_preview = "mock"
frameTicks = {}
env.onOpen("")
check("in mock mode no frame ticks are requested", false, frameTicks[#frameTicks])
config.card_preview = "auto"
mock.fileInfo = previousFileInfo

-- ------------------------------------------------------- recent frames --

print("\n== recent frames ==")

-- The panel stores eight captures per widget and uses them to animate the
-- card when its window is closed. On the ninth it discards the oldest and
-- deletes its file. If the UI tree still points to that file, the host
-- requests it again when reopening the panel and warns "image failed to load"
-- because the file no longer exists: a file in use cannot be deleted until
-- the tree stops using it.

-- `snapshot.py` does not run in the simulator, so the mock creates the
-- thumbnail files. The capture is left *pending* so a capture arriving with
-- the window already closed can be simulated: that is exactly when the tree
-- stays pointing to a file the plugin is going to delete.
--
-- The simulator's `removeFile` deletes from the thumbnail section table;
-- here the same disk used to create the capture files matters.
local previousRemoveFile = mock.removeFile
mock.removeFile = function(path)
  files[path] = nil
  return true
end

local pendingCapture = nil
local capturedFrames = {}

local previousRunAsync = mock.runAsync
mock.runAsync = function(argv, callback)
  if type(argv) == "table" and argv[1] == "python3" then
    local batchPath = argv[3]
    pendingCapture = function()
      pendingCapture = nil
      local raw = files[batchPath]
      if raw ~= nil then
        -- Paths are read from the batch text: the text is enough, there is
        -- no need to decode the batch JSON.
        for out in raw:gmatch('"out":"([^"]*)"') do
          files[out] = true
          capturedFrames[#capturedFrames + 1] = out
        end
        for current in raw:gmatch('"current_out":"([^"]*)"') do
          files[current] = true
        end
      end
      if callback ~= nil then
        callback({ exitCode = 0, stdout = "", stderr = "" })
      end
    end
    return true
  end
  return previousRunAsync(argv, callback)
end

local function finishCapture()
  local pending = pendingCapture
  pendingCapture = nil
  if pending ~= nil then
    pending()
  end
end

-- Previous sections leave stray cards: they are deleted so the capture
-- count belongs only to this section's widget.
for _, name in ipairs(cardNames()) do
  env.onIpc("remove", name)
end
env.onIpc("add", "marco|echo hello|")

clients = {
  { address = "0x1", class = "noctalia-term-marco", x = 100, y = 100, w = 600, h = 400, monitor = "1" },
}
env.onOpen("")

-- Eight captures: the frame list reaches the cap.
for _ = 1, 8 do
  finishCapture()
  clock = clock + 4000
  env.update()
end
check("the widget stores eight captures", 8, #capturedFrames)

-- The window closes with the ninth capture in progress: the card starts
-- animating the saved frames and the tree marks them as in use.
clients = {}
env.onIpc("refresh", "")

-- The ninth capture arrives: the list goes over eight and the oldest one is
-- discarded, which the tree is using.
finishCapture()
check("the widget stores nine captures", 9, #capturedFrames)
local oldestFrame = capturedFrames[1]
check(
  "the frame the tree uses is not deleted when discarded",
  true,
  files[oldestFrame] ~= nil
)

-- When the tree stops using it, the discarded file is deleted.
clock = clock + 4000
env.update()
clock = clock + 4000
env.update()
check(
  "the discarded frame is deleted when the tree stops using it",
  true,
  files[oldestFrame] == nil
)

mock.runAsync = previousRunAsync
mock.removeFile = previousRemoveFile
clients = {}

-- ------------------------------------------------------------- service.luau --

print("\n== service.luau ==")

-- The service uses its own environment (own globals) with the same `noctalia`.
local service = {}
setmetatable(service, { __index = env })
local chunk = assert(loadfile(DIR .. "service.luau", "t", service))
chunk()
check("service: exports update", "function", type(service.update))
-- the getConfig mock must return margin = 0 so the expectations are exact
check("service: 1 s poll interval", true, serviceUpdatedMs == 1000)

-- The memorized string depends on the configured margin: it is set to 0 so
-- the expected values below are exact (restored on exit).
local savedMargin = config.margin
config.margin = 0

local callsBefore = #dispatched
files[storePath] = '{"commands":{},"brain":false,"brainGeometry":{}}'
service.update()
check("service: brain OFF does not query hyprctl", callsBefore, #dispatched)
check("service: brain OFF does not write memory", nil, storeLib.load().brainGeometry["noctalia-term-lavat"])

-- brain ON: two ticks with the same window memorize
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{}}'
clients = { { class = "noctalia-term-lavat", at = { 0, 800 }, size = { 802, 582 }, address = "0x1", monitor = 0 } }
service.update()
service.update()
check("service: brain ON memorizes after two ticks", "bottom-left, 802x582, 0, -58", storeLib.load().brainGeometry["noctalia-term-lavat"])
clients = {}

-- brain ON and recent imposed rect: does not memorize
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{}}'
mock.state.set("imposed", { ["noctalia-term-lavat"] = { x = 0, y = 800, w = 802, h = 582, at = clock } })
clients = { { class = "noctalia-term-lavat", at = { 0, 800 }, size = { 802, 582 }, address = "0x1", monitor = 0 } }
service.update()
service.update()
check("service: respects imposed suppression", nil, storeLib.load().brainGeometry["noctalia-term-lavat"])
mock.state.set("imposed", {})
clients = {}

-- if runAsync does not start, polling must not stay blocked
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{}}'
local realRunAsync = mock.runAsync
mock.runAsync = function() return false end
service.update()
mock.runAsync = realRunAsync
clients = { { class = "noctalia-term-lavat", at = { 0, 800 }, size = { 802, 582 }, address = "0x1", monitor = 0 } }
service.update()
service.update()
check("service: failed runAsync does not block polling", "bottom-left, 802x582, 0, -58", storeLib.load().brainGeometry["noctalia-term-lavat"])
clients = {}

config.margin = savedMargin

print(string.format("\n%d checks, %d failures", PASSED + FAILED, FAILED))
os.exit(FAILED == 0 and 0 or 1)
