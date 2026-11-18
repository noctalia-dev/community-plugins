--!nonstrict
-- Icon theme panel.
--
-- bin/iconmgr.py owns every lookup, write and download; this file shells out
-- to it and draws the JSON it prints. The icons on screen are the theme's own
-- files - the host renders SVG - so what you see is what the theme ships.

local shared = require("./shared.luau")
local shellQuote, trim = shared.shellQuote, shared.trim

local PANEL_ID = "vn1k/icons:manager"
local ENGINE_TIMEOUT_MS = 60000 -- runAsync's maximum; `fetch` runs detached instead
local LIST_WIDTH = 220
local ICON = 40
local SWATCH = 28
local GROUPS = { "folders", "files", "apps", "system" }
local SORTS = { "popular", "new", "rating" }

local render
local loadThemes

-- ── state ───────────────────────────────────────────────────────────────────
-- Module globals outlive a close, so a reopen shows the last view at once.

local view = "installed"       -- "installed" | "more"
local busy = false
local status, statusTone = "", "on_surface_variant"
local refreshGen = 0           -- a refresh whose answer lands after a newer one is ignored

local themes = {}
local current = nil            -- `current` from the engine: theme, layers, consistent
local selected = ""
local specimens = {}           -- "theme|folder colour" -> groups
local folderInfo = {}          -- theme name -> { color (on disk), colors }
local pendingColor = {}        -- theme name -> folder colour picked, not yet applied
local failedLayers = {}        -- layer -> reason, from the last apply
local pendingRemove = ""
local openFamilies = {}        -- family parent -> open in the sidebar (absent: decided on load)
local pendingReset = false
local undone = false           -- after a reset every layer reads "not set"; that is the point

local query, sortIndex, page = "", 0, 0
local results = nil            -- nil = never searched; {} = searched, nothing found
local total = 0
local expanded = ""            -- gnome-look item id whose files are showing
local previews = {}            -- item id -> local path of its downloaded preview
local fetching = nil           -- { state = path, name = string, info = table } while a fetch runs
local fetchSeq = 0

local function tr(key)
  return noctalia.tr(key)
end

local function setStatus(text, tone)
  status = text
  statusTone = tone or "on_surface_variant"
end

local function fail(message)
  busy = false
  setStatus(message, "error")
  noctalia.notifyError(tr("title"), message)
  render()
end

-- ── engine ──────────────────────────────────────────────────────────────────

local function engine()
  local dir = noctalia.pluginDir()
  return shared.engine(dir .. "/bin/iconmgr.py")
end

-- Every subcommand answers with one JSON object, so a decode failure means the
-- engine itself is missing or broken rather than the request being invalid.
local function call(args, done)
  if not noctalia.commandExists("python3") then
    done(nil, tr("engine_missing"))
    return
  end
  noctalia.runAsync(`{engine()} {args}`, function(result)
    if result == nil then
      done(nil, tr("engine_missing"))
      return
    end
    if result.timedOut then
      done(nil, tr("engine_timeout"))
      return
    end
    local decoded = noctalia.json.decode(result.stdout or "")
    if type(decoded) ~= "table" then
      local stderr = trim(result.stderr)
      done(nil, stderr ~= "" and stderr or tr("engine_missing"))
      return
    end
    if not decoded.ok then
      done(nil, tostring(decoded.error or tr("error")))
      return
    end
    done(decoded, nil)
  end, ENGINE_TIMEOUT_MS)
end

-- ── small helpers ───────────────────────────────────────────────────────────

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

-- "kdeglobals" is a file name, not something a user has heard of.
local function layerName(name)
  local key = `layer_{name}`
  local label = tr(key)
  return (label ~= nil and label ~= key) and label or name
end

local function themeByName(name)
  for _, theme in ipairs(themes) do
    if theme.name == name then
      return theme
    end
  end
  return nil
end

-- Everything that uses `name`'s files, which Remove takes along with it.
local function dependents(name)
  local family, queue = {}, { name }
  while #queue > 0 do
    local current = table.remove(queue, 1)
    for _, theme in ipairs(themes) do
      if theme.name ~= name and table.find(theme.needs or {}, current) ~= nil
          and table.find(family, theme.name) == nil then
        table.insert(family, theme.name)
        table.insert(queue, theme.name)
      end
    end
  end
  return family
end

local function isBroken(theme)
  return theme ~= nil and #(theme.missing or {}) > 0
end

-- Under its parent "WhiteSur-light" only needs to say "Light".
local function childLabel(theme)
  local parent = themeByName(theme.parent)
  local base = parent ~= nil and parent.title or theme.parent
  local rest = theme.title
  if string.lower(string.sub(rest, 1, #base)) == string.lower(base) then
    rest = string.sub(rest, #base + 1)
  end
  rest = string.gsub(rest, "^[%-%s_]+", "")
  if rest == "" then
    return theme.title
  end
  return string.upper(string.sub(rest, 1, 1)) .. string.sub(rest, 2)
end

local function inUse(name)
  return current ~= nil and current.theme == name
end

local function compact(n)
  if n >= 1000000 then
    return string.format("%.1fM", n / 1000000)
  elseif n >= 1000 then
    return string.format("%dk", math.floor(n / 1000 + 0.5))
  end
  return tostring(n)
end

local function megabytes(kb)
  if kb >= 1024 then
    return string.format("%.1f MB", kb / 1024)
  end
  return `{kb} KB`
end

-- ── loading ─────────────────────────────────────────────────────────────────

local function loadFolders(name)
  local theme = themeByName(name)
  if theme == nil or (theme.folder_color or "") == "" or folderInfo[name] ~= nil then
    return
  end
  call(`folders {shellQuote(name)}`, function(result)
    if result ~= nil then
      folderInfo[name] = { color = result.color, colors = result.colors or {} }
      render()
    end
  end)
end

-- Specimens are optional decoration and never hold `busy`: the list and the
-- Use button work while the icons are still being looked up.
local function specimenKey(name)
  return `{name}|{pendingColor[name] or ""}`
end

local function loadSpecimen(name)
  if name == "" then
    return
  end
  loadFolders(name)
  local key = specimenKey(name)
  if specimens[key] ~= nil then
    return
  end
  -- A picked colour is previewed: the engine reads the other colour's icons
  -- off the links, and nothing on disk changes until Use.
  local color = pendingColor[name]
  local args = `specimen {shellQuote(name)}`
  if color ~= nil then
    args ..= ` --folder-color {shellQuote(color)}`
  end
  call(args, function(result)
    if result ~= nil then
      specimens[key] = result.groups or {}
      render()
    end
  end)
end

local function selectTheme(name)
  selected = name
  -- Keep the selection visible: a variant's family opens around it.
  local theme = themeByName(name)
  if theme ~= nil and theme.parent ~= "" and openFamilies[theme.parent] == nil then
    openFamilies[theme.parent] = true
  end
  pendingRemove = ""
  loadSpecimen(name)
  render()
end

loadThemes = function(keepSelection)
  refreshGen += 1
  local gen = refreshGen
  busy = true
  current = nil
  setStatus(tr("loading"))
  render()
  call("list", function(result, err)
    if gen ~= refreshGen then
      return
    end
    if result == nil then
      fail(err)
      return
    end
    themes = result.themes or {}
    call("current", function(cur)
      if gen ~= refreshGen then
        return
      end
      current = cur
      busy = false
      setStatus("")
      if not keepSelection or themeByName(selected) == nil then
        selected = (cur ~= nil and themeByName(cur.theme or "") ~= nil) and cur.theme
          or (themes[1] ~= nil and themes[1].name or "")
      end
      selectTheme(selected)
    end)
  end)
end

-- ── installed view ──────────────────────────────────────────────────────────

local CHEVRON = 22

-- One sidebar row. A family's head carries the chevron that folds its
-- variants; everything else gets a blank of the same width, so all the names
-- line up. Children sit one step further in and show only their own part.
local function themeRow(theme, isChild, children)
  local isSelected = theme.name == selected
  local open = openFamilies[theme.name] == true
  local broken = isBroken(theme)
  local lead
  if #children > 0 then
    lead = ui.button({
      key = `chev_{theme.name}_{open and "open" or "shut"}`,
      glyph = open and "chevron-down" or "chevron-right", variant = "ghost",
      width = CHEVRON, height = CHEVRON, glyphSize = 14,
      onClick = function()
        openFamilies[theme.name] = not open
        render()
      end,
    })
  else
    -- An empty column, not a ui.box: a box has a fill of its own, which showed
    -- as a dark square on the selected row.
    lead = ui.column({ width = isChild and CHEVRON + 14 or CHEVRON, height = CHEVRON }, {})
  end
  local tail = ui.box({ width = 0, height = 0 })
  if broken then
    tail = ui.glyph({ name = "alert-triangle", size = 14, color = "tertiary" })
  elseif inUse(theme.name) then
    tail = ui.glyph({ name = "check", size = 14, color = "primary" })
  end
  -- The state is in the key: the host keeps a prop that a later render merely
  -- leaves out, so a row that stopped being selected kept its fill.
  return ui.row({
    key = `theme_{theme.name}_{isSelected and "on" or "off"}`, gap = 4, align = "center",
    paddingH = 6, paddingV = 6, radius = 8, fill = isSelected and "surface_container" or nil,
    onClick = function() selectTheme(theme.name) end,
  }, {
    lead,
    ui.label({ text = isChild and childLabel(theme) or theme.title, fontSize = 13, maxLines = 1,
               flexGrow = 1, fontWeight = isSelected and "bold" or "normal",
               color = broken and "tertiary" or (isSelected and "on_surface" or "on_surface_variant") }),
    tail,
  })
end

local function themeList()
  -- Variants under their theme: WhiteSur > dark, light; Papirus > Dark, Light.
  local children, roots = {}, {}
  for _, theme in ipairs(themes) do
    if theme.parent ~= "" and themeByName(theme.parent) ~= nil then
      children[theme.parent] = children[theme.parent] or {}
      table.insert(children[theme.parent], theme)
    else
      table.insert(roots, theme)
    end
  end
  local rows = {}
  for _, theme in ipairs(roots) do
    local kids = children[theme.name] or {}
    table.insert(rows, themeRow(theme, false, kids))
    if openFamilies[theme.name] then
      for _, child in ipairs(kids) do
        table.insert(rows, themeRow(child, true, {}))
      end
    end
  end
  if #rows == 0 then
    rows = { ui.label({ text = busy and tr("loading") or tr("no_themes"), fontSize = 12,
                        color = "on_surface_variant" }) }
  end
  return ui.column({ width = LIST_WIDTH, gap = 8, align = "stretch" }, {
    ui.scroll({ flexGrow = 1, gap = 2 }, rows),
    ui.separator({}),
    ui.label({ text = tr("install_from"), fontSize = 12, color = "on_surface_variant" }),
    ui.button({ key = "pick_folder", text = tr("pick_folder"), glyph = "folder",
                variant = "outline", controlSize = "sm", enabled = not busy,
                onClick = "onPickFolder" }),
  })
end

local function iconCell(icon)
  if icon.path ~= "" then
    return ui.image({ key = `icon_{selected}_{icon.name}`, path = icon.path, width = ICON,
                      height = ICON, fit = "contain", tooltip = icon.name })
  end
  -- A gap, not a stand-in: the theme really does not have this icon.
  return ui.box({ width = ICON, height = ICON, radius = 8, border = "outline_variant", borderWidth = 1,
                  tooltip = `{icon.name}: {tr("missing_icon")}` })
end

-- The specimen sheet: the selected theme's own icons, by real category.
local function specimenSheet()
  local groups = specimens[specimenKey(selected)]
  local rows = {}
  for index, name in ipairs(GROUPS) do
    local group = groups ~= nil and groups[index] or nil
    local cells = { ui.label({ text = tr(`group_{name}`), fontSize = 12, minWidth = 72,
                               color = "on_surface_variant" }) }
    if group ~= nil then
      for _, icon in ipairs(group.icons) do
        table.insert(cells, iconCell(icon))
      end
    end
    table.insert(rows, ui.row({ key = `group_{name}`, gap = 18, align = "center",
                                minHeight = ICON }, cells))
  end
  return ui.column({ gap = 14, padding = 18, radius = 12, fill = "surface_container",
                     align = "stretch" }, rows)
end

-- Each swatch is that colour's own folder icon: the choice shows itself.
local function folderColors()
  local info = folderInfo[selected]
  if info == nil or #info.colors == 0 then
    return ui.box({ height = 0 })
  end
  local shown = pendingColor[selected] or info.color
  local swatches, rows = {}, {}
  for _, c in ipairs(info.colors) do
    -- Picked: a strong ring. Still on disk while another is picked: a faint
    -- one, so the way back is visible. State in the key, as in themeRow.
    local state = c.name == shown and "picked" or (c.name == info.color and "applied" or "plain")
    table.insert(swatches, ui.image({
      key = `swatch_{selected}_{c.name}_{state}`, path = c.path, width = SWATCH, height = SWATCH,
      fit = "contain", radius = 6,
      tooltip = state == "applied" and `{c.name} ({tr("applied_now")})` or c.name,
      border = state == "picked" and "primary" or (state == "applied" and "outline_variant" or nil),
      borderWidth = state == "plain" and 0 or (state == "picked" and 2 or 1),
      onClick = function() onFolderColor(c.name) end,
    }))
    if #swatches == 13 then
      table.insert(rows, ui.row({ gap = 6, align = "center" }, swatches))
      swatches = {}
    end
  end
  if #swatches > 0 then
    table.insert(rows, ui.row({ gap = 6, align = "center" }, swatches))
  end
  local pending = pendingColor[selected] ~= nil
  return ui.column({ gap = 8, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = `{tr("folder_color")}: {shown}`, fontSize = 12,
                 color = "on_surface_variant" }),
      pending and ui.label({ text = tr("applies_on_use"), fontSize = 12, color = "primary" })
        or ui.box({ width = 0, height = 0 }),
    }),
    ui.column({ gap = 6, align = "start" }, rows),
  })
end

local function warnings()
  local lines = {}
  local names = sortedKeys(failedLayers)
  if #names > 0 then
    table.insert(lines, ui.label({ text = tr("applied_partly"), fontSize = 12, color = "tertiary" }))
    for _, name in ipairs(names) do
      table.insert(lines, ui.label({ text = `{layerName(name)}: {failedLayers[name]}`,
                                     fontSize = 11, color = "tertiary", maxLines = 1 }))
    end
  elseif current ~= nil and not current.consistent and not undone and not busy then
    table.insert(lines, ui.label({ text = tr("drift"), fontSize = 12, color = "tertiary" }))
    for _, name in ipairs(sortedKeys(current.layers or {})) do
      local value = current.layers[name]
      if value ~= current.theme then
        table.insert(lines, ui.label({
          text = `{layerName(name)}: {value ~= "" and value or tr("not_set")}`,
          fontSize = 11, color = "tertiary", maxLines = 1 }))
      end
    end
  end
  if #lines == 0 then
    return ui.box({ height = 0 })
  end
  return ui.column({ gap = 2, align = "stretch" }, lines)
end

-- In use *and* every layer agrees: nothing to do, so no faded button that looks
-- broken. In use but drifted is exactly when Use is needed.
local function useNeeded()
  local theme = themeByName(selected)
  if theme == nil or isBroken(theme) then
    return false
  end
  return pendingColor[selected] ~= nil
    or not (inUse(selected) and current.consistent and next(failedLayers) == nil)
end

-- Secondary and destructive, so it stays small until asked for. Armed, it says
-- exactly what it will do and offers a way back out.
local function actionBar()
  if pendingReset then
    return ui.column({ key = "footer_reset", gap = 8, align = "stretch" }, {
      ui.label({ text = tr("reset_explain"), fontSize = 12, color = "on_surface_variant" }),
      ui.row({ gap = 8, align = "center" }, {
        ui.spacer({ flexGrow = 1 }),
        ui.button({ key = "reset_cancel", text = tr("cancel"), variant = "ghost", controlSize = "sm",
                    onClick = function()
                      pendingReset = false
                      render()
                    end }),
        ui.button({ key = "reset_confirm", text = tr("reset_confirm"), variant = "destructive",
                    controlSize = "sm", enabled = not busy, onClick = "onReset" }),
      }),
    })
  end
  -- The last row of the detail column: it lines up with Choose folder… across
  -- the panel, and the scroll above it means content can never cover it.
  return ui.row({ key = "footer_main", gap = 8, align = "center" }, {
    ui.label({ text = status, fontSize = 12, color = statusTone, maxLines = 1, flexGrow = 1 }),
    ui.button({ key = "reset", text = tr("reset"), glyph = "arrow-back-up", variant = "ghost",
                controlSize = "sm", enabled = not busy,
                onClick = function()
                  pendingReset = true
                  render()
                end }),
    useNeeded() and ui.button({ key = "use", text = tr("use"), variant = "primary",
                                enabled = not busy, onClick = "onUse" })
      or ui.box({ width = 0, height = 0 }),
  })
end

local function detail()
  local theme = themeByName(selected)
  if theme == nil then
    return ui.column({ flexGrow = 1, align = "stretch" }, { ui.spacer({ flexGrow = 1 }), actionBar() })
  end
  local armed = pendingRemove == theme.name
  local family = dependents(theme.name)
  local familyInUse = false
  for _, name in ipairs(family) do
    familyInUse = familyInUse or inUse(name)
  end
  local confirm = #family > 0
    and string.gsub(string.gsub(tr("confirm_remove_family"), "{name}", theme.title), "{n}", tostring(#family))
    or tr("confirm_remove")
  local header = {
    ui.label({ text = theme.title, fontSize = 22, fontWeight = "bold", maxLines = 1,
               flexGrow = 1 }),
  }
  if inUse(theme.name) then
    table.insert(header, ui.label({ text = tr("in_use"), fontSize = 12, color = "primary" }))
  end
  if theme.removable then
    table.insert(header, ui.button({
      key = `remove_{armed and "armed" or "idle"}`, text = armed and confirm or nil,
      glyph = not armed and "trash" or nil, variant = armed and "destructive" or "ghost",
      controlSize = "sm", tooltip = familyInUse and tr("in_use_family") or tr("remove"),
      enabled = not busy and not inUse(theme.name) and not familyInUse,
      onClick = function()
        if armed then
          onRemove(theme.name)
        else
          pendingRemove = theme.name
          render()
        end
      end,
    }))
  end
  -- Scrolls, so a long comment, all 25 Papirus colors and a drift warning
  -- together never spill over the footer. The title stays put above it.
  return ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
    ui.row({ gap = 10, align = "center" }, header),
    isBroken(theme)
      -- Its specimen would be all gaps: say what is wrong and what to do instead.
      and ui.column({ key = "broken", flexGrow = 1, gap = 8, align = "stretch" }, {
        ui.label({ text = string.gsub(tr("missing_files"), "{name}", table.concat(theme.missing, ", ")),
                   fontSize = 13, color = "tertiary" }),
        -- In use, it cannot be removed - and every icon on screen is broken now.
        inUse(theme.name)
          and ui.label({ text = tr("missing_in_use"), fontSize = 13, color = "on_surface" })
          or ui.box({ height = 0 }),
      })
      or ui.scroll({ key = "sheet", flexGrow = 1, gap = 14 }, {
        (theme.comment or "") ~= "" and ui.label({ text = theme.comment, fontSize = 12, maxLines = 2,
                                                   color = "on_surface_variant" })
          or ui.box({ height = 0 }),
        specimenSheet(),
        folderColors(),
        warnings(),
      }),
    actionBar(),
  })
end


-- Each view and footer variant has its own key. Without one, switching tabs put
-- a column where a row had been, and the host reused the old node with its old
-- size: Get more's list came up a few rows tall until the next render.
local function installedView()
  return ui.row({ key = "view_installed", flexGrow = 1, gap = 20, align = "stretch" }, {
    themeList(),
    detail(),
  })
end

-- ── get more view ───────────────────────────────────────────────────────────

local function previewFor(item)
  local path = previews[item.id]
  if path ~= nil then
    return ui.image({ key = `preview_{item.id}`, path = path, width = 128, height = 90,
                      fit = "cover", radius = 8 })
  end
  return ui.box({ width = 128, height = 90, radius = 8, fill = "surface_container" })
end

local function loadPreview(item)
  local data = noctalia.pluginDataDir()
  if previews[item.id] ~= nil or item.preview == "" or data == nil then
    return
  end
  local dest = `{data}/preview-{item.id}.jpg`
  if noctalia.fileExists(dest) then
    previews[item.id] = dest
    return
  end
  noctalia.download(item.preview, dest, function(ok)
    if ok then
      previews[item.id] = dest
      render()
    end
  end)
end

local function fileRows(item)
  if #item.files == 0 then
    return { ui.label({ text = tr("no_files"), fontSize = 12, color = "on_surface_variant" }) }
  end
  local rows = {}
  for _, file in ipairs(item.files) do
    table.insert(rows, ui.row({ key = `file_{item.id}_{file.index}`, gap = 10, align = "center" }, {
      ui.label({ text = file.name, fontSize = 12, maxLines = 1, flexGrow = 1 }),
      ui.label({ text = megabytes(file.kb), fontSize = 11, color = "on_surface_variant" }),
      ui.button({ text = tr("install"), glyph = "download", variant = "outline",
                  controlSize = "sm", enabled = fetching == nil,
                  onClick = function() onFetch(item, file) end }),
    }))
  end
  return rows
end

local function resultRow(item)
  local open = expanded == item.id
  local children = {
    ui.row({ gap = 14, align = "center",
             onClick = function()
               expanded = open and "" or item.id
               render()
             end }, {
      previewFor(item),
      ui.column({ gap = 4, flexGrow = 1, align = "stretch" }, {
        ui.label({ text = item.name, fontSize = 14, fontWeight = "bold", maxLines = 1 }),
        ui.label({ text = `{tr("by")} {item.author}`, fontSize = 12, maxLines = 1,
                   color = "on_surface_variant" }),
        ui.label({ text = `{compact(item.downloads)} {tr("downloads")}`, fontSize = 12,
                   color = "on_surface_variant" }),
      }),
      ui.glyph({ name = open and "chevron-up" or "chevron-down", size = 16,
                 color = "on_surface_variant" }),
    }),
  }
  if open then
    table.insert(children, ui.column({ gap = 6, paddingH = 4, align = "stretch" }, fileRows(item)))
  end
  return ui.column({ key = `item_{item.id}_{open and "open" or "shut"}`, gap = 10, padding = 8,
                     radius = 10,
                     fill = open and "surface_container" or nil, align = "stretch" }, children)
end

local function progressLine()
  if fetching == nil then
    return ui.box({ height = 0 })
  end
  local info, text = fetching.info or {}, tr("downloading")
  if info.state == "installing" then
    text = tr("installing")
  elseif (info.total or 0) > 0 then
    text = `{tr("downloading")} {fetching.name}  {megabytes(math.floor(info.done / 1024))} / {megabytes(math.floor(info.total / 1024))}`
  else
    text = `{tr("downloading")} {fetching.name}…`
  end
  return ui.label({ text = text, fontSize = 12, color = "primary" })
end

local function moreView()
  local list = {}
  if busy and (results == nil or #results == 0) then
    list = { ui.label({ text = tr("searching"), fontSize = 12, color = "on_surface_variant" }) }
  elseif results == nil then
    -- Only "Searching" while a search really runs; otherwise say what to do.
    list = { ui.label({ text = tr("search_hint"), fontSize = 12, color = "on_surface_variant" }) }
  elseif #results == 0 then
    list = { ui.label({ text = tr("no_results"), fontSize = 12, color = "on_surface_variant" }) }
  else
    for _, item in ipairs(results) do
      table.insert(list, resultRow(item))
    end
  end
  local pages = math.max(1, math.ceil(total / 20))
  return ui.column({ key = "view_more", flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "query", placeholder = tr("search_placeholder"), value = query,
                 flexGrow = 1, onChange = "onQueryChange", onSubmit = "onSearch" }),
      ui.select({ key = "sort", options = { tr("sort_popular"), tr("sort_new"), tr("sort_rating") },
                  selectedIndex = sortIndex, width = 140, onChange = "onSortChange" }),
      ui.button({ key = "search", text = tr("search"), glyph = "search", variant = "outline",
                  enabled = not busy, onClick = "onSearch" }),
    }),
    progressLine(),
    ui.scroll({ flexGrow = 1, gap = 6 }, list),
    -- The last row of the view, like Installed's action bar: what is going on
    -- (a failed search, say) takes the count's place, so no extra row hangs
    -- below the pagination.
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = status ~= "" and status or `{total} {tr("results")}`, fontSize = 12,
                 color = status ~= "" and statusTone or "on_surface_variant", maxLines = 1,
                 flexGrow = 1 }),
      ui.button({ key = "prev", text = tr("previous"), variant = "ghost", controlSize = "sm",
                  enabled = not busy and page > 0, onClick = "onPrevPage" }),
      ui.label({ text = `{tr("page")} {page + 1} / {pages}`, fontSize = 12,
                 color = "on_surface_variant" }),
      ui.button({ key = "next", text = tr("next"), variant = "ghost", controlSize = "sm",
                  enabled = not busy and page + 1 < pages, onClick = "onNextPage" }),
    }),
  })
end

-- ── frame ───────────────────────────────────────────────────────────────────

local function viewButton(id, labelKey)
  return ui.button({ key = `view_{id}`, text = tr(labelKey),
                     variant = view == id and "primary" or "ghost", controlSize = "sm",
                     onClick = function() onView(id) end })
end


render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 16, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      viewButton("installed", "view_installed"),
      viewButton("more", "view_more"),
      ui.button({ key = "reload", glyph = "refresh", variant = "ghost", tooltip = tr("reload"),
                  enabled = not busy, onClick = "onReload" }),
      ui.button({ key = "close", glyph = "close", variant = "ghost", tooltip = tr("close"),
                  onClick = "onCloseClicked" }),
    }),
    view == "installed" and installedView() or moreView(),
  }))
end

-- ── the picker ──────────────────────────────────────────────────────────────
-- zenity takes focus and the panel closes, so the pick is fire-and-forget: the
-- shell stashes the path and reopens the panel, and onOpen picks it up.

local function stashPath()
  local dir = noctalia.pluginDataDir()
  return dir ~= nil and `{dir}/pick` or nil
end

-- Folders only: an archive from disk is the user's to extract, so nothing is
-- unpacked behind their back. Get more's downloads are the one exception.
local function pick()
  local stash = stashPath()
  if not noctalia.commandExists("zenity") or stash == nil then
    fail(tr("picker_missing"))
    return
  end
  -- `;` before panel-open, not `&&`: cancelling must still bring the panel back.
  noctalia.runAsync(
    `p=$(zenity --file-selection --directory --title={shellQuote(tr("install_from"))}`
      .. ` --filename={shellQuote(noctalia.expandPath("~/Downloads") .. "/")})`
      .. ` && printf '%s' "$p" > {shellQuote(stash)}`
      .. `; noctalia msg panel-open {shellQuote(PANEL_ID)}`
  )
end

local function install(path)
  busy = true
  setStatus(tr("installing"))
  render()
  call(`install {shellQuote(path)}`, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    local names = table.concat(result.installed, ", ")
    setStatus(`{tr("installed")} {names}`, "primary")
    noctalia.notify(tr("title"), `{tr("installed")} {names}`)
    specimens, folderInfo = {}, {}
    selected = result.installed[1] or selected
    view = "installed"
    loadThemes(true)
  end)
end

-- ── handlers ────────────────────────────────────────────────────────────────

function onOpen(_context)
  pendingReset, pendingRemove = false, ""
  -- A download may have finished while the panel was closed.
  if fetching ~= nil then
    panel.setWantsSecondTicks(true)
    update()
    if fetching ~= nil then
      render()
      return
    end
  end
  local stash = stashPath()
  if stash ~= nil and noctalia.fileExists(stash) then
    local path = trim(noctalia.readFile(stash))
    noctalia.removeFile(stash)
    if path ~= "" then
      install(path)
      return
    end
  end
  loadThemes(true)
end

function onCloseClicked()
  panel.close()
end

function onReload()
  specimens, folderInfo = {}, {}
  if view == "more" then
    onSearch()
  else
    loadThemes(true)
  end
end

function onView(id)
  view = id
  pendingReset = false
  if id == "more" and results == nil then
    onSearch()
    return
  end
  render()
end

function onPickFolder()
  pick()
end

-- Use's second half: the picked folder colour, written to the theme's links.
local function applyFolderColor(name, done)
  local color = pendingColor[name]
  if color == nil then
    done(true)
    return
  end
  setStatus(tr("recoloring"))
  render()
  call(`folders {shellQuote(name)} {shellQuote(color)}`, function(result, err)
    if result == nil then
      fail(err)
      done(false)
      return
    end
    pendingColor[name] = nil
    folderInfo[name] = { color = result.color, colors = result.colors or {} }
    -- The links now point at the new colour; the old cache keys are stale.
    specimens[specimenKey(name)] = nil
    loadSpecimen(name)
    done(true)
  end)
end

function onUse()
  if busy or selected == "" then
    return
  end
  busy = true
  failedLayers = {}
  setStatus(tr("applying"))
  render()
  local name, color = selected, pendingColor[selected]
  call(`apply {shellQuote(name)}`, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    undone = false
    failedLayers = type(result.failed) == "table" and result.failed or {}
    applyFolderColor(name, function(ok)
      if not ok then
        return
      end
      busy = false
      local failed = {}
      for _, layer in ipairs(sortedKeys(failedLayers)) do
        table.insert(failed, layerName(layer))
      end
      local done = color ~= nil and `{tr("now_using")} {name}, {color} {tr("folders_word")}`
        or `{tr("now_using")} {name}`
      if #failed > 0 then
        setStatus(`{tr("applied_partly")} {table.concat(failed, ", ")}`, "tertiary")
      else
        setStatus(done, "primary")
      end
      noctalia.notify(tr("title"), done)
      call("current", function(cur)
        current = cur or current
        render()
      end)
    end)
  end)
end

-- Picking a colour is a preview, like picking a theme: nothing is written
-- until Use. Picking the colour already on disk drops the pick.
function onFolderColor(color)
  local info = folderInfo[selected]
  if busy or info == nil then
    return
  end
  pendingColor[selected] = color ~= info.color and color or nil
  loadSpecimen(selected)
  render()
end


function onRemove(name)
  if busy then
    return
  end
  busy = true
  pendingRemove = ""
  call(`remove {shellQuote(name)}`, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    local removed = type(result.removed) == "table" and result.removed or { name }
    setStatus(`{tr("removed")} {table.concat(removed, ", ")}`, "primary")
    for _, gone in ipairs(removed) do
      folderInfo[gone], openFamilies[gone] = nil, nil
    end
    specimens = {}
    loadThemes(true)
  end)
end

function onReset()
  if busy then
    return
  end
  busy = true
  pendingReset = false
  pendingColor = {}
  setStatus(tr("resetting"))
  render()
  call("uninstall", function(result, err)
    if result == nil then
      fail(err)
      return
    end
    undone = true
    failedLayers = {}
    setStatus(tr("reset_done"), "primary")
    noctalia.notify(tr("title"), tr("reset_done"))
    -- Follow the theme that is now actually in use, not the old pick.
    loadThemes(false)
  end)
end

-- ── get more handlers ───────────────────────────────────────────────────────

function onQueryChange(value)
  query = value
end

function onSortChange(index, _text)
  sortIndex = tonumber(index) or 0
  page = 0
  onSearch()
end

function onSearch(value)
  if type(value) == "string" then
    query = value
  end
  busy = true
  expanded = ""
  results = results or {}
  setStatus(tr("searching"))
  render()
  local args = `browse --sort {SORTS[sortIndex + 1]} --page {page}`
  if trim(query) ~= "" then
    args ..= ` --query {shellQuote(trim(query))}`
  end
  call(args, function(result, err)
    busy = false
    if result == nil then
      results = {}
      setStatus(err, "error")
      render()
      return
    end
    results, total = result.items or {}, result.total or 0
    setStatus("")
    for _, item in ipairs(results) do
      loadPreview(item)
    end
    render()
  end)
end

function onPrevPage()
  page = math.max(0, page - 1)
  onSearch()
end

function onNextPage()
  page += 1
  onSearch()
end

-- Downloads run detached: a 30 MB theme can outlast runAsync's 60 s. The
-- engine writes its progress to a file, which update() reads.
function onFetch(item, file)
  local data = noctalia.pluginDataDir()
  if fetching ~= nil or data == nil then
    return
  end
  fetchSeq += 1
  local state = `{data}/fetch-{fetchSeq}.json`
  fetching = { state = state, name = file.name, info = { state = "starting" } }
  -- A panel's update() only runs on ticks it asks for; setUpdateInterval is
  -- the bar's, and with it this poll never ran and the panel sat on
  -- "Downloading" while the theme had long been installed.
  panel.setWantsSecondTicks(true)
  noctalia.runAsync(`{engine()} fetch {shellQuote(item.id)} {file.index}`
    .. ` --state {shellQuote(state)} > /dev/null 2>&1`)
  render()
end

function update()
  if fetching == nil or not noctalia.fileExists(fetching.state) then
    return
  end
  local info = noctalia.json.decode(noctalia.readFile(fetching.state) or "")
  if type(info) ~= "table" then
    return
  end
  fetching.info = info
  if info.state ~= "done" then
    render()
    return
  end
  noctalia.removeFile(fetching.state)
  fetching = nil
  panel.setWantsSecondTicks(false)
  local result = info.result or {}
  if not result.ok then
    fail(tostring(result.error or tr("error")))
    return
  end
  local names = table.concat(result.installed or {}, ", ")
  noctalia.notify(tr("title"), `{tr("installed")} {names}`)
  setStatus(`{tr("installed")} {names}`, "primary")
  specimens, folderInfo = {}, {}
  selected = (result.installed or {})[1] or selected
  view = "installed"
  loadThemes(true)
end
