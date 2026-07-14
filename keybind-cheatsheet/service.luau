--!nonstrict
-- Cache-first keybind data service for Mango, Hyprland, and Niri.
--
-- The active configuration is parsed once during script startup and only
-- again after a relevant settings change or explicit refresh request. There
-- is no update interval, filesystem watcher, polling loop, or persistent
-- subprocess.

local noctalia = noctalia
if noctalia == nil then
  local host = require("./tests/host_mock")
  noctalia = host.noctalia
end

local SNAPSHOT_KEY = "keybind-cheatsheet.snapshot"
local REFRESH_REQUEST_KEY = "keybind-cheatsheet.refresh-request"
local SELF_TEST_REQUEST_KEY = "keybind-cheatsheet.self-test-request"
local MAX_PARSE_DEPTH = 32
local MAX_PARSE_FILES = 256
local BINDINGS_CACHE_FILE = "bindings-cache.json"
local CACHE_SCHEMA = 1

local refreshing = false
local refreshQueued = false
local refreshGeneration = 0
local lastGood = nil

local function tr(key, values)
  return noctalia.tr(key, values)
end

local function trim(value)
  local result = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return result
end

local function lower(value)
  return string.lower(value or "")
end

local function startsWith(value, prefix)
  return value:sub(1, #prefix) == prefix
end

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" or trim(value) == "" then
    return fallback
  end
  return trim(value)
end

local function pathDirname(path)
  local clean = (path or ""):gsub("/+$", "")
  local parent = clean:match("^(.*)/[^/]*$")
  if parent == nil or parent == "" then
    return clean:sub(1, 1) == "/" and "/" or "."
  end
  return parent
end

local function pathJoin(base, child)
  if child == nil or child == "" then
    return base
  end
  if child:sub(1, 1) == "/" then
    return child
  end
  if base == "/" then
    return "/" .. child
  end
  return (base:gsub("/+$", "")) .. "/" .. child
end

local function normalizePath(path)
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        table.remove(parts)
      elseif not absolute then
        table.insert(parts, part)
      end
    elseif part ~= "." and part ~= "" then
      table.insert(parts, part)
    end
  end
  local result = table.concat(parts, "/")
  if absolute then
    result = "/" .. result
  end
  if result == "" then
    return absolute and "/" or "."
  end
  return result
end

local function expandEnvironment(path)
  local expanded = path:gsub("%${([%w_]+)}", function(name)
    return noctalia.getenv(name) or "${" .. name .. "}"
  end)
  expanded = expanded:gsub("%$HOME", noctalia.getenv("HOME") or "~")
  return noctalia.expandPath(expanded)
end

local function unquote(value)
  local result = trim(value)
  if #result >= 2 then
    local first = result:sub(1, 1)
    local last = result:sub(-1)
    if (first == "\"" and last == "\"") or (first == "'" and last == "'") then
      result = result:sub(2, -2)
    end
  end
  return result
end

local function resolvePath(value, includingFile)
  local path = expandEnvironment(unquote(value))
  if path:sub(1, 1) ~= "/" then
    path = pathJoin(pathDirname(includingFile), path)
  end
  return normalizePath(path)
end

local function hasGlob(path)
  return path:find("*", 1, true) ~= nil
    or path:find("?", 1, true) ~= nil
    or path:find("[", 1, true) ~= nil
end

local LUA_PATTERN_MAGIC = {
  ["^"] = true,
  ["$"] = true,
  ["("] = true,
  [")"] = true,
  ["%"] = true,
  ["."] = true,
  ["+"] = true,
  ["-"] = true,
  ["]"] = true,
}

local function globPattern(segment)
  local result = { "^" }
  local index = 1
  while index <= #segment do
    local char = segment:sub(index, index)
    if char == "*" then
      table.insert(result, ".*")
    elseif char == "?" then
      table.insert(result, ".")
    elseif char == "[" then
      local closing = segment:find("]", index + 1, true)
      if closing ~= nil then
        table.insert(result, segment:sub(index, closing))
        index = closing
      else
        table.insert(result, "%[")
      end
    elseif LUA_PATTERN_MAGIC[char] then
      table.insert(result, "%" .. char)
    else
      table.insert(result, char)
    end
    index += 1
  end
  table.insert(result, "$")
  return table.concat(result)
end

local function expandGlob(path, context)
  if not hasGlob(path) then
    -- Read explicit paths directly. A separate existence check can race with
    -- atomic Home Manager symlink replacement and suppress a readable file.
    return { path }
  end

  local candidates = { path:sub(1, 1) == "/" and "/" or "." }
  for segment in path:gmatch("[^/]+") do
    local nextCandidates = {}
    if hasGlob(segment) then
      local pattern = globPattern(segment)
      for _, base in ipairs(candidates) do
        local entries = noctalia.listDir(base)
        if entries ~= nil then
          table.sort(entries)
          for _, name in ipairs(entries) do
            if name:match(pattern) then
              table.insert(nextCandidates, normalizePath(pathJoin(base, name)))
            end
          end
        end
      end
    else
      for _, base in ipairs(candidates) do
        table.insert(nextCandidates, normalizePath(pathJoin(base, segment)))
      end
    end
    candidates = nextCandidates
  end

  local files = {}
  for _, candidate in ipairs(candidates) do
    local info = noctalia.fileInfo(candidate)
    if info ~= nil and not info.isDir then
      table.insert(files, candidate)
    end
  end
  table.sort(files)
  if context ~= nil and hasGlob(path) then
    local snapshot = {}
    for _, file in ipairs(files) do table.insert(snapshot, file) end
    table.insert(context.globs, { pattern = path, files = snapshot })
  end
  return files
end

local function extractTrailingDescription(line)
  local ending = line:sub(-1)
  local startIndex, description
  if ending == "\"" then
    startIndex, _, description = line:find("#%s*\"([^\"]*)\"%s*$")
  elseif ending == "'" then
    startIndex, _, description = line:find("#%s*'([^']*)'%s*$")
  end
  if startIndex == nil then
    return line, ""
  end
  return trim(line:sub(1, startIndex - 1)), trim(description)
end

local function splitCsv(value, maximumParts)
  if value:find("\"", 1, true) == nil and value:find("'", 1, true) == nil
    and value:find("\\", 1, true) == nil then
    local parts = {}
    local startIndex = 1
    while maximumParts == nil or #parts < maximumParts - 1 do
      local comma = value:find(",", startIndex, true)
      if comma == nil then break end
      table.insert(parts, trim(value:sub(startIndex, comma - 1)))
      startIndex = comma + 1
    end
    table.insert(parts, trim(value:sub(startIndex)))
    return parts
  end

  local parts = {}
  local current = {}
  local quote = nil
  local escaped = false
  local index = 1
  while index <= #value do
    local char = value:sub(index, index)
    if escaped then
      table.insert(current, char)
      escaped = false
    elseif char == "\\" and quote ~= nil then
      table.insert(current, char)
      escaped = true
    elseif quote ~= nil then
      table.insert(current, char)
      if char == quote then
        quote = nil
      end
    elseif char == "\"" or char == "'" then
      quote = char
      table.insert(current, char)
    elseif char == "," and (maximumParts == nil or #parts < maximumParts - 1) then
      table.insert(parts, trim(table.concat(current)))
      current = {}
    else
      table.insert(current, char)
    end
    index += 1
  end
  table.insert(parts, trim(table.concat(current)))
  return parts
end

local MODIFIER_ORDER = { "SUPER", "CTRL", "SHIFT", "ALT", "MOD2", "MOD3", "MOD5" }
local KNOWN_MODIFIERS = { SUPER = true, CTRL = true, SHIFT = true, ALT = true, MOD2 = true, MOD3 = true, MOD5 = true }
local MODIFIER_ALIASES = {
  LOGO = "SUPER",
  WIN = "SUPER",
  MOD4 = "SUPER",
  CONTROL = "CTRL",
  MOD1 = "ALT",
}

local function expandHyprVariables(value, variables)
  local previous = value
  for _ = 1, 8 do
    local expanded = previous:gsub("%$([%w_]+)", function(name)
      return variables[name] or "$" .. name
    end)
    if expanded == previous then
      break
    end
    previous = expanded
  end
  return previous
end

local function normalizeModifiers(value, variables)
  local raw = expandHyprVariables(value or "", variables or {})
  raw = raw:gsub("%+", " "):gsub("|", " "):gsub(",", " ")
  local present = {}
  local unknown = {}
  for token in raw:gmatch("[^%s]+") do
    local upper = string.upper(token)
    upper = MODIFIER_ALIASES[upper] or upper
    if upper ~= "NONE" and upper ~= "" then
      if KNOWN_MODIFIERS[upper] then
        present[upper] = true
      elseif not present[upper] then
        present[upper] = true
        table.insert(unknown, upper)
      end
    end
  end
  local result = {}
  for _, name in ipairs(MODIFIER_ORDER) do
    if present[name] then
      table.insert(result, name)
    end
  end
  for _, name in ipairs(unknown) do
    table.insert(result, name)
  end
  return result
end

local function bindingIdentity(binding)
  return table.concat({
    binding.compositor or "",
    binding.bindingType or "",
    table.concat(binding.modifiers or {}, "+"),
    binding.key or "",
    binding.action or "",
    binding.submap or "",
  }, "|")
end

local function addBinding(target, binding)
  binding.description = trim(binding.description)
  binding.category = trim(binding.category)
  binding.baseCategory = binding.category
  binding.action = trim(binding.action)
  binding.key = trim(binding.key)
  binding.modifiers = binding.modifiers or {}
  binding.id = bindingIdentity(binding)
  table.insert(target, binding)
end

local CATEGORY_SMALL_WORDS = {
  ["and"] = true,
  ["for"] = true,
  of = true,
  the = true,
  to = true,
}

local function mangoCategoryFromComment(line)
  if not startsWith(line, "#") or startsWith(line, "#\"") or startsWith(line, "#'") then
    return nil
  end
  local heading = trim(line:gsub("^#+%s*", ""))
  if heading == "" or heading:match("^[%-%=_*]+$") ~= nil then return nil end

  local explicit = heading:match("^[Cc]ategory%s*:%s*(.+)$")
  if explicit ~= nil then return trim(explicit) end
  heading = trim(heading:gsub("^%d+%.%s*", ""))

  if #heading > 64 or lower(heading):match("^bind%s*=") ~= nil then return nil end
  if heading:find("=", 1, true) ~= nil or heading:find(":", 1, true) ~= nil
    or heading:find(" + ", 1, true) ~= nil then return nil end

  local wordCount = 0
  for token in heading:gmatch("%S+") do
    wordCount += 1
    local word = token:gsub("^[^%a]+", ""):gsub("[^%a]+$", "")
    local lowered = lower(word)
    if word ~= "" and not CATEGORY_SMALL_WORDS[lowered]
      and word:sub(1, 1) ~= string.upper(word:sub(1, 1)) then
      return nil
    end
  end
  if wordCount == 0 or wordCount > 7 then return nil end
  return heading
end

local function parseMangoContent(content, sourceFile, context)
  local hasBindings = content:find("bind", 1, true) ~= nil
  local hasSources = content:find("source", 1, true) ~= nil
  if not hasBindings and not hasSources then return {} end

  local category = ""
  local includes = {}
  local lineNumber = 0
  for rawLine in (content .. "\n"):gmatch("(.-)\r?\n") do
    lineNumber += 1
    local line = trim(rawLine)
    if line ~= "" then
      if startsWith(line, "source") then
        local optionalPath = line:match("^source%-optional%s*=%s*(.-)%s*$")
        local sourcePath = line:match("^source%s*=%s*(.-)%s*$")
        if optionalPath ~= nil then
          table.insert(includes, { path = optionalPath, optional = true })
        elseif sourcePath ~= nil then
          table.insert(includes, { path = expandHyprVariables(sourcePath, context.variables), optional = false })
        end
      elseif startsWith(line, "#") then
        if hasBindings then
          local heading = mangoCategoryFromComment(line)
          if heading ~= nil then category = heading end
        end
      elseif hasBindings and line:find("bind", 1, true) ~= nil then
        local clean, description = extractTrailingDescription(line)
        local directive, body = clean:match("^([%a]*bind)%s*=%s*(.*)$")
        if directive ~= nil then
          directive = lower(directive)
          local maximum = directive == "gesturebind" and 5 or (directive == "switchbind" and 3 or 4)
          local fields = splitCsv(body, maximum)
          local modifiers = {}
          local key = ""
          local command = ""
          local parameters = ""
          if directive == "switchbind" then
            key = fields[1] or ""
            command = fields[2] or ""
            parameters = fields[3] or ""
          elseif directive == "gesturebind" then
            modifiers = normalizeModifiers(fields[1], {})
            key = (fields[3] or "") .. "-finger " .. (fields[2] or "")
            command = fields[4] or ""
            parameters = fields[5] or ""
          else
            modifiers = normalizeModifiers(fields[1], {})
            key = fields[2] or ""
            command = fields[3] or ""
            parameters = fields[4] or ""
          end
          if key ~= "" and command ~= "" then
            addBinding(context.bindings, {
              compositor = "mango",
              bindingType = directive,
              modifiers = modifiers,
              key = key,
              action = trim(command .. " " .. parameters),
              description = description,
              category = category,
              sourceFile = sourceFile,
              sourceLine = lineNumber,
            })
          end
        end
      end
    end
  end
  return includes
end

local function parseHyprContent(content, sourceFile, context)
  local category = ""
  local includes = {}
  local lineNumber = 0
  for rawLine in (content .. "\n"):gmatch("(.-)\r?\n") do
    lineNumber += 1
    local line = trim(rawLine)
    if line ~= "" then
      local variable, value = line:match("^%$([%w_]+)%s*=%s*(.-)%s*$")
      local sourcePath = line:match("^source%s*=%s*(.-)%s*$")
      local numberedCategory = line:match("^#%s*%d+%.%s*(.-)%s*$")
      if variable ~= nil then
        context.variables[variable] = value
      elseif sourcePath ~= nil then
        table.insert(includes, { path = expandHyprVariables(sourcePath, context.variables), optional = false })
      elseif numberedCategory ~= nil and numberedCategory ~= "" then
        category = numberedCategory
      else
        local clean, description = extractTrailingDescription(line)
        local directive, body = clean:match("^(bind[%a]*)%s*=%s*(.*)$")
        if directive ~= nil then
          local fields = splitCsv(body, 4)
          local key = fields[2] or ""
          local dispatcher = fields[3] or ""
          if key ~= "" and dispatcher ~= "" then
            addBinding(context.bindings, {
              compositor = "hyprland",
              bindingType = lower(directive),
              modifiers = normalizeModifiers(fields[1], context.variables),
              key = key,
              action = trim(dispatcher .. " " .. (fields[4] or "")),
              description = description,
              category = category,
              sourceFile = sourceFile,
              sourceLine = lineNumber,
            })
          end
        end
      end
    end
  end
  return includes
end

local function niriTokens(content)
  local tokens = {}
  local index = 1
  local line = 1
  while index <= #content do
    local char = content:sub(index, index)
    local nextChar = content:sub(index + 1, index + 1)
    if char == "\n" then
      line += 1
      index += 1
    elseif char:match("%s") then
      index += 1
    elseif char == "/" and nextChar == "/" then
      local ending = content:find("\n", index + 2, true) or (#content + 1)
      table.insert(tokens, { type = "comment", value = content:sub(index + 2, ending - 1), line = line })
      index = ending
    elseif char == "/" and nextChar == "*" then
      local ending = content:find("*/", index + 2, true) or (#content - 1)
      local value = content:sub(index + 2, ending - 1)
      table.insert(tokens, { type = "comment", value = value, line = line })
      local _, newlines = value:gsub("\n", "")
      line += newlines
      index = ending + 2
    elseif char == "\"" then
      local startLine = line
      local value = {}
      index += 1
      local escaped = false
      while index <= #content do
        local stringChar = content:sub(index, index)
        if escaped then
          local replacements = { n = "\n", r = "\r", t = "\t" }
          table.insert(value, replacements[stringChar] or stringChar)
          escaped = false
        elseif stringChar == "\\" then
          escaped = true
        elseif stringChar == "\"" then
          index += 1
          break
        else
          if stringChar == "\n" then
            line += 1
          end
          table.insert(value, stringChar)
        end
        index += 1
      end
      table.insert(tokens, { type = "string", value = table.concat(value), line = startLine })
    elseif char == "{" or char == "}" or char == ";" then
      table.insert(tokens, { type = char, value = char, line = line })
      index += 1
    else
      local start = index
      while index <= #content do
        char = content:sub(index, index)
        nextChar = content:sub(index + 1, index + 1)
        if char:match("%s") or char == "\"" or char == "{" or char == "}" or char == ";"
          or (char == "/" and (nextChar == "/" or nextChar == "*")) then
          break
        end
        index += 1
      end
      table.insert(tokens, { type = "word", value = content:sub(start, index - 1), line = line })
    end
  end
  return tokens
end

local function niriActionText(tokens)
  local values = {}
  for _, token in ipairs(tokens) do
    if token.type == "string" then
      table.insert(values, token.value)
    elseif token.type == "word" then
      table.insert(values, token.value)
    elseif token.type == ";" then
      if #values > 0 then
        values[#values] = values[#values] .. ";"
      end
    end
  end
  return trim(table.concat(values, " "))
end

local function niriCategoryFor(action)
  local value = lower(action)
  if startsWith(value, "spawn") then return "Applications" end
  if startsWith(value, "focus-column-") then return "Column Navigation" end
  if startsWith(value, "focus-window-") then return "Window Focus" end
  if startsWith(value, "focus-workspace-") then return "Workspace Navigation" end
  if startsWith(value, "move-column-") then return "Move Columns" end
  if startsWith(value, "move-window-") then return "Move Windows" end
  if startsWith(value, "screenshot") then return "Screenshots" end
  if startsWith(value, "close-window") or startsWith(value, "fullscreen-window") then return "Window Management" end
  if startsWith(value, "power-off-monitors") then return "Power" end
  if startsWith(value, "quit") then return "System" end
  return "Other"
end

local function niriHeaderDescription(header)
  for index, token in ipairs(header) do
    if token.type == "word" then
      if token.value == "hotkey-overlay-title=" and header[index + 1] ~= nil and header[index + 1].type == "string" then
        return header[index + 1].value
      end
      local quoted = token.value:match('^hotkey%-overlay%-title="(.*)"$')
      if quoted ~= nil then
        return quoted
      end
    end
  end
  return ""
end

local function parseNiriContent(content, sourceFile, context)
  local includes = {}
  for rawLine in (content .. "\n"):gmatch("(.-)\r?\n") do
    local includePath = rawLine:match('^%s*include%s+"([^"]+)"')
    if includePath ~= nil then
      table.insert(includes, { path = includePath, optional = false })
    end
  end

  local tokens = niriTokens(content)
  local index = 1
  while index <= #tokens do
    if tokens[index].type == "word" and tokens[index].value == "binds"
      and tokens[index + 1] ~= nil and tokens[index + 1].type == "{" then
      index += 2
      local category = ""
      while index <= #tokens and tokens[index].type ~= "}" do
        local token = tokens[index]
        if token.type == "comment" then
          local heading = token.value:match('#%s*"([^"]+)"') or token.value:match("#%s*'([^']+)'")
          if heading ~= nil then
            category = trim(heading)
          end
          index += 1
        elseif token.type == "word" then
          local hotkey = token.value
          local sourceLine = token.line
          local header = {}
          index += 1
          while index <= #tokens and tokens[index].type ~= "{" and tokens[index].type ~= "}" do
            table.insert(header, tokens[index])
            index += 1
          end
          if index <= #tokens and tokens[index].type == "{" then
            local depth = 1
            local actionTokens = {}
            index += 1
            while index <= #tokens and depth > 0 do
              if tokens[index].type == "{" then
                depth += 1
                table.insert(actionTokens, tokens[index])
              elseif tokens[index].type == "}" then
                depth -= 1
                if depth > 0 then
                  table.insert(actionTokens, tokens[index])
                end
              else
                table.insert(actionTokens, tokens[index])
              end
              index += 1
            end
            local action = niriActionText(actionTokens)
            local keyParts = {}
            for part in hotkey:gmatch("[^+]+") do
              table.insert(keyParts, part)
            end
            local key = table.remove(keyParts) or hotkey
            local description = niriHeaderDescription(header)
            addBinding(context.bindings, {
              compositor = "niri",
              bindingType = "bind",
              modifiers = normalizeModifiers(table.concat(keyParts, " "), {}),
              key = key,
              action = action,
              description = description,
              category = category ~= "" and category or niriCategoryFor(action),
              sourceFile = sourceFile,
              sourceLine = sourceLine,
            })
          else
            index += 1
          end
        else
          index += 1
        end
      end
    end
    index += 1
  end
  return includes
end

local function walkConfig(rootPath, parser)
  local context = {
    bindings = {},
    variables = {},
    warnings = {},
    visited = {},
    fileCount = 0,
    rootRead = false,
    sources = {},
    globs = {},
  }

  local visit
  visit = function(pattern, depth, optional, isRoot)
    if depth > MAX_PARSE_DEPTH then
      table.insert(context.warnings, "Include depth exceeded at " .. pattern)
      return
    end
    if context.fileCount >= MAX_PARSE_FILES then
      table.insert(context.warnings, "File limit reached at " .. pattern)
      return
    end

    local files = expandGlob(pattern, context)
    if #files == 0 then
      if not optional then
        table.insert(context.warnings, "Could not read " .. pattern)
      end
      return
    end
    for _, file in ipairs(files) do
      file = normalizePath(file)
      if not context.visited[file] and context.fileCount < MAX_PARSE_FILES then
        context.visited[file] = true
        context.fileCount += 1
        local content, err = noctalia.readFile(file)
        if content == nil then
          if not optional then
            table.insert(context.warnings, err or ("Could not read " .. file))
          end
        else
          local info = noctalia.fileInfo(file)
          if info ~= nil then
            table.insert(context.sources, { path = file, size = info.size, mtime = info.mtime })
          end
          if isRoot then
            context.rootRead = true
          end
          local includes = parser(content, file, context) or {}
          for _, include in ipairs(includes) do
            local resolved = resolvePath(include.path, file)
            visit(resolved, depth + 1, include.optional == true, false)
          end
        end
      end
    end
  end

  local expandedRoot = normalizePath(expandEnvironment(rootPath))
  visit(expandedRoot, 0, false, true)
  return context
end

local function readConfig(rootPath, parser)
  local context = walkConfig(rootPath, parser)
  if not context.rootRead then
    context = walkConfig(rootPath, parser)
  end
  if not context.rootRead then
    noctalia.log("Keybind cheatsheet could not read " .. expandEnvironment(rootPath)
      .. ": " .. table.concat(context.warnings, "; "))
  end
  return context
end

local function scanHyprLuaContent(content, sourceFile, context)
  local category = ""
  local includes = {}
  for rawLine in (content .. "\n"):gmatch("(.-)\r?\n") do
    local heading = rawLine:match("^%s*%-%-%s*%d+%.%s*(.-)%s*$")
    if heading ~= nil and heading ~= "" then
      category = heading
    end

    local code = rawLine:gsub("%-%-.*$", "")
    local module = code:match('require%s*%(%s*"([^"]+)"')
      or code:match("require%s*%(%s*'([^']+)'")
      or code:match('require%s+"([^"]+)"')
      or code:match("require%s+'([^']+)'")
    if module ~= nil then
      local modulePath = module:gsub("%.", "/") .. ".lua"
      table.insert(includes, { path = pathJoin(context.luaRoot, modulePath), optional = false })
    end

    local description = code:match('description%s*=%s*"([^"]*)"')
      or code:match("description%s*=%s*'([^']*)'")
      or code:match('desc%s*=%s*"([^"]*)"')
      or code:match("desc%s*=%s*'([^']*)'")
    if description ~= nil and description ~= "" then
      local kind = code:find("%.%.") ~= nil and "prefix" or "exact"
      table.insert(context.rules, { kind = kind, value = description, category = category ~= "" and category or "Other" })
    end
  end
  return includes
end

local function scanHyprLua(rootPath)
  local context = {
    bindings = {},
    variables = {},
    warnings = {},
    visited = {},
    fileCount = 0,
    rootRead = false,
    rules = {},
    luaRoot = pathDirname(normalizePath(expandEnvironment(rootPath))),
    sources = {},
    globs = {},
  }

  local visit
  visit = function(path, depth, isRoot)
    if depth > MAX_PARSE_DEPTH or context.fileCount >= MAX_PARSE_FILES then
      table.insert(context.warnings, "Lua include limit reached at " .. path)
      return
    end
    path = normalizePath(path)
    if context.visited[path] then
      return
    end
    context.visited[path] = true
    context.fileCount += 1
    local content, err = noctalia.readFile(path)
    if content == nil then
      table.insert(context.warnings, err or ("Could not read " .. path))
      return
    end
    local info = noctalia.fileInfo(path)
    if info ~= nil then
      table.insert(context.sources, { path = path, size = info.size, mtime = info.mtime })
    end
    if isRoot then context.rootRead = true end
    local includes = scanHyprLuaContent(content, path, context)
    for _, include in ipairs(includes) do
      visit(normalizePath(include.path), depth + 1, false)
    end
  end

  visit(normalizePath(expandEnvironment(rootPath)), 0, true)
  return context
end

local function categoryFromHyprRules(description, rules)
  for _, rule in ipairs(rules) do
    if rule.kind == "exact" and description == rule.value then
      return rule.category
    end
  end
  for _, rule in ipairs(rules) do
    if rule.kind == "prefix" and startsWith(description, rule.value) then
      return rule.category
    end
  end
  return "Other"
end

local function modifiersFromMask(mask)
  local result = {}
  local bits = {
    { 1, "SHIFT" },
    { 4, "CTRL" },
    { 8, "ALT" },
    { 16, "MOD2" },
    { 32, "MOD3" },
    { 64, "SUPER" },
    { 128, "MOD5" },
  }
  mask = tonumber(mask) or 0
  for _, entry in ipairs(bits) do
    if math.floor(mask / entry[1]) % 2 == 1 then
      table.insert(result, entry[2])
    end
  end
  return result
end

local function parseHyprJson(raw, rules)
  local decoded, err = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return nil, err or "Invalid hyprctl JSON"
  end
  local result = {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" then
      local description = entry.has_description == false and "" or (entry.description or "")
      local key = entry.key or ""
      if key == "" and tonumber(entry.keycode) ~= nil and tonumber(entry.keycode) ~= 0 then
        key = "code:" .. tostring(entry.keycode)
      end
      local dispatcher = entry.dispatcher or ""
      local argument = entry.arg or ""
      if key ~= "" and dispatcher ~= "" then
        addBinding(result, {
          compositor = "hyprland",
          bindingType = entry.mouse == true and "bindm" or "bind",
          modifiers = modifiersFromMask(entry.modmask),
          key = key,
          action = trim(dispatcher .. " " .. argument),
          description = description,
          category = description ~= "" and categoryFromHyprRules(description, rules) or "",
          sourceFile = "hyprctl binds -j",
          sourceLine = 0,
          submap = entry.submap or "",
        })
      end
    end
  end
  return result, nil
end

local function detectCompositor()
  local forced = configString("compositor", "auto")
  if forced ~= "auto" then
    return forced
  end
  if noctalia.getenv("MANGO_INSTANCE_SIGNATURE") ~= nil then return "mango" end
  if noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil then return "hyprland" end
  if noctalia.getenv("NIRI_SOCKET") ~= nil then return "niri" end

  local desktop = lower((noctalia.getenv("XDG_CURRENT_DESKTOP") or "") .. ":" .. (noctalia.getenv("XDG_SESSION_DESKTOP") or ""))
  if desktop:find("mango", 1, true) ~= nil then return "mango" end
  if desktop:find("hyprland", 1, true) ~= nil then return "hyprland" end
  if desktop:find("niri", 1, true) ~= nil then return "niri" end

  if noctalia.fileExists(noctalia.expandPath("~/.config/mango/config.conf")) then return "mango" end
  if noctalia.fileExists(noctalia.expandPath("~/.config/hypr/hyprland.lua"))
    or noctalia.fileExists(noctalia.expandPath("~/.config/hypr/hyprland.conf")) then return "hyprland" end
  if noctalia.fileExists(noctalia.expandPath("~/.config/niri/config.kdl")) then return "niri" end
  return nil
end

local function currentRequest()
  local compositor = detectCompositor()
  if compositor == nil then return nil end
  if compositor == "mango" then
    return {
      compositor = compositor,
      parser = "mango",
      root = normalizePath(expandEnvironment(configString("mango_config", "~/.config/mango/config.conf"))),
    }
  end
  if compositor == "niri" then
    return {
      compositor = compositor,
      parser = "niri",
      root = normalizePath(expandEnvironment(configString("niri_config", "~/.config/niri/config.kdl"))),
    }
  end
  if compositor == "hyprland" then
    local mode = configString("hyprland_parser", "auto")
    local luaPath = configString("hyprland_lua_config", "~/.config/hypr/hyprland.lua")
    local useLua = mode == "lua" or (mode == "auto" and noctalia.fileExists(noctalia.expandPath(luaPath)))
    local root = useLua and luaPath or configString("hyprland_config", "~/.config/hypr/hyprland.conf")
    return {
      compositor = compositor,
      parser = useLua and "hypr-lua" or "hypr-conf",
      root = normalizePath(expandEnvironment(root)),
    }
  end
  return nil
end

local function requestsMatch(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.compositor == right.compositor
    and left.parser == right.parser
    and left.root == right.root
end

local function normalizedCache(decoded)
  if type(decoded) ~= "table" or decoded.schema ~= CACHE_SCHEMA or type(decoded.request) ~= "table"
    or type(decoded.bindings) ~= "table" or type(decoded.sources) ~= "table"
    or type(decoded.globs) ~= "table" then
    return nil
  end

  local cachedBindings = {}
  for _, item in ipairs(decoded.bindings) do
    if type(item) ~= "table" or type(item.key) ~= "string" or type(item.action) ~= "string"
      or type(item.modifiers) ~= "table" then
      return nil
    end
    local modifiers = {}
    for _, modifier in ipairs(item.modifiers) do
      if type(modifier) ~= "string" then return nil end
      table.insert(modifiers, modifier)
    end
    addBinding(cachedBindings, {
      compositor = type(item.compositor) == "string" and item.compositor or decoded.request.compositor,
      bindingType = type(item.bindingType) == "string" and item.bindingType or "bind",
      modifiers = modifiers,
      key = item.key,
      action = item.action,
      description = type(item.description) == "string" and item.description or "",
      category = type(item.category) == "string" and item.category or "",
      sourceFile = type(item.sourceFile) == "string" and item.sourceFile or "",
      sourceLine = tonumber(item.sourceLine) or 0,
      submap = type(item.submap) == "string" and item.submap or "",
    })
  end

  local warnings = {}
  for _, warning in ipairs(type(decoded.warnings) == "table" and decoded.warnings or {}) do
    if type(warning) == "string" then table.insert(warnings, warning) end
  end
  return {
    schema = CACHE_SCHEMA,
    request = {
      compositor = decoded.request.compositor,
      parser = decoded.request.parser,
      root = decoded.request.root,
    },
    bindings = cachedBindings,
    warnings = warnings,
    sources = decoded.sources,
    globs = decoded.globs,
  }
end

local function cachePath()
  local directory, err = noctalia.pluginDataDir()
  if directory == nil then
    noctalia.log("Could not resolve plugin data directory: " .. (err or "unknown error"))
    return nil
  end
  return directory .. "/" .. BINDINGS_CACHE_FILE
end

local function readBindingCache()
  local path = cachePath()
  if path == nil then return nil end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then return nil end
  local decoded = noctalia.json.decode(raw)
  return normalizedCache(decoded)
end

local function cachedBindingValue(binding)
  return {
    compositor = binding.compositor,
    bindingType = binding.bindingType,
    modifiers = binding.modifiers,
    key = binding.key,
    action = binding.action,
    description = binding.description,
    category = binding.baseCategory or binding.category,
    sourceFile = binding.sourceFile,
    sourceLine = binding.sourceLine,
    submap = binding.submap,
  }
end

local function saveBindingCache(cache)
  local path = cachePath()
  if path == nil then return end
  local serializedBindings = {}
  for _, binding in ipairs(cache.bindings) do
    table.insert(serializedBindings, cachedBindingValue(binding))
  end
  local encoded, encodeError = noctalia.json.encode({
    schema = CACHE_SCHEMA,
    request = cache.request,
    bindings = serializedBindings,
    warnings = cache.warnings,
    sources = cache.sources,
    globs = cache.globs,
  }, false)
  if encoded == nil then
    noctalia.log("Could not encode keybind cache: " .. (encodeError or "unknown error"))
    return
  end

  local temporary = path .. ".tmp"
  local written, writeError = noctalia.writeFile(temporary, encoded)
  if not written then
    noctalia.log("Could not write keybind cache: " .. (writeError or "unknown error"))
    return
  end
  local renamed, renameError = noctalia.renameFile(temporary, path)
  if not renamed then
    noctalia.removeFile(temporary)
    noctalia.log("Could not commit keybind cache: " .. (renameError or "unknown error"))
  end
end

local refresh

local function snapshot(status, request, cache, err, isRefreshing)
  return {
    schema = CACHE_SCHEMA,
    status = status,
    compositor = request ~= nil and request.compositor or "",
    parser = request ~= nil and request.parser or "",
    source = request ~= nil and request.root or "",
    request = request,
    bindings = cache ~= nil and cache.bindings or {},
    warnings = cache ~= nil and cache.warnings or {},
    error = err or "",
    refreshing = isRefreshing == true,
  }
end

local function publish(status, request, cache, err, isRefreshing)
  noctalia.state.set(SNAPSHOT_KEY, snapshot(status, request, cache, err, isRefreshing))
end

local function matchingLastGood(request)
  if requestsMatch(lastGood ~= nil and lastGood.request or nil, request) then
    return lastGood
  end
  return nil
end

local function finishRefresh(generation, request, result, warnings, err, sourceSnapshot)
  if generation ~= refreshGeneration then return end

  refreshing = false
  if err == nil then
    lastGood = {
      schema = CACHE_SCHEMA,
      request = request,
      bindings = result or {},
      warnings = warnings or {},
      sources = sourceSnapshot ~= nil and sourceSnapshot.sources or {},
      globs = sourceSnapshot ~= nil and sourceSnapshot.globs or {},
    }
    saveBindingCache(lastGood)
    publish("ready", request, lastGood, "", false)
  else
    local previous = matchingLastGood(request)
    if previous ~= nil then
      publish("ready", request, previous, err, false)
    else
      publish("error", request, nil, err, false)
    end
  end

  if refreshQueued then
    refreshQueued = false
    refresh(request)
  end
end

local function configReadError(context)
  if context.rootRead then return nil end
  return tr("missing_config")
end

local function refreshHyprLua(generation, request)
  local scan = scanHyprLua(request.root)
  if not noctalia.commandExists("hyprctl") then
    finishRefresh(generation, request, {}, scan.warnings, tr("hyprctl_missing"), scan)
    return
  end

  local accepted = noctalia.runAsync("hyprctl binds -j", function(result)
    if generation ~= refreshGeneration then return end
    if result.exitCode ~= 0 or result.timedOut then
      local message = trim(result.stderr)
      finishRefresh(
        generation,
        request,
        {},
        scan.warnings,
        message ~= "" and message or tr("hyprctl_failed"),
        scan
      )
      return
    end
    local parsed, err = parseHyprJson(result.stdout, scan.rules)
    finishRefresh(generation, request, parsed or {}, scan.warnings, err, scan)
  end, 10000)

  if not accepted then
    finishRefresh(generation, request, {}, scan.warnings, tr("hyprctl_failed"), scan)
  end
end

local function performRefresh(generation, request)
  if request == nil then
    finishRefresh(generation, { compositor = "", parser = "", root = "" }, {}, {}, tr("unsupported"), nil)
  elseif request.parser == "mango" then
    local context = readConfig(request.root, parseMangoContent)
    finishRefresh(generation, request, context.bindings, context.warnings, configReadError(context), context)
  elseif request.parser == "niri" then
    local context = readConfig(request.root, parseNiriContent)
    finishRefresh(generation, request, context.bindings, context.warnings, configReadError(context), context)
  elseif request.parser == "hypr-lua" then
    refreshHyprLua(generation, request)
  elseif request.parser == "hypr-conf" then
    local context = readConfig(request.root, parseHyprContent)
    finishRefresh(generation, request, context.bindings, context.warnings, configReadError(context), context)
  else
    finishRefresh(generation, request, {}, {}, tr("unsupported"), nil)
  end
end

refresh = function(request)
  if refreshing then
    refreshQueued = true
    return
  end

  request = request or currentRequest()
  refreshGeneration += 1
  local generation = refreshGeneration
  refreshing = true
  local previous = matchingLastGood(request)
  if previous == nil then
    publish("loading", request, nil, "", true)
  end
  performRefresh(generation, request)
end

local function loadCachedSnapshot(request)
  local cached = readBindingCache()
  if requestsMatch(cached ~= nil and cached.request or nil, request) then
    lastGood = cached
    publish("ready", request, cached, "", true)
  else
    lastGood = nil
    publish("loading", request, nil, "", true)
  end
end

local function bootstrap()
  local request = currentRequest()
  loadCachedSnapshot(request)
  refresh(request)
end

local function lifecycleState()
  local current = noctalia.state.get(SNAPSHOT_KEY)
  return {
    refreshing = refreshing,
    refreshQueued = refreshQueued,
    bindingCount = type(current) == "table" and type(current.bindings) == "table" and #current.bindings or 0,
    cacheLoaded = lastGood ~= nil,
  }
end

local function resetForTests()
  refreshGeneration += 1
  refreshing = false
  refreshQueued = false
  lastGood = nil
  bootstrap()
end

local function containsAll(values, required)
  local found = {}
  for _, value in ipairs(values) do found[value] = true end
  for _, value in ipairs(required or {}) do
    if not found[value] then return false, value end
  end
  return true, nil
end

local function runSelfTest()
  local pluginDir = noctalia.pluginDir() or "."
  local fixtureRoot = pluginDir .. "/tests/fixtures"
  local expectedRaw = noctalia.readFile(pluginDir .. "/tests/expected.json")
  local expected = expectedRaw ~= nil and noctalia.json.decode(expectedRaw) or nil
  local report = { passed = true, cases = {} }
  if type(expected) ~= "table" then
    report.passed = false
    report.error = "Could not read tests/expected.json"
  else
    local cases = {
      mango = function()
        return walkConfig(fixtureRoot .. "/mango/main.conf", parseMangoContent).bindings
      end,
      hypr_conf = function()
        return walkConfig(fixtureRoot .. "/hypr/hyprland.conf", parseHyprContent).bindings
      end,
      niri = function()
        return walkConfig(fixtureRoot .. "/niri/config.kdl", parseNiriContent).bindings
      end,
      hypr_lua = function()
        local scan = scanHyprLua(fixtureRoot .. "/hypr/hyprland.lua")
        local raw = noctalia.readFile(fixtureRoot .. "/hypr/binds.json") or "[]"
        return parseHyprJson(raw, scan.rules) or {}
      end,
    }
    for name, execute in pairs(cases) do
      local parsed = execute()
      local expectedCase = expected[name]
      local descriptions = {}
      local categories = {}
      for _, binding in ipairs(parsed) do
        table.insert(descriptions, binding.description)
        table.insert(
          categories,
          binding.description == "" and tr("without_description")
            or (binding.category ~= "" and binding.category or tr("other"))
        )
      end
      local descriptionsOk, missingDescription = containsAll(descriptions, expectedCase.descriptions)
      local categoriesOk, missingCategory = containsAll(categories, expectedCase.categories)
      local passed = #parsed == expectedCase.count and descriptionsOk and categoriesOk
      report.cases[name] = {
        passed = passed,
        expectedCount = expectedCase.count,
        actualCount = #parsed,
        missingDescription = missingDescription,
        missingCategory = missingCategory,
      }
      if not passed then report.passed = false end
    end
  end
  local encoded = noctalia.json.encode(report, true) or "{}"
  local dataDir = noctalia.pluginDataDir()
  if dataDir ~= nil then noctalia.writeFile(dataDir .. "/selftest.json", encoded) end
  noctalia.log("Keybind cheatsheet self-test: " .. encoded)
  if report.passed then
    noctalia.notify(tr("title"), "Parser self-test passed")
  else
    noctalia.notifyError(tr("title"), "Parser self-test failed; see the Noctalia log")
  end
end

function onConfigChanged()
  local request = currentRequest()
  local current = noctalia.state.get(SNAPSHOT_KEY)
  if requestsMatch(type(current) == "table" and current.request or nil, request) then
    return
  end
  refreshGeneration += 1
  refreshing = false
  refreshQueued = false
  loadCachedSnapshot(request)
  refresh(request)
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  elseif event == "self-test" then
    runSelfTest()
  end
end

function onExit(_signal)
  refreshGeneration += 1
  refreshing = false
  refreshQueued = false
end

noctalia.state.watch(REFRESH_REQUEST_KEY, function(_request)
  refresh()
end)

noctalia.state.watch(SELF_TEST_REQUEST_KEY, function(_request)
  runSelfTest()
end)

bootstrap()

return {
  parseMangoContent = parseMangoContent,
  mangoCategoryFromComment = mangoCategoryFromComment,
  parseHyprContent = parseHyprContent,
  parseNiriContent = parseNiriContent,
  parseHyprJson = parseHyprJson,
  scanHyprLua = scanHyprLua,
  walkConfig = walkConfig,
  configReadError = configReadError,
  currentRequest = currentRequest,
  requestsMatch = requestsMatch,
  normalizedCache = normalizedCache,
  refresh = refresh,
  bootstrap = bootstrap,
  resetForTests = resetForTests,
  lifecycleState = lifecycleState,
  onConfigChanged = onConfigChanged,
  onIpc = onIpc,
  onExit = onExit,
  runSelfTest = runSelfTest,
  snapshotKey = SNAPSHOT_KEY,
  refreshRequestKey = REFRESH_REQUEST_KEY,
}
