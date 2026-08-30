--!nonstrict
-- Lists Remmina connection profiles in the launcher and opens the selected one
-- with `remmina -c <profile>`.
--
-- A profile is a small INI file in the Remmina data directory; only name,
-- group, protocol, server and username are read. Passwords stay untouched:
-- they are encrypted in the profile and Remmina itself resolves them.

local PROFILE_SUFFIX = ".remmina"
local DEFAULT_PROFILES_PATH = "~/.local/share/remmina"

-- Profiles are parsed once and reused until the directory's mtime changes, so
-- typing in the launcher never re-reads the disk.
local cache = nil
local cacheStamp = nil

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function profilesPath()
  local configured = noctalia.getConfig("profiles_path")
  if type(configured) == "string" and trim(configured) ~= "" then
    return noctalia.expandPath(trim(configured))
  end
  return noctalia.expandPath(DEFAULT_PROFILES_PATH)
end

local function maxResults()
  local n = noctalia.getConfig("max_results")
  return (type(n) == "number" and n > 0) and math.floor(n) or 30
end

local function showGroup()
  local value = noctalia.getConfig("show_group")
  return value ~= false
end

local function statusRow(title, subtitle, glyph)
  return { id = "", title = title, subtitle = subtitle, glyph = glyph }
end

-- Remmina writes one lowercase `key=value` per line, no sections that matter
-- here and no quoting, so a plain split is enough.
local function parseProfile(content)
  local fields = {}
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^(%w+)=(.*)$")
    if key ~= nil then
      fields[key:lower()] = trim(value)
    end
  end
  return fields
end

-- Tabler icon names, as shipped by the host (Commons/IconsTabler.qml); a name
-- the set does not have renders as nothing and only warns in the log.
local GLYPHS = {
  RDP = "device-desktop",
  VNC = "screen-share",
  SPICE = "device-desktop",
  X2GO = "device-desktop",
  NX = "device-desktop",
  SSH = "terminal",
  TELNET = "terminal-2",
  SFTP = "folder",
  WWW = "world-www",
  EXEC = "terminal-2",
}

local function glyphFor(protocol)
  return GLYPHS[protocol] or "device-desktop"
end

-- "user@host · RDP", with the group in front when the setting asks for it and
-- the profile actually has one.
local function subtitleFor(profile)
  local parts = {}
  if showGroup() and profile.group ~= "" then
    table.insert(parts, profile.group)
  end
  local target = profile.server
  if profile.username ~= "" and target ~= "" then
    target = profile.username .. "@" .. target
  end
  if target ~= "" then
    table.insert(parts, target)
  end
  if profile.protocol ~= "" then
    table.insert(parts, profile.protocol)
  end
  return table.concat(parts, " · ")
end

local function loadProfiles()
  local directory = profilesPath()
  local entries, err = noctalia.listDir(directory)
  if entries == nil then
    return nil, err
  end

  local profiles = {}
  for _, entry in ipairs(entries) do
    if entry:sub(-#PROFILE_SUFFIX) == PROFILE_SUFFIX then
      -- listDir may hand back bare names or full paths depending on the host;
      -- only prepend the directory when the entry is not already absolute.
      local path = entry:sub(1, 1) == "/" and entry or (directory .. "/" .. entry)
      local content = noctalia.readFile(path)
      if type(content) == "string" and content ~= "" then
        local fields = parseProfile(content)
        local name = fields.name ~= nil and fields.name or ""
        if name == "" then
          -- Fall back to the file name so a profile is never invisible.
          name = (entry:match("([^/]+)$") or entry):sub(1, -#PROFILE_SUFFIX - 1)
        end
        table.insert(profiles, {
          path = path,
          name = name,
          group = fields.group or "",
          protocol = (fields.protocol or ""):upper(),
          server = fields.server or "",
          username = fields.username or "",
        })
      end
    end
  end

  table.sort(profiles, function(a, b)
    if a.group ~= b.group then
      return a.group:lower() < b.group:lower()
    end
    return a.name:lower() < b.name:lower()
  end)
  return profiles, nil
end

local function directoryStamp()
  local info = noctalia.fileInfo(profilesPath())
  return info ~= nil and tostring(info.mtime) or nil
end

local function profiles()
  local stamp = directoryStamp()
  if cache ~= nil and stamp == cacheStamp then
    return cache, nil
  end
  local loaded, err = loadProfiles()
  if loaded == nil then
    return nil, err
  end
  cache = loaded
  cacheStamp = stamp
  return cache, nil
end

local function scoreFor(filter, profile)
  for _, text in ipairs({ profile.name, profile.group, profile.server, profile.protocol }) do
    if text ~= "" then
      local score = noctalia.fuzzyScore(filter, text)
      if score then
        return score
      end
    end
  end
  return nil
end

local function makeRows(list, filter)
  local rows = {}
  local limit = maxResults()
  for _, profile in ipairs(list) do
    local score = filter == "" and nil or scoreFor(filter, profile)
    if filter == "" or score ~= nil then
      table.insert(rows, {
        id = profile.path,
        title = profile.name,
        subtitle = subtitleFor(profile),
        glyph = glyphFor(profile.protocol),
        score = score,
      })
      if #rows >= limit then
        break
      end
    end
  end
  return rows
end

function onQuery(query)
  local filter = trim(query)

  if not noctalia.commandExists("remmina") then
    launcher.setResults(query, {
      statusRow(noctalia.tr("err-no-remmina"), noctalia.tr("err-no-remmina-subtitle"), "alert-triangle"),
    })
    return
  end

  local list, err = profiles()
  if list == nil then
    launcher.setResults(query, {
      statusRow(noctalia.tr("profiles-missing"), err ~= nil and err or profilesPath(), "file-x"),
    })
    return
  end

  local rows = makeRows(list, filter)
  if #rows == 0 then
    launcher.setResults(query, {
      statusRow(
        noctalia.tr("no-profiles-found"),
        filter ~= "" and noctalia.tr("filter-empty", { filter = filter }) or noctalia.tr("profiles-empty"),
        "device-desktop"
      ),
    })
    return
  end

  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == "" then
    return
  end
  -- argv form: the profile path carries spaces, @ and parentheses, and must
  -- stay one argument.
  if not noctalia.runAsync({ "remmina", "-c", id }) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err-launch"))
  end
end
