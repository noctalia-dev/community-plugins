--!nonstrict
-- Searchable keybind viewer for Mango, Hyprland, and Niri.
--
-- The entry is deliberately idle while the panel is closed: there is no
-- update(), service, stream, watcher, or background process. Configuration is
-- parsed on onOpen() and explicit refresh only, then released in onClose().

local noctalia = noctalia
local ui = ui
local panel = panel
if noctalia == nil then
  local host = require("./tests/host_mock")
  noctalia = host.noctalia
  ui = host.ui
  panel = host.panel
end

local PANEL_ID = "kenn/keybind-cheatsheet:cheatsheet"
local MAX_PARSE_DEPTH = 32
local MAX_PARSE_FILES = 256
local PREFERENCES_FILE = "preferences.json"

local bindings = {}
local parseWarnings = {}
local currentCompositor = ""
local loading = false
local panelOpen = false
local panelError = nil
local query = ""
local searchRevision = 0
local parseGeneration = 0
local refreshPending = false
local view = "bindings"
local editingId = nil
local editDraft = ""
local preferences = { version = 1, hidden = {}, descriptions = {}, colors = {} }

local render
local refresh

local env = getfenv()
local dynamicCallbacks = {}
local callbackIndex = 0

local function tr(key, values)
  return noctalia.tr(key, values)
end

local function trim(value)
  return noctalia.string.trim(value or "")
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

local function resetCallbacks()
  for _, name in ipairs(dynamicCallbacks) do
    env[name] = nil
  end
  dynamicCallbacks = {}
  callbackIndex = 0
end

local function callback(prefix, fn)
  callbackIndex += 1
  local name = "keybindCheatsheet_" .. prefix .. "_" .. callbackIndex
  env[name] = fn
  table.insert(dynamicCallbacks, name)
  return name
end

local function copyTable(value)
  local result = {}
  for key, item in pairs(value or {}) do
    if type(item) == "table" then
      result[key] = copyTable(item)
    else
      result[key] = item
    end
  end
  return result
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

local function expandGlob(path)
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
  return files
end

local function extractTrailingDescription(line)
  local startIndex, _, description = line:find("#%s*\"([^\"]*)\"%s*$")
  if startIndex == nil then
    startIndex, _, description = line:find("#%s*'([^']*)'%s*$")
  end
  if startIndex == nil then
    return line, ""
  end
  return trim(line:sub(1, startIndex - 1)), trim(description)
end

local function splitCsv(value, maximumParts)
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
      local recognized = false
      for _, name in ipairs(MODIFIER_ORDER) do
        if upper == name then
          present[name] = true
          recognized = true
          break
        end
      end
      if not recognized and not present[upper] then
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

local KEY_LABELS = {
  XF86AudioRaiseVolume = "Vol Up",
  XF86AudioLowerVolume = "Vol Down",
  XF86AudioMute = "Mute",
  XF86AudioMicMute = "Mic Mute",
  XF86MonBrightnessUp = "Bright Up",
  XF86MonBrightnessDown = "Bright Down",
  XF86AudioPlay = "Play/Pause",
  XF86AudioPause = "Pause",
  XF86AudioNext = "Next",
  XF86AudioPrev = "Previous",
  Print = "PrtSc",
  Prior = "PgUp",
  Next = "PgDn",
  Return = "Enter",
  Escape = "Esc",
  space = "Space",
  btn_left = "Mouse Left",
  btn_right = "Mouse Right",
  btn_middle = "Mouse Middle",
  btn_side = "Mouse Side",
  btn_extra = "Mouse Extra",
}

local function formatKey(key)
  return KEY_LABELS[key] or key:gsub("^mouse:", "Mouse ")
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
  local category = ""
  local includes = {}
  local lineNumber = 0
  for rawLine in (content .. "\n"):gmatch("(.-)\r?\n") do
    lineNumber += 1
    local line = trim(rawLine)
    if line ~= "" then
      local optionalPath = line:match("^source%-optional%s*=%s*(.-)%s*$")
      local sourcePath = line:match("^source%s*=%s*(.-)%s*$")
      if optionalPath ~= nil then
        table.insert(includes, { path = optionalPath, optional = true })
      elseif sourcePath ~= nil then
        table.insert(includes, { path = expandHyprVariables(sourcePath, context.variables), optional = false })
      elseif startsWith(line, "#") then
        local heading = mangoCategoryFromComment(line)
        if heading ~= nil then category = heading end
      else
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

    local files = expandGlob(pattern)
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

local function preferencesPath()
  local directory, err = noctalia.pluginDataDir()
  if directory == nil then
    noctalia.log("Could not resolve plugin data directory: " .. (err or "unknown error"))
    return nil
  end
  return directory .. "/" .. PREFERENCES_FILE
end

local function normalizePreferences(decoded)
  local result = { version = 1, hidden = {}, descriptions = {}, colors = {} }
  if type(decoded) ~= "table" then
    return result
  end
  for id, hidden in pairs(type(decoded.hidden) == "table" and decoded.hidden or {}) do
    if type(id) == "string" and hidden == true then
      result.hidden[id] = true
    end
  end
  for id, description in pairs(type(decoded.descriptions) == "table" and decoded.descriptions or {}) do
    if type(id) == "string" and type(description) == "string" and trim(description) ~= "" then
      result.descriptions[id] = trim(description)
    end
  end
  for bucket, colors in pairs(type(decoded.colors) == "table" and decoded.colors or {}) do
    if type(bucket) == "string" and type(colors) == "table" then
      result.colors[bucket] = {}
      if type(colors.background) == "string" then result.colors[bucket].background = colors.background end
      if type(colors.text) == "string" then result.colors[bucket].text = colors.text end
    end
  end
  return result
end

local function loadPreferences()
  local path = preferencesPath()
  if path == nil then
    preferences = normalizePreferences(nil)
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then
    preferences = normalizePreferences(nil)
    return
  end
  local decoded = noctalia.json.decode(raw)
  preferences = normalizePreferences(decoded)
end

local function savePreferences()
  local path = preferencesPath()
  if path == nil then return end
  local encoded = noctalia.json.encode(preferences, true)
  if encoded == nil then return end
  local ok, err = noctalia.writeFile(path, encoded)
  if not ok then
    noctalia.notifyError(tr("title"), err or "Could not save preferences")
  end
end

local function finishParse(generation, compositor, result, warnings, err)
  if not panelOpen or generation ~= parseGeneration then
    return
  end
  currentCompositor = compositor or ""
  bindings = result or {}
  parseWarnings = warnings or {}
  if #bindings > 0 then
    panelError = nil
  else
    panelError = err
  end
  loading = false
  if refreshPending then
    refreshPending = false
    refresh()
  else
    render()
  end
end

local function configReadError(context)
  if context.rootRead then
    return nil
  end
  return tr("missing_config")
end

local function parseHyprLua(generation)
  local luaPath = configString("hyprland_lua_config", "~/.config/hypr/hyprland.lua")
  local scan = scanHyprLua(luaPath)
  if not noctalia.commandExists("hyprctl") then
    finishParse(generation, "hyprland", {}, scan.warnings, tr("hyprctl_missing"))
    return
  end
  local accepted = noctalia.runAsync("hyprctl binds -j", function(result)
    if result.exitCode ~= 0 or result.timedOut then
      local message = trim(result.stderr)
      finishParse(generation, "hyprland", {}, scan.warnings, message ~= "" and message or tr("hyprctl_failed"))
      return
    end
    local parsed, err = parseHyprJson(result.stdout, scan.rules)
    finishParse(generation, "hyprland", parsed or {}, scan.warnings, err)
  end, 10000)
  if not accepted then
    finishParse(generation, "hyprland", {}, scan.warnings, tr("hyprctl_failed"))
  end
end

refresh = function()
  if loading then
    refreshPending = true
    return
  end
  refreshPending = false
  parseGeneration += 1
  local generation = parseGeneration
  bindings = {}
  parseWarnings = {}
  panelError = nil
  loading = true
  currentCompositor = ""
  render()

  local compositor = detectCompositor()
  if compositor == nil then
    finishParse(generation, nil, {}, {}, tr("unsupported"))
    return
  end
  if compositor == "mango" then
    local root = configString("mango_config", "~/.config/mango/config.conf")
    local context = readConfig(root, parseMangoContent)
    finishParse(generation, compositor, context.bindings, context.warnings, configReadError(context))
  elseif compositor == "niri" then
    local root = configString("niri_config", "~/.config/niri/config.kdl")
    local context = readConfig(root, parseNiriContent)
    finishParse(generation, compositor, context.bindings, context.warnings, configReadError(context))
  elseif compositor == "hyprland" then
    local mode = configString("hyprland_parser", "auto")
    local luaPath = configString("hyprland_lua_config", "~/.config/hypr/hyprland.lua")
    if mode == "lua" or (mode == "auto" and noctalia.fileExists(noctalia.expandPath(luaPath))) then
      parseHyprLua(generation)
    else
      local root = configString("hyprland_config", "~/.config/hypr/hyprland.conf")
      local context = readConfig(root, parseHyprContent)
      finishParse(generation, compositor, context.bindings, context.warnings, configReadError(context))
    end
  else
    finishParse(generation, compositor, {}, {}, tr("unsupported"))
  end
end

local COLOR_BUCKETS = {
  { id = "super", label = "Super", background = "primary", text = "on_primary", picker = "#6750A4" },
  { id = "ctrl", label = "Ctrl", background = "secondary", text = "on_secondary", picker = "#625B71" },
  { id = "shift", label = "Shift", background = "tertiary", text = "on_tertiary", picker = "#7D5260" },
  { id = "alt", label = "Alt", background = "error", text = "on_error", picker = "#B3261E" },
  { id = "xf86", label = "Media", background = "secondary/0.25", text = "secondary", picker = "#E8DEF8" },
  { id = "number", label = "Numbers", background = "tertiary/0.25", text = "tertiary", picker = "#FFD8E4" },
  { id = "mouse", label = "Mouse", background = "error/0.2", text = "error", picker = "#F9DEDC" },
  { id = "print", label = "Print", background = "primary/0.25", text = "primary", picker = "#EADDFF" },
  { id = "default", label = "Other keys", background = "surface_variant", text = "on_surface_variant", picker = "#E7E0EC" },
  { id = "description", label = "Descriptions", background = "surface", text = "on_surface", picker = "#1D1B20" },
}

local COLOR_BY_ID = {}
for _, bucket in ipairs(COLOR_BUCKETS) do COLOR_BY_ID[bucket.id] = bucket end

local function colorValue(bucketId, property)
  local custom = preferences.colors[bucketId]
  if custom ~= nil and custom[property] ~= nil then
    return custom[property]
  end
  local bucket = COLOR_BY_ID[bucketId] or COLOR_BY_ID.default
  return bucket[property]
end

local function bucketForKey(key)
  local value = lower(key)
  if startsWith(value, "xf86") then return "xf86" end
  if value:match("^%d$") then return "number" end
  if startsWith(value, "mouse") or startsWith(value, "btn_") or value:find("wheel", 1, true) ~= nil then return "mouse" end
  if value == "print" or value == "prior" or value == "next" then return "print" end
  return "default"
end

local function bucketForModifier(modifier)
  local value = lower(modifier)
  if value == "super" or value == "mod4" or value == "logo" then return "super" end
  if value == "ctrl" or value == "control" then return "ctrl" end
  if value == "shift" then return "shift" end
  if value == "alt" or value == "mod1" then return "alt" end
  return "default"
end

local function isHexColor(value)
  if type(value) ~= "string" then return false end
  return value:match("^#%x%x%x%x%x%x$") ~= nil or value:match("^#%x%x%x%x%x%x%x%x$") ~= nil
end

local function setColor(bucketId, property, value)
  preferences.colors[bucketId] = preferences.colors[bucketId] or {}
  preferences.colors[bucketId][property] = value
  savePreferences()
  render()
end

local function chooseColor(bucketId, property)
  local bucket = COLOR_BY_ID[bucketId] or COLOR_BY_ID.default
  local current = colorValue(bucketId, property)
  local initial = isHexColor(current) and current:sub(1, 7) or bucket.picker
  noctalia.openColorPicker(initial, function(color)
    if color ~= nil then
      setColor(bucketId, property, color)
    end
  end)
end

local function pasteColor(bucketId, property)
  local value = trim(noctalia.clipboardText() or "")
  if isHexColor(value) then
    setColor(bucketId, property, string.upper(value))
  else
    noctalia.notifyError(tr("title"), "Clipboard does not contain a #RRGGBB color")
  end
end

local function bindingContentOpacity(hidden)
  return hidden and 0.45 or 1
end

local function keyPill(text, bucketId, key)
  return ui.column({
    key = key,
    fill = colorValue(bucketId, "background"),
    radius = 4,
    paddingH = 7,
    paddingV = 3,
    align = "center",
  }, {
    ui.label({ text = text, color = colorValue(bucketId, "text"), fontSize = 12, fontWeight = "bold", maxLines = 1 }),
  })
end

local function authoredDescription(binding)
  return preferences.descriptions[binding.id] or binding.description or ""
end

local function titleCase(value)
  value = trim(value):gsub("[_%-]+", " ")
  return (value:gsub("(%a)([%w']*)", function(first, rest)
    return string.upper(first) .. lower(rest)
  end))
end

local function friendlySpawn(commandLine)
  local value = lower(trim(commandLine))
  if value:find("noctalia msg panel-toggle launcher", 1, true) ~= nil then return "Application Launcher" end
  if value:find("noctalia msg panel-toggle session", 1, true) ~= nil then return "Power Menu" end
  if value:find("noctalia msg session lock", 1, true) ~= nil then return "Lock Screen" end
  if value:find("playerctl play-pause", 1, true) ~= nil then return "Play / Pause" end
  if value:find("playerctl next", 1, true) ~= nil then return "Next Track" end
  if value:find("playerctl previous", 1, true) ~= nil then return "Previous Track" end
  if value:find("playerctl stop", 1, true) ~= nil then return "Stop Playback" end
  if value:find("wpctl set-volume", 1, true) ~= nil then
    return value:find("+", 1, true) ~= nil and "Volume Up" or "Volume Down"
  end
  if value:find("wpctl set-mute", 1, true) ~= nil then
    return value:find("source", 1, true) ~= nil and "Toggle Microphone Mute" or "Toggle Mute"
  end
  if value:find("brightnessctl", 1, true) ~= nil then
    return value:find("+", 1, true) ~= nil and "Brightness Up" or "Brightness Down"
  end

  local program = trim(commandLine):match("^([^%s]+)") or "Application"
  program = program:match("([^/]+)$") or program
  local programs = {
    alacritty = "Terminal",
    chromium = "Browser",
    dolphin = "File Manager",
    firefox = "Browser",
    foot = "Terminal",
    kitty = "Terminal",
    nautilus = "File Manager",
    thunar = "File Manager",
  }
  return programs[lower(program)] or ("Launch " .. titleCase(program))
end

local ACTION_LABELS = {
  close_window = "Close Window",
  killactive = "Close Window",
  killclient = "Close Window",
  minimized = "Minimize Window",
  quit = "Exit Compositor",
  reload_config = "Reload Configuration",
  restore_minimized = "Restore Minimized Window",
  switch_proportion_preset = "Cycle Width Preset",
  toggle_named_scratchpad = "Toggle Scratchpad",
  togglefakefullscreen = "Toggle Fake Fullscreen",
  togglefloating = "Toggle Floating",
  togglefullscreen = "Toggle Fullscreen",
  togglegaps = "Toggle Gaps",
  toggleglobal = "Toggle Global Window",
  togglemaximizescreen = "Toggle Maximize",
  toggleoverlay = "Toggle Overlay",
  toggleoverview = "Workspace Overview",
}

local function friendlyAction(binding)
  local action = trim(binding.action)
  local command, arguments = action:match("^(%S+)%s*(.*)$")
  command = lower(command or ""):gsub("%-", "_")
  arguments = trim(arguments or "")
  if command == "spawn" or command == "spawn_shell" or command == "exec" then
    return friendlySpawn(arguments)
  end
  if ACTION_LABELS[command] ~= nil then return ACTION_LABELS[command] end

  local argument = arguments:match("^([^,%s]+)") or ""
  local direction = argument ~= "" and titleCase(argument) or ""
  if command == "focusdir" or command == "movefocus" then return "Focus " .. direction end
  if command == "exchange_client" or command == "movewindow" then return "Move Window " .. direction end
  if command == "focusmon" then return "Focus Monitor " .. direction end
  if command == "tagmon" then return "Move to Monitor " .. direction end
  if command == "scroller_stack" then return "Move Within Stack " .. direction end
  if command == "view" or command == "workspace" then return "Workspace " .. argument end
  if command == "tag" or command == "movetoworkspace" then return "Send to Workspace " .. argument end
  if command == "viewtoleft" or command == "viewtoleft_have_client" then return "Previous Workspace" end
  if command == "viewtoright" or command == "viewtoright_have_client" then return "Next Workspace" end
  if command == "setlayout" then return titleCase(argument) .. " Layout" end
  if command == "set_proportion" then return "Set Window Proportion " .. argument end
  if command == "setmfact" then return "Set Layout Size " .. argument end
  if command == "moveresize" then
    return arguments:find("curresize", 1, true) ~= nil and "Resize Window with Mouse" or "Move Window with Mouse"
  end
  return titleCase(action)
end

local function effectiveDescription(binding)
  local description = authoredDescription(binding)
  return description ~= "" and description or friendlyAction(binding)
end

local function effectiveCategory(binding)
  if binding.baseCategory ~= nil and binding.baseCategory ~= "" then
    return binding.baseCategory
  end
  if authoredDescription(binding) == "" and binding.compositor ~= "niri" then
    return tr("without_description")
  end
  return binding.compositor == "niri" and niriCategoryFor(binding.action) or tr("other")
end

local function bindingMatches(binding)
  local needle = lower(trim(query))
  if needle == "" then return true end
  local haystack = lower(table.concat({
    table.concat(binding.modifiers, " "),
    binding.key,
    formatKey(binding.key),
    effectiveDescription(binding),
    binding.action,
    effectiveCategory(binding),
  }, " "))
  return haystack:find(needle, 1, true) ~= nil
end

local CATEGORY_PRIORITIES = {
  { "applications", 10 },
  { "system", 20 },
  { "window management", 30 },
  { "focus", 40 },
  { "navigation", 40 },
  { "moving windows", 45 },
  { "workspace", 50 },
  { "tags", 50 },
  { "monitor", 50 },
  { "media", 60 },
  { "brightness", 60 },
  { "layout", 70 },
  { "mouse", 80 },
  { "touchpad", 90 },
  { "gesture", 90 },
  { "integration", 100 },
  { lower(tr("without_description")), 900 },
  { lower(tr("other")), 950 },
}

local function categoryPriority(name)
  local value = lower(name)
  for _, entry in ipairs(CATEGORY_PRIORITIES) do
    if value:find(entry[1], 1, true) ~= nil then return entry[2] end
  end
  return 500
end

local function bindingAvailableInView(hidden, undescribed, managing, showUndescribed)
  if managing then return true end
  return not hidden and (showUndescribed or not undescribed)
end

local function hiddenBindingCount(bindingList, hiddenPreferences)
  local currentIds = {}
  for _, binding in ipairs(bindingList or {}) do
    currentIds[binding.id] = true
  end
  local count = 0
  for id in pairs(currentIds) do
    if hiddenPreferences[id] == true then count += 1 end
  end
  return count
end

local function restoreHiddenBindings(bindingList, hiddenPreferences)
  for _, binding in ipairs(bindingList or {}) do
    hiddenPreferences[binding.id] = nil
  end
end

local function visibleGroups()
  local showUndescribed = noctalia.getConfig("show_undescribed") ~= false
  local managing = view == "edit"
  local groups = {}
  local byName = {}
  for index, binding in ipairs(bindings) do
    local hidden = preferences.hidden[binding.id] == true
    local undescribed = authoredDescription(binding) == "" and binding.compositor ~= "niri"
    if bindingAvailableInView(hidden, undescribed, managing, showUndescribed) and bindingMatches(binding) then
      local category = effectiveCategory(binding)
      local group = byName[category]
      if group == nil then
        group = { name = category, bindings = {}, sourceOrder = #groups + 1, order = 0, weight = 1 }
        byName[category] = group
        table.insert(groups, group)
      end
      binding.displayIndex = index
      table.insert(group.bindings, binding)
      group.weight += 1
    end
  end
  table.sort(groups, function(a, b)
    local left = categoryPriority(a.name)
    local right = categoryPriority(b.name)
    if left ~= right then return left < right end
    return a.sourceOrder < b.sourceOrder
  end)
  for index, group in ipairs(groups) do group.order = index end
  return groups
end

local function columnCount()
  local configured = math.clamp(tonumber(noctalia.getConfig("columns")) or 3, 1, 4)
  local outputWidth = 1920
  local focused = noctalia.focusedOutputName()
  for _, output in ipairs(noctalia.outputs()) do
    if output.name == focused or output.focused then
      outputWidth = output.width / math.max(output.scale or 1, 1)
      break
    end
  end
  local responsive = outputWidth < 760 and 1 or (outputWidth < 1100 and 2 or (outputWidth < 1500 and 3 or 4))
  return math.min(configured, responsive)
end

local function balancedColumns(groups, count)
  local columns = {}
  for index = 1, count do columns[index] = { groups = {}, weight = 0 } end
  for _, group in ipairs(groups) do
    local target = 1
    for index = 2, count do
      if columns[index].weight < columns[target].weight then target = index end
    end
    table.insert(columns[target].groups, group)
    columns[target].weight += group.weight
  end
  for _, column in ipairs(columns) do
    table.sort(column.groups, function(a, b) return a.order < b.order end)
  end
  return columns
end

local function saveCustomDescription(binding, value)
  value = trim(value)
  if value == "" or value == binding.description then
    preferences.descriptions[binding.id] = nil
  else
    preferences.descriptions[binding.id] = value
  end
  editingId = nil
  editDraft = ""
  savePreferences()
  render()
end

local function bindingRow(binding, occurrence)
  local hidden = preferences.hidden[binding.id] == true
  local contentOpacity = bindingContentOpacity(hidden)
  local pills = {}
  for index, modifier in ipairs(binding.modifiers) do
    table.insert(pills, keyPill(modifier == "SUPER" and "Super" or modifier:sub(1, 1) .. lower(modifier:sub(2)), bucketForModifier(modifier), "mod-" .. index))
  end
  table.insert(pills, keyPill(formatKey(binding.key), bucketForKey(binding.key), "key"))

  local description = effectiveDescription(binding)
  local identity = binding.id .. "#" .. occurrence
  if view == "edit" and editingId == identity then
    local visibilityChanged = callback("visibility", function()
      if hidden then
        preferences.hidden[binding.id] = nil
      else
        preferences.hidden[binding.id] = true
      end
      savePreferences()
      render()
    end)
    local inputChanged = callback("editChange", function(value) editDraft = value end)
    local submit = callback("editSubmit", function(value) saveCustomDescription(binding, value) end)
    local save = callback("editSave", function() saveCustomDescription(binding, editDraft) end)
    local cancel = callback("editCancel", function()
      editingId = nil
      editDraft = ""
      render()
    end)
    return ui.row({ key = "edit-" .. identity, gap = 6, align = "center", paddingV = 0 }, {
      ui.row({ minWidth = 188, gap = 3, align = "center", opacity = contentOpacity }, pills),
      ui.input({ key = "description-" .. identity, value = editDraft, placeholder = tr("edit_description"), focus = true, controlSize = "sm", flexGrow = 1, onChange = inputChanged, onSubmit = submit }),
      ui.button({ glyph = "check", width = 22, height = 22, glyphSize = 12, variant = "ghost", controlSize = "sm", tooltip = tr("save"), onClick = save }),
      ui.button({ glyph = "close", width = 22, height = 22, glyphSize = 12, variant = "ghost", controlSize = "sm", tooltip = tr("cancel"), onClick = cancel }),
      ui.button({ glyph = hidden and "eye-off" or "eye", width = 22, height = 22, glyphSize = 13, variant = "ghost", controlSize = "sm", selected = hidden, tooltip = hidden and tr("show_binding") or tr("hide_binding"), onClick = visibilityChanged }),
    })
  end

  local labels = {
    ui.label({
      text = description,
      color = colorValue("description", "text"),
      fontWeight = "bold",
      fontSize = 13,
      maxLines = 1,
    }),
  }
  if noctalia.getConfig("show_actions") ~= false and description ~= "" and binding.action ~= "" then
    table.insert(labels, ui.label({ text = binding.action, color = "on_surface_variant", fontSize = 11, maxLines = 1 }))
  end
  local row = {
    ui.row({ minWidth = 188, gap = 3, align = "center", opacity = contentOpacity }, pills),
    ui.column({ flexGrow = 1, gap = 0, opacity = contentOpacity }, labels),
  }
  if view == "edit" then
    local edit = callback("edit", function()
      editingId = identity
      editDraft = description
      render()
    end)
    local visibilityChanged = callback("visibility", function()
      if hidden then
        preferences.hidden[binding.id] = nil
      else
        preferences.hidden[binding.id] = true
      end
      savePreferences()
      render()
    end)
    table.insert(row, ui.button({ glyph = "pencil", width = 22, height = 22, glyphSize = 12, variant = "ghost", controlSize = "sm", tooltip = tr("edit_description"), onClick = edit }))
    table.insert(row, ui.button({ glyph = hidden and "eye-off" or "eye", width = 22, height = 22, glyphSize = 13, variant = "ghost", controlSize = "sm", selected = hidden, tooltip = hidden and tr("show_binding") or tr("hide_binding"), onClick = visibilityChanged }))
  end
  return ui.row({ key = identity, gap = 6, align = "center", paddingV = 0 }, row)
end

local function categoryNode(group)
  local children = {
    ui.label({ text = string.upper(group.name), color = "primary", fontSize = 14, fontWeight = "bold" }),
    ui.separator({ color = "outline", thickness = 1, spacing = 1 }),
  }
  local occurrences = {}
  for _, binding in ipairs(group.bindings) do
    occurrences[binding.id] = (occurrences[binding.id] or 0) + 1
    table.insert(children, bindingRow(binding, occurrences[binding.id]))
  end
  return ui.column({ key = "category-" .. group.name, gap = 1, paddingV = 3, align = "stretch" }, children)
end

local function bindingsBody()
  local groups = visibleGroups()
  if #groups == 0 then
    return ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
      ui.glyph({ name = "search-off", size = 32, color = "on_surface_variant" }),
      ui.label({ text = tr("no_results"), color = "on_surface_variant" }),
    })
  end
  local columns = balancedColumns(groups, columnCount())
  local columnNodes = {}
  for index, column in ipairs(columns) do
    local categoryNodes = {}
    for _, group in ipairs(column.groups) do table.insert(categoryNodes, categoryNode(group)) end
    table.insert(columnNodes, ui.column({ key = "column-" .. index, flexGrow = 1, gap = 8, align = "stretch" }, categoryNodes))
  end
  return ui.scroll({ flexGrow = 1, gap = 0 }, {
    ui.row({ key = "binding-columns", gap = 22, align = "stretch" }, columnNodes),
  })
end

local function hiddenCount()
  return hiddenBindingCount(bindings, preferences.hidden)
end

local function colorControl(bucket, property)
  local choose = callback("chooseColor", function() chooseColor(bucket.id, property) end)
  local paste = callback("pasteColor", function() pasteColor(bucket.id, property) end)
  local reset = callback("resetColor", function()
    if preferences.colors[bucket.id] ~= nil then
      preferences.colors[bucket.id][property] = nil
      if next(preferences.colors[bucket.id]) == nil then preferences.colors[bucket.id] = nil end
      savePreferences()
      render()
    end
  end)
  return ui.row({ gap = 5, align = "center", flexGrow = 1 }, {
    ui.box({ width = 24, height = 24, radius = 5, fill = colorValue(bucket.id, property), border = "outline", borderWidth = 1 }),
    ui.button({ text = property == "background" and tr("background") or tr("text"), variant = "ghost", controlSize = "sm", flexGrow = 1, onClick = choose }),
    ui.button({ glyph = "clipboard", variant = "ghost", controlSize = "sm", tooltip = tr("paste"), onClick = paste }),
    ui.button({ glyph = "restore", variant = "ghost", controlSize = "sm", tooltip = tr("reset"), onClick = reset }),
  })
end

local function appearanceBody()
  local rows = {
    ui.label({ text = tr("customize_colors"), color = "on_surface_variant" }),
  }
  for _, bucket in ipairs(COLOR_BUCKETS) do
    table.insert(rows, ui.column({ key = "color-" .. bucket.id, gap = 5, paddingV = 4 }, {
      ui.label({ text = bucket.label, fontWeight = "medium" }),
      ui.row({ gap = 12, align = "center" }, {
        colorControl(bucket, "background"),
        colorControl(bucket, "text"),
      }),
    }))
  end
  local resetAll = callback("resetAllColors", function()
    preferences.colors = {}
    savePreferences()
    render()
  end)
  table.insert(rows, ui.separator({ spacing = 6 }))
  table.insert(rows, ui.row({ gap = 8, align = "center" }, {
    ui.button({ glyph = "restore", text = tr("reset_colors"), onClick = resetAll }),
  }))
  return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

local function renderHeader()
  local refreshClick = callback("refresh", function() refresh() end)
  local editMode = callback("editMode", function()
    view = view == "edit" and "bindings" or "edit"
    editingId = nil
    editDraft = ""
    render()
  end)
  local appearance = callback("appearance", function()
    view = view == "appearance" and "bindings" or "appearance"
    editingId = nil
    editDraft = ""
    render()
  end)
  local title = tr("title")
  if currentCompositor ~= "" then
    title = (currentCompositor == "mango" and "Mango" or (currentCompositor == "niri" and "Niri" or "Hyprland")) .. " Keymap"
  end
  local children = {
    ui.row({ minWidth = 230, gap = 7, align = "center", flexGrow = 1 }, {
      ui.glyph({ name = "keyboard", size = 16, color = "primary" }),
      ui.label({ text = title, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
    }),
  }
  if (view == "bindings" or view == "edit") and not loading and panelError == nil then
    local searchChanged = callback("search", function(value)
      query = value
      editingId = nil
      render()
    end)
    local clearSearch = callback("clearSearch", function()
      query = ""
      searchRevision += 1
      render()
    end)
    table.insert(children, ui.input({ key = "search-" .. searchRevision, value = query, placeholder = tr("search_placeholder"), controlSize = "sm", width = 300, onChange = searchChanged }))
    table.insert(children, ui.button({ glyph = "x", width = 26, variant = "ghost", controlSize = "sm", enabled = query ~= "", tooltip = tr("clear"), onClick = clearSearch }))
  end
  table.insert(children, ui.label({ text = tr("binding_count", { count = #bindings }), color = "on_surface_variant", fontSize = 12 }))
  if view == "edit" then
    local count = hiddenCount()
    local restoreHidden = callback("restoreHidden", function()
      restoreHiddenBindings(bindings, preferences.hidden)
      savePreferences()
      render()
    end)
    table.insert(children, ui.label({ text = tr("hidden_count", { count = count }), color = "on_surface_variant", fontSize = 12 }))
    table.insert(children, ui.button({ glyph = "eye", variant = "ghost", controlSize = "sm", enabled = count > 0, tooltip = tr("restore_hidden"), onClick = restoreHidden }))
  end
  table.insert(children, ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("refresh"), enabled = not loading, onClick = refreshClick }))
  table.insert(children, ui.button({ glyph = view == "edit" and "check" or "pencil", variant = "ghost", tooltip = view == "edit" and tr("finish_editing") or tr("edit_bindings"), selected = view == "edit", onClick = editMode }))
  table.insert(children, ui.button({ glyph = view == "appearance" and "check" or "palette", variant = "ghost", tooltip = view == "appearance" and tr("back") or tr("appearance"), selected = view == "appearance", onClick = appearance }))
  return ui.row({ align = "center", justify = "space_between", gap = 7 }, children)
end

render = function()
  if not panelOpen then return end
  resetCallbacks()
  local contentState = "bindings"
  if view == "appearance" then
    contentState = "appearance"
  elseif loading then
    contentState = "loading"
  elseif panelError ~= nil then
    contentState = "error"
  elseif view == "edit" then
    contentState = "edit"
  end
  local children = { renderHeader() }
  if view == "appearance" then
    table.insert(children, appearanceBody())
  elseif loading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 10 }, {
      ui.glyph({ name = "loader", size = 32, color = "primary" }),
      ui.label({ text = tr("loading"), color = "on_surface_variant" }),
    }))
  elseif panelError ~= nil then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 10 }, {
      ui.glyph({ name = "alert-triangle", size = 32, color = "error" }),
      ui.label({ text = panelError, color = "error", textAlign = "center", maxWidth = 640 }),
    }))
  else
    if #parseWarnings > 0 then
      table.insert(children, ui.label({ text = tr("source_warning") .. " " .. table.concat(parseWarnings, " | "), color = "error", fontSize = 11, maxLines = 2 }))
    end
    table.insert(children, bindingsBody())
  end
  panel.render(ui.column({ key = "keybind-cheatsheet-" .. contentState, flexGrow = 1, gap = 8, align = "stretch" }, children))
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
        table.insert(categories, binding.description == "" and tr("without_description") or (binding.category ~= "" and binding.category or tr("other")))
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

noctalia.state.watch("refresh_generation", function(_value)
  if panelOpen then refresh() end
end)

local function releasePanelState()
  panelOpen = false
  parseGeneration += 1
  bindings = {}
  parseWarnings = {}
  currentCompositor = ""
  panelError = nil
  loading = false
  refreshPending = false
  view = "bindings"
  query = ""
  editingId = nil
  editDraft = ""
  resetCallbacks()
end

function onOpen(_context)
  panelOpen = true
  loading = false
  refreshPending = false
  view = "bindings"
  query = ""
  searchRevision += 1
  editingId = nil
  editDraft = ""
  loadPreferences()
  refresh()
end

function onClose()
  releasePanelState()
end

function onExit(_signal)
  releasePanelState()
end

function onIpc(event, _payload)
  if event == "toggle" then
    if panelOpen then panel.close() else noctalia.togglePanel(PANEL_ID) end
  elseif event == "refresh" then
    if panelOpen then refresh() end
  elseif event == "self-test" then
    runSelfTest()
  end
end

local function lifecycleState()
  return {
    panelOpen = panelOpen,
    loading = loading,
    refreshPending = refreshPending,
    bindingCount = #bindings,
    callbackCount = #dynamicCallbacks,
    editDraft = editDraft,
  }
end

return {
  parseMangoContent = parseMangoContent,
  mangoCategoryFromComment = mangoCategoryFromComment,
  parseHyprContent = parseHyprContent,
  parseNiriContent = parseNiriContent,
  parseHyprJson = parseHyprJson,
  scanHyprLua = scanHyprLua,
  walkConfig = walkConfig,
  configReadError = configReadError,
  bindingAvailableInView = bindingAvailableInView,
  bindingContentOpacity = bindingContentOpacity,
  hiddenBindingCount = hiddenBindingCount,
  restoreHiddenBindings = restoreHiddenBindings,
  categoryPriority = categoryPriority,
  friendlyAction = friendlyAction,
  runSelfTest = runSelfTest,
  onOpen = onOpen,
  onClose = onClose,
  onExit = onExit,
  onIpc = onIpc,
  lifecycleState = lifecycleState,
}
