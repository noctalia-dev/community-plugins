--!nonstrict
-- User folders (user-dirs.dirs) and default applications (mimeapps.list), with a searchable app picker.
local kit = require("../ui/kit.luau")
local files = require("../pages/files.luau")

local M = {}

local FOLDERS = {
  { "DESKTOP", "Desktop" }, { "DOCUMENTS", "Documents" }, { "DOWNLOAD", "Downloads" }, { "MUSIC", "Music" },
  { "PICTURES", "Pictures" }, { "VIDEOS", "Videos" }, { "TEMPLATES", "Templates" },
  { "PUBLICSHARE", "Public share" }, { "PROJECTS", "Projects" },
}
local ROLE_ORDER = { "Web browser", "Email client", "File manager", "Text editor", "Image viewer", "PDF viewer",
                     "Audio player", "Video player" }
local ROLE_GLYPHS = { ["Web browser"] = "world", ["Email client"] = "mail", ["File manager"] = "folder",
                      ["Text editor"] = "file-text", ["Image viewer"] = "photo", ["PDF viewer"] = "file-type-pdf",
                      ["Audio player"] = "music", ["Video player"] = "movie" }

local MIME_ROWS = 50  -- other file types listed at most (each row is a card with two buttons)

local function loading(ctx, title)
  ctx.loadDesktop()
  local content = { ctx.desktopError and kit.notice(ctx.desktopError, "error", nil, "desktop-error")
                    or kit.loading() }
  return { header = { kit.header(ctx, title) }, content = content }
end

-- Icon theme lookups are slow in Noctalia (25 ms per callback; a miss can take several ms): cache them and
-- resolve a few per render within a time budget, asking for another frame while some are still missing.
local ICON_LOOKUPS_PER_RENDER = 6
local ICON_BUDGET_MS = 6
local iconCache = {}

local function clock()
  return noctalia.nowMs and noctalia.nowMs() or nil
end

local function iconLookup()
  local lookup = { left = ICON_LOOKUPS_PER_RENDER, pending = false, start = clock() }
  function lookup.icon(id)
    if not noctalia.appIconPath or not id or id == "" or id == "<multiple>" then return nil end
    local cached = iconCache[id]
    if cached ~= nil then return cached or nil end
    local now = lookup.left < ICON_LOOKUPS_PER_RENDER and lookup.start and clock()
    if lookup.left <= 0 or (now and now - lookup.start >= ICON_BUDGET_MS) then
      lookup.pending = true
      return nil
    end
    lookup.left = lookup.left - 1
    local path = noctalia.appIconPath((string.gsub(id, "%.desktop$", "")), 32)
    iconCache[id] = path or false
    return path
  end
  function lookup.finish(ctx)
    if lookup.pending then ctx.renderSoon() end
  end
  return lookup
end

local function appName(apps, id)
  if not id or id == "" then return nil end
  for _, app in ipairs(apps.apps) do
    if app.id == id then return app.name end
  end
  return apps.names and apps.names[id] or id
end

-- "Name  ·  id", or just the id when no name is known (never the id twice)
local function appLine(apps, id)
  local name = appName(apps, id)
  return name == id and id or (name .. "  ·  " .. id)
end

local function validFolder(value)
  if value == "" then return true end
  if not (string.sub(value, 1, 1) == "/" or value == "$HOME" or string.sub(value, 1, 6) == "$HOME/") then
    return false, "Use an absolute path or $HOME/…"
  end
  local rest = string.sub(value, 1, 5) == "$HOME" and string.sub(value, 6) or value
  if string.find(rest, '[$`"\\\r\n]') then return false, "The path contains unsupported characters." end
  return true
end

local function foldersPage(ctx)
  local store, view = ctx.store, ctx.view
  if not store.desktop then return loading(ctx, "User folders") end
  local dirs = store.desktop.userdirs
  local header = { kit.header(ctx, "User folders", "Where apps put downloads, documents, pictures… Folders are not created.") }
  local content = {}
  local keys = {}
  for _, item in ipairs(FOLDERS) do keys[item[1]] = item[2] end
  local list = {}
  for _, item in ipairs(FOLDERS) do table.insert(list, item) end
  for key in pairs(dirs.values) do
    if not keys[key] then table.insert(list, { key, string.sub(key, 1, 1) .. string.lower(string.sub(key, 2)) }) end
  end
  for _, item in ipairs(list) do
    local key, label = item[1], item[2]
    local value = dirs.values[key] or ""
    local ok, problem = validFolder(value)
    local badges = {}
    if value ~= (dirs.original[key] or "") then table.insert(badges, kit.badge("unsaved", "primary", "fb-" .. key)) end
    local rows = {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = label, fontSize = kit.FONT.body, fontWeight = "bold", flexGrow = 1 }),
        ui.row({ gap = 4 }, badges),
      }),
      ui.row({ gap = 6, align = "center" }, {
        ui.input({ key = "fold-" .. key .. "-" .. ctx.gen("fold-" .. key), value = value, flexGrow = 1,
                   controlSize = "sm", placeholder = "Not set",
                   onChange = function(text) store.setDesktop("userdirs", key, text); ctx.render() end }),
        ui.button({ text = "Browse…", glyph = "folder-open", controlSize = "sm", variant = "outline",
                    onClick = function()
                      files.open(ctx, { mode = "folder", title = "Choose the " .. label .. " folder", start = value },
                        function(path)
                          store.setDesktop("userdirs", key, path)
                          ctx.bump("fold-" .. key)
                        end)
                    end }),
      }),
    }
    if not ok then table.insert(rows, kit.notice(problem, "error", nil, "fe-" .. key)) end
    table.insert(content, kit.card({ key = "folder-" .. key }, rows))
  end
  return { header = header, content = content }
end

local function appsPage(ctx)
  local store, view = ctx.store, ctx.view
  if not store.desktop then return loading(ctx, "Default apps") end
  local apps = store.desktop.apps
  local header = { kit.header(ctx, "Default apps", "Which app opens links and files. Other fallbacks are kept.", {
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Rescan installed apps",
                onClick = function()
                  if store.desktopChanges() then ctx.flash("Save or discard desktop changes before rescanning.", "warning")
                  else ctx.loadDesktop(true) end
                end }),
  }) }
  local content = { kit.section("Common roles") }
  local icons = iconLookup()
  for _, role in ipairs(ROLE_ORDER) do
    local value = apps.roles[role] or ""
    local subtitle = value == "<multiple>" and "Different apps for different file types"
      or (value ~= "" and appLine(apps, value)) or "Not set"
    local badges = {}
    if value ~= (apps.originalRoles[role] or "") then table.insert(badges, kit.badge("unsaved", "primary", "rb-" .. role)) end
    local icon = icons.icon(value)
    table.insert(content, kit.navRow({ key = "role-" .. role, image = icon or nil, glyph = ROLE_GLYPHS[role],
      title = role, subtitle = subtitle, badges = badges, onClick = function()
        ctx.go({ name = "appPicker", kind = "role", target = role })
      end }))
  end
  icons.finish(ctx)
  table.insert(content, kit.section("Other file types"))
  table.insert(content, kit.filterBox(ctx, "mimeFilter", { placeholder = "Filter file types or apps" }))
  local function addMime(mime)
    mime = noctalia.string.trim(mime or "")
    for _, managed in ipairs(apps.roleMimes or {}) do
      if string.lower(managed) == string.lower(mime) then
        ctx.flash("That type is set through a common role above.", "warning"); return
      end
    end
    view.addedMimes = view.addedMimes or {}
    view.addedMimes[mime] = true  -- listed while unassigned; only picking an app is an edit
    ctx.bump("mimeAdd")
    ctx.go({ name = "appPicker", kind = "mime", target = mime })
  end
  table.insert(content, kit.nameForm(ctx, "mimeAdd", "Add a MIME type (text/markdown) or extension (.md)", "Add",
    function(text)
      if text == "" then return end
      if string.find(text, "/", 1, true) then addMime(text); return end
      ctx.helper.call("extension", { extension = text }, function(err, data)
        if err then ctx.flash(err.error, "warning") else addMime(data.mime) end
      end)
    end))
  local filter = kit.filterText(ctx, "mimeFilter")
  local names = {}
  for mime in pairs(apps.mimes) do table.insert(names, mime) end
  for mime in pairs(view.addedMimes or {}) do
    if apps.mimes[mime] == nil then table.insert(names, mime) end
  end
  table.sort(names)
  local appNames = {}
  for id, name in pairs(apps.names or {}) do appNames[id] = name end
  for _, app in ipairs(apps.apps) do appNames[app.id] = app.name end
  local extensions = apps.extensions or {}
  local listStart = #content + 1
  local shown = 0
  for _, mime in ipairs(names) do
    local value = apps.mimes[mime] or ""
    local name = value ~= "" and (appNames[value] or value) or nil
    local exts = extensions[mime] or ""
    if shown < MIME_ROWS and (filter == "" or kit.contains(table.concat({ mime, exts, value, name or "" }, " "), filter)) then
      shown = shown + 1
      table.insert(content, kit.rowCard({ key = "mime-" .. mime, gap = 6, align = "center", paddingH = 12, paddingV = 6,
                                          radius = kit.RADIUS.md }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = exts ~= "" and (mime .. "  ·  " .. exts) or mime, fontSize = kit.FONT.body }),
          kit.muted(name and (name == value and value or (name .. "  ·  " .. value)) or "Removed when you save"),
        }),
        ui.button({ text = "Change", controlSize = "sm", variant = "outline",
                    onClick = function() ctx.go({ name = "appPicker", kind = "mime", target = mime }) end }),
        kit.iconButton("trash", "Remove this association", function()
          if view.addedMimes then view.addedMimes[mime] = nil end
          store.setDesktop("mimes", mime, "")
          ctx.render()
        end, value ~= "" or (view.addedMimes or {})[mime] == true),
      }))
    end
  end
  if shown == MIME_ROWS then
    table.insert(content, listStart, kit.muted("Showing " .. MIME_ROWS .. " file types; filter to find others."))
  end
  return { header = header, content = content }
end

-- Kind `command` (autostart Browse…, `view.pick` from fields.luau): the app's command goes to `pick.onChosen`.
local function pickerPage(ctx, route)
  local store, view = ctx.store, ctx.view
  local command = route.kind == "command"
  local pick = command and view.pick
  if command and not pick then return { header = { kit.header(ctx, "Choose an app") }, content = {} } end
  if not store.desktop then return loading(ctx, "Choose an app") end
  local apps = store.desktop.apps
  local current = route.kind == "role" and apps.roles[route.target] or apps.mimes[route.target]
  if command then current = nil end
  local search = kit.filterBox(ctx, "appQuery", { focus = true, flexGrow = command and 1 or nil,
                                                 placeholder = "Search installed apps" })
  if command then  -- any other program: next to the search, not below the list
    search = ui.row({ key = "app-search-row", gap = 6, align = "center" }, { search,
      ui.button({ key = "app-file", text = "Browse files…", glyph = "folder-open", controlSize = "sm",
                  variant = "outline", tooltip = "Choose a program or script",
                  onClick = function() files.open(ctx, pick.options, pick.onChosen, true) end }) })
  end
  local header = { kit.header(ctx, "Choose an app", route.target), search }
  local function choose(id)
    if command then
      if view.appCommandBusy then return end
      view.appCommandBusy = true
      ctx.helper.call("app-command", { id = id }, function(err, data)
        view.appCommandBusy = false
        if view.pick ~= pick then return end
        if err then ctx.flash(err.error, "warning"); ctx.render(); return end
        view.pick, view.appQuery = nil, ""
        pick.onChosen(data.command)
        ctx.back()
      end)
      return
    end
    store.setDesktop(route.kind == "role" and "roles" or "mimes", route.target, id)
    view.appQuery, view.appManual = "", nil
    ctx.back()
  end
  local query = kit.filterText(ctx, "appQuery")
  local content = {}
  local shown = 0
  local icons = iconLookup()
  for _, app in ipairs(apps.apps) do
    if shown < kit.LIST_CAP and (query == "" or kit.contains(app.name .. " " .. app.id, query)) then
      shown = shown + 1
      local icon = icons.icon(app.id)
      table.insert(content, kit.navRow({ key = "app-" .. app.id, image = icon or nil, glyph = "apps",
        title = app.name, subtitle = app.id, trailing = app.id == current and "check" or "chevron-right",
        fill = app.id == current and "primary_container" or nil, onClick = function() choose(app.id) end }))
    end
  end
  icons.finish(ctx)
  if shown == kit.LIST_CAP then table.insert(content, kit.muted("Type to find more apps.")) end
  if shown == 0 then table.insert(content, kit.empty("No installed app matches.", "apps")) end
  if command then return { header = header, content = content } end
  table.insert(content, kit.section("Or enter a desktop file ID"))
  table.insert(content, ui.row({ key = "app-manual", gap = 6 }, {
    ui.input({ key = "app-id-" .. route.kind .. "-" .. route.target, value = current ~= "<multiple>" and current or "",
               flexGrow = 1, controlSize = "sm", placeholder = "e.g. org.gnome.Nautilus.desktop",
               onChange = function(text) view.appManual = { target = route.target, text = text } end,
               onSubmit = function(text) choose(noctalia.string.trim(text)) end }),
    ui.button({ text = "Use", controlSize = "sm", variant = "outline",
                onClick = function()
                  local typed = view.appManual and view.appManual.target == route.target and view.appManual.text
                  choose(noctalia.string.trim(typed or current or ""))
                end }),
  }))
  return { header = header, content = content }
end

function M.render(ctx, route)
  if route.name == "folders" then return foldersPage(ctx) end
  if route.name == "appPicker" then return pickerPage(ctx, route) end
  return appsPage(ctx)
end

return M
