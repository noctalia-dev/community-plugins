--!nonstrict
-- Shares Noctalia's settings.toml between devices, one setting at a time.
--
-- Settings.merge(mine, theirs, base) compares each setting in three versions: this device's
-- settings.toml, the other devices' shared settings, and the shared settings this device last
-- agreed on. Any of them may be "". It returns:
-- - shared: the new shared settings, as TOML text;
-- - localText: the settings of <mine> that stay on this device;
-- - settings: this device's new settings.toml, or nil when nothing was taken;
-- - taken: how many settings came from the other devices;
-- - count: how many settings are shared.
-- It raises an error when a file holds TOML it does not know, so a setting is never lost.
--
-- A setting is a leaf: its path, the keys joined by dots, and its value as TOML text on one
-- line, written the same way whatever file it came from. A setting only another device
-- changed is taken; otherwise this device's value stays. The list of enabled plugins is
-- merged item by item. Settings tied to the hardware are never shared: brightness and
-- battery, any table named after a monitor or placed on one (except the wallpaper's), and
-- Resurrect's own settings, so another device never changes what this one writes. Plugin sources that are folders on this device stay
-- too. A setting shared for the first time takes the value already shared, so the device
-- that shared it first wins.
--
-- Settings.breathe is called between lines; the service sets it to pause the save when the
-- callback's time is used up.

local Settings = {}
Settings.breathe = function() end

local RESURRECT = 'plugin_settings."omerfuyar/resurrect"'
local MONITOR_NAMES = { "eDP", "DP", "HDMI", "DVI", "VGA", "LVDS", "DSI" }
local MONITOR_VALUES = { "eDP", "DP", "HDMI", "DVI", "VGA", "LVDS", "DSI", "Virtual", "HEADLESS", "USB" }
local ESCAPE = { b = "\\u0008", t = "\\u0009", n = "\\u000a", f = "\\u000c", r = "\\u000d" }

-- Where each path sits, the same in every file: parent, key as written, name, depth, and the
-- name of its first key.
local meta = {}

local function fail(message)
  error("settings: " .. message, 0)
end

-- Whether <text> is a connector name such as "DP-1" or "HDMI-A-1", from <names>.
local function isConnector(text, names)
  local prefix, rest = text:match("^(%a+)(%-.+)$")
  if prefix == nil or not table.find(names, prefix) then
    return false
  end
  return rest:match("^%-%u%-%d+$") ~= nil or rest:match("^%-%d+$") ~= nil
end

-- Whether a table's name holds a monitor's name, such as "DP-1" or "bar@HDMI-A-1": a
-- connector between the name's ends or the characters @ : _ . -
local function namesMonitor(name)
  for start = 1, #name do
    if start == 1 or name:sub(start - 1, start - 1):match("[@:_.%-]") then
      for _, prefix in ipairs(MONITOR_NAMES) do
        if name:sub(start, start + #prefix - 1) == prefix then
          local rest = name:sub(start + #prefix)
          for _, pattern in ipairs({ "^%-%u%-%d+", "^%-%d+" }) do
            local suffix = rest:match(pattern) or ""
            local after = rest:sub(#suffix + 1, #suffix + 1)
            if suffix ~= "" and (after == "" or after:match("[@:_.%-]")) then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

-- Reading. A reader is { text, at, size }.

local function where(r)
  local _, lines = r.text:sub(1, r.at):gsub("\n", "")
  return "line " .. (lines + 1)
end

local function skipSpace(r)
  r.at = r.text:find("[^ \t]", r.at) or r.size + 1
end

-- Skips spaces, line ends and comments.
local function skipBlank(r)
  while true do
    r.at = r.text:find("[^ \t\r\n]", r.at) or r.size + 1
    if r.text:sub(r.at, r.at) ~= "#" then
      return
    end
    r.at = r.text:find("\n", r.at, true) or r.size + 1
  end
end

-- Ends a line: only a comment may follow.
local function lineEnd(r)
  skipSpace(r)
  if r.text:sub(r.at, r.at) == "#" then
    r.at = r.text:find("\n", r.at, true) or r.size + 1
  end
  if r.text:sub(r.at, r.at) == "\r" then
    r.at += 1
  end
  if r.at <= r.size and r.text:sub(r.at, r.at) ~= "\n" then
    fail("unexpected text at " .. where(r))
  end
  r.at += 1
end

local function expect(r, token)
  if r.text:sub(r.at, r.at + #token - 1) ~= token then
    fail("expected " .. token .. " at " .. where(r))
  end
  r.at += #token
end

-- Text as a basic string holds it: control characters, quotes and backslashes escaped.
local function plain(text)
  return (text:gsub('[%z\1-\31\127"\\]', function(c)
    if c == '"' or c == "\\" then
      return "\\" .. c
    end
    return string.format("\\u%04x", string.byte(c))
  end))
end

local function readBasic(r)
  local many = r.text:sub(r.at, r.at + 2) == '"""'
  if many then
    r.at += 3
    if r.text:sub(r.at, r.at) == "\n" then
      r.at += 1
    elseif r.text:sub(r.at, r.at + 1) == "\r\n" then
      r.at += 2
    end
  else
    r.at += 1
  end
  local parts = {}
  while true do
    local stop = r.text:find(many and '["\\]' or '["\\\n]', r.at)
    if stop == nil then
      fail("a string does not end")
    end
    table.insert(parts, plain(r.text:sub(r.at, stop - 1)))
    local c = r.text:sub(stop, stop)
    r.at = stop
    if c == "\n" then
      fail("a string does not end at " .. where(r))
    elseif c == '"' then
      if not many then
        r.at += 1
        return table.concat(parts)
      elseif r.text:sub(stop, stop + 2) == '"""' then
        r.at += 3
        return table.concat(parts)
      end
      table.insert(parts, '\\"')
      r.at += 1
    else
      local e = r.text:sub(stop + 1, stop + 1)
      if e == '"' or e == "\\" then
        table.insert(parts, "\\" .. e)
        r.at += 2
      elseif ESCAPE[e] then
        table.insert(parts, ESCAPE[e])
        r.at += 2
      elseif e == "u" then
        table.insert(parts, "\\u" .. r.text:sub(stop + 2, stop + 5):lower())
        r.at += 6
      elseif e == "U" then
        table.insert(parts, "\\U" .. r.text:sub(stop + 2, stop + 9):lower())
        r.at += 10
      elseif many and e:match("[ \t\r\n]") then
        fail("a line-ending backslash at " .. where(r))
      else
        fail("unknown escape at " .. where(r))
      end
    end
  end
end

local function readLiteral(r)
  local many = r.text:sub(r.at, r.at + 2) == "'''"
  local close = many and "'''" or "'"
  if many then
    r.at += 3
    if r.text:sub(r.at, r.at) == "\n" then
      r.at += 1
    elseif r.text:sub(r.at, r.at + 1) == "\r\n" then
      r.at += 2
    end
  else
    r.at += 1
  end
  local stop = r.text:find(close, r.at, true)
  if stop == nil then
    fail("a string does not end")
  end
  local text = r.text:sub(r.at, stop - 1)
  if not many and text:find("\n", 1, true) then
    fail("a string does not end at " .. where(r))
  end
  r.at = stop + #close
  return plain(text)
end

-- A key as it is written in the output: bare when it can be, else quoted.
local function keyText(name)
  return name:match("^[%w_%-]+$") and name or '"' .. name .. '"'
end

-- Reads one key; returns it as written and its name.
local function readKey(r)
  local c = r.text:sub(r.at, r.at)
  local name
  if c == '"' then
    name = readBasic(r)
  elseif c == "'" then
    name = readLiteral(r)
  else
    name = r.text:match("^[%w_%-]+", r.at)
    if name == nil then
      fail("expected a key at " .. where(r))
    end
    r.at += #name
  end
  return keyText(name), name
end

-- Reads a dotted key, relative to <table>; returns it. With <record>, each path it names is
-- recorded in meta.
local function readPath(r, tableName, record)
  local relative, path = "", tableName
  skipSpace(r)
  while true do
    local key, name = readKey(r)
    relative = relative == "" and key or relative .. "." .. key
    if record then
      local parent = path
      path = path == "" and key or path .. "." .. key
      if meta[path] == nil then
        local up = meta[parent]
        meta[path] = {
          parent = parent,
          key = key,
          name = name,
          depth = (up and up.depth or 0) + 1,
          first = parent == "" and name or up.first,
        }
      end
    end
    skipSpace(r)
    if r.text:sub(r.at, r.at) ~= "." then
      return relative
    end
    r.at += 1
    skipSpace(r)
  end
end

local function isNumber(word)
  if word:match("^0x[%x_]+$") or word:match("^0o[0-7_]+$") or word:match("^0b[01_]+$")
    or word:match("^[-+]?inf$") or word:match("^[-+]?nan$") then
    return true
  end
  local rest = word:gsub("^[-+]", "", 1)
  local int = rest:match("^0") or rest:match("^[1-9][%d_]*")
  if int == nil then
    return false
  end
  rest = rest:sub(#int + 1)
  local fraction = rest:match("^%.%d[%d_]*")
  if fraction then
    rest = rest:sub(#fraction + 1)
  end
  local exponent = rest:match("^[eE][-+]?%d[%d_]*")
  if exponent then
    rest = rest:sub(#exponent + 1)
  end
  return rest == ""
end

local function isFloat(word)
  if word:match("^0[xob]") then
    return false
  end
  return word:find("[.eE]") ~= nil or word:match("^[-+]?inf$") ~= nil or word:match("^[-+]?nan$") ~= nil
end

local readValue

local function readList(r)
  r.at += 1
  local items = {}
  while true do
    skipBlank(r)
    if r.text:sub(r.at, r.at) == "]" then
      r.at += 1
      return "[" .. table.concat(items, ", ") .. "]"
    end
    table.insert(items, readValue(r))
    skipBlank(r)
    local c = r.text:sub(r.at, r.at)
    if c == "," then
      r.at += 1
    elseif c ~= "]" then
      fail("expected , or ] at " .. where(r))
    end
  end
end

local function readInline(r)
  r.at += 1
  local items = {}
  while true do
    skipBlank(r)
    if r.text:sub(r.at, r.at) == "}" then
      r.at += 1
      return #items == 0 and "{}" or "{ " .. table.concat(items, ", ") .. " }"
    end
    local key = readPath(r, "", false)
    expect(r, "=")
    table.insert(items, key .. " = " .. readValue(r))
    skipBlank(r)
    local c = r.text:sub(r.at, r.at)
    if c == "," then
      r.at += 1
    elseif c ~= "}" then
      fail("expected , or } at " .. where(r))
    end
  end
end

-- Reads a value and returns it as the output writes it.
readValue = function(r)
  skipSpace(r)
  local c = r.text:sub(r.at, r.at)
  if c == '"' then
    return '"' .. readBasic(r) .. '"'
  elseif c == "'" then
    return '"' .. readLiteral(r) .. '"'
  elseif c == "[" then
    return readList(r)
  elseif c == "{" then
    return readInline(r)
  end
  local word = r.text:match("^[%w_.:+%-]*", r.at)
  r.at += #word
  if word == "true" or word == "false" or isNumber(word) then
    return word
  end
  fail("unknown value " .. word .. " at " .. where(r))
  return ""
end

-- A parsed file: values by path, paths in order, and the tables that hold a monitor's name.
local function newFile()
  return { values = {}, leaves = {}, hasMonitor = {} }
end

local leaf

-- Splits an inline table into its leaves, as a table is.
local function splitInline(file, path, value)
  local r = { text = value, at = 2, size = #value }
  while true do
    skipSpace(r)
    if r.text:sub(r.at, r.at) == "}" or r.at > r.size then
      return
    end
    local key = readPath(r, path, true)
    expect(r, "=")
    leaf(file, path .. "." .. key, readValue(r))
    skipSpace(r)
    if r.text:sub(r.at, r.at) == "," then
      r.at += 1
    end
  end
end

leaf = function(file, path, value)
  if value:sub(1, 1) == "{" then
    splitInline(file, path, value)
    return
  end
  if file.values[path] ~= nil then
    fail("setting " .. path .. " is there twice")
  end
  file.values[path] = value
  table.insert(file.leaves, path)
  -- A table with a monitor's name as a value belongs to this device.
  if value:sub(1, 1) == '"' and isConnector(value:sub(2, -2), MONITOR_VALUES) then
    file.hasMonitor[meta[path].parent] = true
  end
end

local function itemText(item)
  return #item == 0 and "{}" or "{ " .. table.concat(item, ", ") .. " }"
end

-- Reads TOML text into a file.
local function parse(text)
  local file = newFile()
  local r = { text = text or "", at = 1, size = #(text or "") }
  local tableName, list, item = "", nil, nil
  local lists, listOrder = {}, {}
  local function closeItem()
    if item then
      table.insert(lists[list], itemText(item))
      item = nil
    end
  end
  while true do
    Settings.breathe()
    skipBlank(r)
    if r.at > r.size then
      break
    end
    if r.text:sub(r.at, r.at + 1) == "[[" then
      closeItem()
      r.at += 2
      list = readPath(r, "", true)
      expect(r, "]]")
      lineEnd(r)
      if lists[list] == nil then
        lists[list] = {}
        table.insert(listOrder, list)
      end
      item = {}
    elseif r.text:sub(r.at, r.at) == "[" then
      closeItem()
      list = nil
      r.at += 1
      tableName = readPath(r, "", true)
      expect(r, "]")
      lineEnd(r)
    elseif item then
      local key = readPath(r, "", false)
      expect(r, "=")
      table.insert(item, key .. " = " .. readValue(r))
      lineEnd(r)
    else
      local key = readPath(r, tableName, true)
      expect(r, "=")
      leaf(file, tableName == "" and key or tableName .. "." .. key, readValue(r))
      lineEnd(r)
    end
  end
  closeItem()
  -- Each list of tables is one leaf, a list of inline tables.
  for _, name in ipairs(listOrder) do
    leaf(file, name, "[" .. table.concat(lists[name], ", ") .. "]")
  end
  return file
end

-- Comparing.

-- The tokens of a value.
local function tokens(text)
  local out, at, size = {}, 1, #text
  while at <= size do
    local c = text:sub(at, at)
    if c == " " then
      at += 1
    elseif c:match("[%[%]{},=]") then
      table.insert(out, c)
      at += 1
    elseif c == '"' then
      local start = at
      at += 1
      while at <= size and text:sub(at, at) ~= '"' do
        at += text:sub(at, at) == "\\" and 2 or 1
      end
      at += 1
      table.insert(out, text:sub(start, at - 1))
    else
      local word = text:match("^[^%[%]{},= ]+", at)
      table.insert(out, word)
      at += #word
    end
  end
  return out
end

local function number(word)
  return tonumber((word:gsub("_", ""))) or 0
end

-- Two floats are the same when they are close: Noctalia stores widget positions as floats.
local function closeFloats(a, b)
  if not isNumber(a) or not isNumber(b) or not isFloat(a) or not isFloat(b) then
    return false
  end
  if a:find("inf") or a:find("nan") or b:find("inf") or b:find("nan") then
    return false
  end
  local x, y = number(a), number(b)
  return math.abs(x - y) <= 1e-6 * math.max(math.abs(x), math.abs(y))
end

local function same(a, b)
  if a == b then
    return true
  end
  local ta, tb = tokens(a), tokens(b)
  if #ta ~= #tb then
    return false
  end
  for i = 1, #ta do
    if ta[i] ~= tb[i] and not closeFloats(ta[i], tb[i]) then
      return false
    end
  end
  return true
end

-- The items of a list value.
local function items(text)
  local out = {}
  if text:sub(1, 1) ~= "[" or #text < 3 then
    return out
  end
  local depth, quoted, start, at = 0, false, 2, 2
  local size = #text - 1
  while at <= size do
    local c = text:sub(at, at)
    if quoted then
      if c == "\\" then
        at += 1
      elseif c == '"' then
        quoted = false
      end
    elseif c == '"' then
      quoted = true
    elseif c == "[" or c == "{" then
      depth += 1
    elseif c == "]" or c == "}" then
      depth -= 1
    elseif c == "," and depth == 0 then
      table.insert(out, noctalia.string.trim(text:sub(start, at - 1)))
      start = at + 1
    end
    at += 1
  end
  table.insert(out, noctalia.string.trim(text:sub(start, size)))
  return out
end

local function join(list)
  return "[" .. table.concat(list, ", ") .. "]"
end

-- Sharing.

-- Whether a table holds settings of this device only, in <file>.
local function isLocal(file, tableName)
  file.localTable = file.localTable or {}
  local known = file.localTable[tableName]
  if known ~= nil then
    return known
  end
  local m = meta[tableName]
  local result
  if tableName == "" then
    result = file.hasMonitor[""] == true
  elseif isLocal(file, m.parent) then
    result = true
  elseif m.depth == 1 and (m.name == "brightness" or m.name == "battery") then
    result = true
  elseif m.first == "wallpaper" then
    result = false
  else
    result = namesMonitor(m.name) or file.hasMonitor[tableName] == true
  end
  file.localTable[tableName] = result
  return result
end

local function isFolderSource(item)
  return item:match('^{ kind = "path"[,}%s]') ~= nil or item:find(', kind = "path"[,%s}]') ~= nil
end

-- Puts each leaf of <file> in file.shared or in file.localValues.
local function classify(file)
  file.shared, file.localValues = {}, {}
  for _, path in ipairs(file.leaves) do
    Settings.breathe()
    local value = file.values[path]
    local m = meta[path]
    if isLocal(file, m.parent) or m.parent == RESURRECT then
      file.localValues[path] = value
    elseif path == "plugins.source" and value:sub(1, 1) == "[" then
      -- Plugin sources that are folders on this device stay here.
      local shared, kept = {}, {}
      for _, item in ipairs(items(value)) do
        table.insert(isFolderSource(item) and kept or shared, item)
      end
      file.shared[path] = join(shared)
      if #kept > 0 then
        file.localValues[path] = join(kept)
      end
    else
      file.shared[path] = value
    end
  end
end

-- Whether a setting is the same in two files; missing in both counts as the same.
local function agree(a, b, path)
  local x, y = a.shared[path], b.shared[path]
  if x == nil or y == nil then
    return x == nil and y == nil
  end
  return same(x, y)
end

-- Plugins enabled on either side are in, those turned off on either side are out.
local function mergeList(mine, theirs, base, path)
  local m, t, b = items(mine.shared[path] or ""), items(theirs.shared[path] or ""), items(base.shared[path] or "")
  local removed = {}
  for _, item in ipairs(b) do
    if not table.find(m, item) or not table.find(t, item) then
      removed[item] = true
    end
  end
  local out = {}
  for _, item in ipairs(t) do
    if not removed[item] then
      table.insert(out, item)
    end
  end
  for _, item in ipairs(m) do
    if not removed[item] and not table.find(out, item) then
      table.insert(out, item)
    end
  end
  return join(out)
end

local function sameItems(a, b)
  local x, y = items(a), items(b)
  if #x ~= #y then
    return false
  end
  for _, item in ipairs(x) do
    if not table.find(y, item) then
      return false
    end
  end
  for _, item in ipairs(y) do
    if not table.find(x, item) then
      return false
    end
  end
  return true
end

-- Writing.

-- TOML text for <values>, a path -> value map, each table's leaves under its header.
local function dump(values)
  local paths = {}
  for path in pairs(values) do
    table.insert(paths, path)
  end
  -- Leaves sort by table, then by key, so each table's leaves stay together.
  table.sort(paths, function(a, b)
    local pa, pb = meta[a].parent, meta[b].parent
    if pa ~= pb then
      return pa < pb
    end
    return meta[a].key < meta[b].key
  end)
  local out, current = {}, nil
  for _, path in ipairs(paths) do
    Settings.breathe()
    local m = meta[path]
    if current ~= m.parent then
      current = m.parent
      if current ~= "" then
        table.insert(out, (#out == 0 and "" or "\n") .. "[" .. current .. "]\n")
      end
    end
    table.insert(out, m.key .. " = " .. values[path] .. "\n")
  end
  return table.concat(out)
end

local function count(values)
  local n = 0
  for _ in pairs(values) do
    n += 1
  end
  return n
end

-- Whether <values> are exactly the leaves of <file>.
local function sameLeaves(values, file)
  if count(values) ~= #file.leaves then
    return false
  end
  for path, value in pairs(values) do
    Settings.breathe()
    if file.values[path] == nil or not same(value, file.values[path]) then
      return false
    end
  end
  return true
end

-- <values> as TOML, read back to make sure it holds exactly them.
local function written(values)
  local text = dump(values)
  if not sameLeaves(values, parse(text)) then
    fail("the written settings do not read back the same")
  end
  return text
end

function Settings.merge(mineText, theirsText, baseText)
  local mine, theirs, base = parse(mineText), parse(theirsText), parse(baseText)
  classify(mine)
  classify(theirs)
  classify(base)

  local merged, taken, seen = {}, 0, {}
  for _, file in ipairs({ mine, theirs, base }) do
    for _, path in ipairs(file.leaves) do
      if file.shared[path] ~= nil and not seen[path] then
        Settings.breathe()
        seen[path] = true
        local value
        if path == "plugins.enabled" then
          value = mergeList(mine, theirs, base, path)
          -- The same plugins in another order are not a change: this device's order stays.
          if mine.shared[path] ~= nil and sameItems(value, mine.shared[path]) then
            value = mine.shared[path]
          else
            taken += 1
          end
        elseif base.shared[path] == nil and theirs.shared[path] ~= nil and not agree(mine, theirs, path) then
          -- Shared for the first time here: the value another device shared first wins.
          value = theirs.shared[path]
          taken += 1
        elseif agree(mine, theirs, path) or agree(theirs, base, path) or not agree(mine, base, path) then
          value = mine.shared[path]
        else
          value = theirs.shared[path]
          taken += 1
        end
        merged[path] = value
      end
    end
  end

  Settings.breathe()
  local shared = written(merged)
  Settings.breathe()
  local localText = written(mine.localValues)

  local settings = nil
  if taken > 0 then
    -- This device's new settings: the merged ones, and those that stay here.
    local result = table.clone(merged)
    for path, value in pairs(mine.localValues) do
      if path == "plugins.source" and merged[path] ~= nil and merged[path] ~= "[]" then
        result[path] = merged[path]:sub(1, -2) .. ", " .. value:sub(2)
      else
        result[path] = value
      end
    end
    if not sameLeaves(result, mine) then
      Settings.breathe()
      settings = written(result)
    end
  end
  return { shared = shared, localText = localText, settings = settings, taken = taken, count = count(merged) }
end

return Settings
