-- Default Apps manager panel.
-- Reads current XDG MIME defaults with `xdg-mime query`, enumerates installed
-- desktop entries that declare each MIME type, and applies changes with
-- `xdg-mime default`. No state is persisted by the plugin itself; the system
-- mimeapps.list is the source of truth.

local tr = noctalia.tr

local CATEGORIES = {
  { key = "browser",  glyph = "world",      mimes = { "x-scheme-handler/http", "x-scheme-handler/https" } },
  { key = "mail",     glyph = "mail",       mimes = { "x-scheme-handler/mailto" }, categories = { "Email" } },
  { key = "calendar", glyph = "calendar",   mimes = { "text/calendar", "x-scheme-handler/webcal" }, categories = { "Calendar" } },
  { key = "files",    glyph = "folder",     mimes = { "inode/directory" }, categories = { "FileManager" } },
  { key = "music",    glyph = "music",      mimes = { "audio/mpeg", "audio/flac", "audio/ogg", "audio/x-wav" }, categories = { "Audio", "Music", "Player" } },
  { key = "video",    glyph = "device-tv",  mimes = { "video/mp4", "video/x-matroska", "video/webm" }, categories = { "Video", "Player" } },
  { key = "photos",   glyph = "photo",      mimes = { "image/png", "image/jpeg", "image/webp", "image/gif" }, categories = { "Graphics", "2DGraphics", "Viewer" } },
  { key = "editor",   glyph = "pencil",     mimes = { "text/plain" }, categories = { "TextEditor" } },
  { key = "pdf",      glyph = "file-text",  mimes = { "application/pdf" }, categories = { "Viewer", "Office" } },
  { key = "archive",  glyph = "archive",    mimes = { "application/zip", "application/x-tar", "application/x-7z-compressed", "application/x-xz", "application/vnd.rar" }, categories = { "Archiver", "Compression" } },
  { key = "word",     glyph = "file-text",  mimes = { "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/msword", "application/vnd.oasis.opendocument.text" }, categories = { "Office", "WordProcessor" } },
  { key = "torrent",  glyph = "download",   mimes = { "application/x-bittorrent", "x-scheme-handler/magnet" }, categories = { "P2P", "FileTransfer" } },
}

local SCAN_DIRS = {
  "~/.local/share/applications",
  "/usr/local/share/applications",
  "/usr/share/applications",
  "~/.local/share/flatpak/exports/share/applications",
  "/var/lib/flatpak/exports/share/applications",
}

-- Non-FHS systems (Guix, Nix, ...) keep desktop entries outside the paths
-- above, exposed instead through a user profile symlink. We discover those
-- generically via XDG_DATA_DIRS, with a Guix-specific fallback in case
-- XDG_DATA_DIRS wasn't populated for this session.
local function getScanDirs()
  local dirs = {}
  local seen = {}
  local function add(dir)
    if dir ~= nil and dir ~= "" and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end

  for _, dir in ipairs(SCAN_DIRS) do
    add(dir)
  end

  local xdgDataDirs = noctalia.getenv("XDG_DATA_DIRS")
  if xdgDataDirs ~= nil then
    for dir in string.gmatch(xdgDataDirs, "[^:]+") do
      add(dir .. "/applications")
    end
  end

  -- Fallback for Guix sessions where XDG_DATA_DIRS doesn't include the
  -- profile (e.g. not sourced from a login shell).
  local guixProfile = noctalia.getenv("GUIX_PROFILE")
  if guixProfile ~= nil then
    add(guixProfile .. "/share/applications")
  end

  local guixEnvironment = noctalia.getenv("GUIX_ENVIRONMENT")
  if guixEnvironment ~= nil then
    add(guixEnvironment .. "/share/applications")
  end

  return dirs
end

-- 'pending' tracks unsaved dropdown changes until Apply is clicked.
local state = { ready = false, defaults = {}, candidates = {}, pending = {} }
local loadingStatus = noctalia.tr("panel.init")

local function parseDesktopFile(text)
  local app = { name = nil, mimes = {}, categories = {}, hidden = false }
  local inMainEntry = false
  for line in string.gmatch(text, "[^\r\n]+") do
    if string.match(line, "^%[Desktop Entry%]") then
      inMainEntry = true
    elseif string.match(line, "^%[") then
      inMainEntry = false
    end
    if inMainEntry then
      local key, value = string.match(line, "^%s*([%w-]+)%s*=%s*(.-)%s*$")
      if key ~= nil and value ~= nil then
        if key == "Name" then
          app.name = value
        elseif key == "MimeType" then
          for mime in string.gmatch(value, "[^;]+") do
            app.mimes[mime] = true
          end
        elseif key == "Categories" then
          for category in string.gmatch(value, "[^;]+") do
            app.categories[category] = true
          end
        elseif key == "Hidden" then
          app.hidden = (value == "true")
        end
      end
    end
  end
  return app
end

local function isCandidateForCategory(app, cat)
  -- Browsers legitimately advertise support for many file types. Outside the
  -- browser picker, do not treat that broad support as a primary app role.
  if cat.key ~= "browser" and app.categories.WebBrowser then
    return false
  end
  if cat.categories == nil then
    return true
  end
  for _, category in ipairs(cat.categories) do
    if app.categories[category] then
      return true
    end
  end
  return false
end

local function render()
  if not state.ready then
    panel.render(ui.column({ padding = 24, align = "center", justify = "center", fill = 1, flexGrow = 1 }, {
      ui.glyph({ name = "loader-2", size = 24, color = "primary" }),
      ui.label({ text = loadingStatus, color = "on_surface/0.7" }),
    }))
    return
  end

  local hasPending = false
  for _, _ in pairs(state.pending) do
    hasPending = true
    break
  end

  local rows = {}
  for _, cat in ipairs(CATEGORIES) do
    local currentId = state.pending[cat.key] or state.defaults[cat.key]
    local candidates = state.candidates[cat.key] or {}

    local options = {}
    local selectedIndex = -1
    for i, app in ipairs(candidates) do
      table.insert(options, app.name)
      if app.id == currentId then
        selectedIndex = i - 1
      end
    end

    local titleChildren = {
      ui.label({ text = tr("category." .. cat.key), fontSize = 14, fontWeight = "bold" })
    }

    if currentId == nil or selectedIndex < 0 then
      table.insert(titleChildren, ui.label({ text = tr("panel.none"), fontSize = 11, color = "on_surface/0.5" }))
    end

    table.insert(rows, ui.row({
      key = "cat-" .. cat.key,
      fill = 1,
      width = "100%",
      align = "center",
      justify = "space_between",
      paddingV = 12,
      paddingH = 20,
    }, {
      ui.row({ gap = 16, align = "center" }, {
        ui.glyph({ name = cat.glyph, size = 20, color = "primary" }),
        ui.column({ gap = 2, align = "start", justify = "center" }, titleChildren),
      }),

      ui.select({
        key = "sel-" .. cat.key,
        options = options,
        selectedIndex = selectedIndex,
        placeholder = tr("panel.pick"),
        width = 220,
        controlSize = "sm",
        enabled = #candidates > 0,
        onChange = function(value)
          local selectedAppId = candidates[tonumber(value) + 1].id
          if selectedAppId == state.defaults[cat.key] then
            state.pending[cat.key] = nil
          else
            state.pending[cat.key] = selectedAppId
          end
          render()
        end,
      }),
    }))
    table.insert(rows, ui.separator({ spacing = 4 }))
  end

  panel.render(ui.column({
    paddingV = 16,
    gap = 2,
    fill = 1,
    flexGrow = 1,
    width = "100%",
    align = "stretch",
  }, {
    ui.row({ width = "100%", fill = 1, align = "center", justify = "space_between", paddingV = 8, paddingH = 20 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "primary" }),
      ui.button({
        text = noctalia.tr("panel.apply"),
        variant = hasPending and "primary" or "ghost",
        enabled = hasPending,
        onClick = applyChanges
      }),
    }),
    ui.scroll({ width = "100%", fill = 1, flexGrow = 1, gap = 4 }, rows),
  }))
end

function applyChanges()
  local toApply = {}
  for catKey, appId in pairs(state.pending) do
    table.insert(toApply, { catKey = catKey, appId = appId })
  end
  if #toApply == 0 then return end

  state.ready = false
  loadingStatus = noctalia.tr("panel.applying")
  render()

  local pendingCount = #toApply

  for _, change in ipairs(toApply) do
    local cat = nil
    for _, c in ipairs(CATEGORIES) do
      if c.key == change.catKey then
        cat = c
        break
      end
    end

    if cat then
      local argv = { "xdg-mime", "default", change.appId }
      for _, mime in ipairs(cat.mimes) do
        table.insert(argv, mime)
      end

      noctalia.runAsync(argv, function(result)
        if result.exitCode ~= 0 then
          noctalia.notifyError(tr("panel.set_failed"), change.appId)
        end
        pendingCount = pendingCount - 1
        if pendingCount <= 0 then
          state.pending = {}
          queryDefaults()
        end
      end)
    else
      pendingCount = pendingCount - 1
      if pendingCount <= 0 then
        state.pending = {}
        queryDefaults()
      end
    end
  end
end

local function scanCandidatesAsync(onDone)
  local seen = {}
  local queue = {}
  loadingStatus = noctalia.tr("panel.locating")
  render()
  for _, dir in ipairs(getScanDirs()) do
    local abs = noctalia.expandPath(dir)
    local names = noctalia.listDir(abs)
    if names ~= nil then
      table.sort(names)
      for _, file in ipairs(names) do
        if string.sub(file, -8) == ".desktop" and not seen[file] then
          seen[file] = true
          table.insert(queue, { file = file, path = abs .. "/" .. file })
        end
      end
    end
  end
  local result = {}
  for _, cat in ipairs(CATEGORIES) do
    result[cat.key] = {}
  end
  local nextIndex = 1
  local function finish()
    loadingStatus = noctalia.tr("panel.sorting")
    render()
    for _, cat in ipairs(CATEGORIES) do
      table.sort(result[cat.key], function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    end
    onDone(result)
  end
  local function step()
    while nextIndex <= #queue do
      local entry = queue[nextIndex]
      nextIndex = nextIndex + 1
      loadingStatus = noctalia.tr("panel.reading") .. entry.file
      render()
      local accepted = noctalia.readFileAsync(entry.path, function(text)
        if text ~= nil then
          local app = parseDesktopFile(text)
          if app.name ~= nil and not app.hidden then
            for _, cat in ipairs(CATEGORIES) do
              if isCandidateForCategory(app, cat) then
                for _, mime in ipairs(cat.mimes) do
                  if app.mimes[mime] then
                    table.insert(result[cat.key], { id = entry.file, name = app.name })
                    break
                  end
                end
              end
            end
          end
        end
        step()
      end)
      if accepted then
        return
      end
    end
    finish()
  end
  if #queue == 0 then
    finish()
  else
    step()
  end
end

function queryDefaults()
  state.ready = false
  local nextIndex = 1
  local function step()
    if nextIndex > #CATEGORIES then
      state.ready = true
      render()
      return
    end
    local cat = CATEGORIES[nextIndex]
    nextIndex = nextIndex + 1
    loadingStatus = noctalia.tr("panel.querying") .. cat.key
    render()
    noctalia.runAsync({ "xdg-mime", "query", "default", cat.mimes[1] }, function(result)
      if result.exitCode == 0 then
        local id = noctalia.string.trim(result.stdout)
        if id == "" then
          id = nil
        end
        state.defaults[cat.key] = id
      else
        state.defaults[cat.key] = nil
      end
      step()
    end)
  end
  step()
end

function refresh()
  state.ready = false
  loadingStatus = "Starting scan..."
  render()
  scanCandidatesAsync(function(candidates)
    state.candidates = candidates
    queryDefaults()
  end)
end

function onOpen(_context)
  refresh()
end

function onClose()
  -- Discard any picks that were never applied, so a stale draft never
  -- silently resurfaces (and becomes applicable) the next time the panel opens.
  state.pending = {}
end
