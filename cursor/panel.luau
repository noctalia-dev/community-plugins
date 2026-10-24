--!nonstrict
-- Cursor theme panel.
--
-- Every cursor file and every config write belongs to the curmgr CLI; this
-- file only shells out to it and renders the JSON it prints. That split keeps
-- binary parsing and five-layer config writing out of a sandboxed script, and
-- means the same engine works from a keybind without the shell running.

local PANEL_ID = "vn1k/cursor:manager"
local SIZES = { 16, 20, 24, 28, 32, 40, 48, 64, 96, 128 }
local COLUMNS = 2
local PANEL_WIDTH = 780
local PANEL_PADDING = 28 -- Style::panelPadding * 2 on the host surface
local GRID_GAP = 12
local STRIP_HEIGHT = 56

local tab = "themes"
local themes = {}
local previews = {} -- theme name -> { path, stamp } of its rendered strip
local selected = ""
local sizeIndex = 2 -- 24
local hideTyping = false
local hideMs = ""
local busy = false
-- "import" or "build": a Browse pick waiting to be scanned once the theme list
-- refresh lets go of `busy` (doImport/doBuild return early while it is set).
local pendingScan = nil
-- Bumped by every loadThemes(). A refresh started by an earlier open whose
-- callbacks land late must not clear `busy`, run the queued scan or keep
-- rendering previews over the newer one.
local refreshGen = 0
local status = ""
local statusTone = "on_surface_variant"
local current = nil

local importPath, importName = "", ""
local importShadow = false
local buildPath, buildName = "", ""
-- No name field: an installed theme carries its own name. `curmgr install
-- --name` still exists for the CLI when two themes would collide.
local installPath = ""
-- Deleting a theme is destructive and a dialog would dismiss the panel, so the
-- confirmation is the button itself: first click arms, second click removes.
local pendingRemove = ""
-- Reset to system cursor undoes everything the plugin wrote. Armed the same
-- way as Remove, but with its consequences spelled out and a way back out.
local pendingReset = false
-- After a reset every place reads "not set" or the system default, which is
-- the point - so the drift warning stays quiet until the next apply.
local undone = false
-- Layers the last apply could not write (name -> reason). "Applied" alone hid
-- a read-only settings.ini until the drift warning turned up later.
local failedLayers = {}
-- Import and Build each get their own report: they used to share one global,
-- which is how a Windows import's mapping grid ended up rendering under Build
-- too - both tabs called the same reportView() off the same variable.
local importReport = nil
local buildReport = nil
-- Manual role mapping, built from the last scan's `files`/`role_previews`.
-- Import and Build each get their own: one shared set is what put the Windows
-- grid under Build in the first place, and both tabs can hold a grid at once.
--   mapping  role -> relpath, survives a re-run so a fix sticks
--   files    every source file the engine rendered, the strip under the grid
--   roles    grid order: mapped first, then the ones nothing claimed
--   previews role -> what the engine says that role currently holds
--   target   the role tile clicked, waiting for a file tile to pair it with
--   scanned  the path this grid belongs to; different from the field means
--            nothing has been scanned yet and the button offers a scan
--   serial   bumped per run. The engine rewrites the same cache paths every
--            time and the host caches textures by path, so a tile would keep
--            painting the last run's art unless its image node changes key.
--            Same trick screen-toolkit uses.
local function newMapState(id)
  return { tab = id, mapping = {}, files = {}, roles = {}, previews = {},
           target = "", scanned = "", serial = 0 }
end
local maps = { import = newMapState("import"), build = newMapState("build") }
-- ui.input only reads `value` when it mounts, so a path chosen by the picker
-- needs a new key to land in the field at all.
local pickSeq = 0
-- The role names are win2xcur's, not English: `size_nwse` says nothing about
-- which corner it drags. Every role tile carries its description as a tooltip,
-- and this toggles the same strings as a visible list - hover alone is not a
-- thing anyone discovers. One flag for both grids: it is the same list.
local mapHelp = false

local render
local loadThemes

local function tr(key)
  return noctalia.tr(key)
end

local shared = require("./shared.luau")
local shellQuote, trim = shared.shellQuote, shared.trim
local configString, pathEnv = shared.configString, shared.pathEnv

-- The engine ships inside the plugin, so a store install needs nothing on
-- PATH; the setting only exists for a checkout that keeps curmgr elsewhere.
local function engine()
  local override = configString("engine_path", "")
  if override ~= "" then
    return shellQuote(noctalia.expandPath(override))
  end
  local dir = noctalia.pluginDir()
  if type(dir) == "string" and dir ~= "" then
    return `python3 -B {shellQuote(dir .. "/bin/curmgr.py")}`
  end
  return "curmgr"
end

local function imageArgs()
  return ` --sizes {shellQuote(configString("build_sizes", "24,32,48,64,96"))}`
    .. ` --filter {shellQuote(configString("scale_filter", "lanczos"))}`
end

-- runAsync's default is 5s, and Noctalia kills the process when it runs out. An
-- animated Windows pack at five sizes takes about that long, so it got killed
-- halfway. 60s is the maximum runAsync allows.
-- ponytail: a pack slower than 60s still times out; runStream has no limit if
-- one ever does.
local ENGINE_TIMEOUT_MS = 60000

-- Every subcommand answers with one JSON object, so a decode failure means the
-- engine itself is missing or broken rather than the request being invalid.
local function call(args, done)
  if configString("engine_path", "") == "" and not noctalia.commandExists("python3") then
    done(nil, tr("engine_missing"))
    return
  end
  noctalia.runAsync(`{pathEnv()}{engine()} {args}`, function(result)
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

-- ── file picker ─────────────────────────────────────────────────────────────
-- Opening zenity takes keyboard focus, and a Noctalia panel dismisses when it
-- loses focus, so the panel is gone before the user has picked anything. The
-- pick is therefore fire-and-forget rather than a runAsync callback: the shell
-- stashes the chosen path in the plugin data dir and reopens the panel itself,
-- which also dodges the 60s ceiling runAsync puts on a callback.

local function stashPath(field)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return `{dir}/pick-{field}`
end

local function startDir(current)
  local path = trim(current)
  if path ~= "" then
    return noctalia.expandPath(path)
  end
  -- Trailing slash so zenity opens inside the folder rather than selecting it.
  return noctalia.expandPath("~/Downloads") .. "/"
end

-- Every tab takes a folder: extract an archive first. The engine refuses
-- archives outright rather than unpacking them.
local function pick(field, current)
  if not noctalia.commandExists("zenity") then
    fail(tr("picker_missing"))
    return
  end
  local stash = stashPath(field)
  if stash == nil then
    fail(tr("picker_missing"))
    return
  end
  -- `;` before panel-open, not `&&`: cancelling must still bring the panel back.
  noctalia.runAsync(
    `p=$(zenity --file-selection --directory --title={shellQuote(tr("pick_folder"))}`
      .. ` --filename={shellQuote(startDir(current))}) && printf '%s' "$p" > {shellQuote(stash)}`
      .. `; noctalia msg panel-open {shellQuote(PANEL_ID)}`
  )
end

-- Called on every open: a stash file means the user just came back from a dialog.
local function consumePick(field, apply)
  local stash = stashPath(field)
  if stash == nil or not noctalia.fileExists(stash) then
    return
  end
  local contents = noctalia.readFile(stash)
  noctalia.removeFile(stash)
  local path = trim(contents)
  if path ~= "" then
    apply(path)
    pickSeq += 1
  end
end

local function sizeValue()
  return SIZES[sizeIndex + 1] or 24
end

local function selectSize(value)
  for index, size in ipairs(SIZES) do
    if size == value then
      sizeIndex = index - 1
      return
    end
  end
  -- A size set outside this panel would otherwise leave the previous choice
  -- showing, and Apply would silently change it. Adopt it instead.
  table.insert(SIZES, value)
  table.sort(SIZES)
  for index, size in ipairs(SIZES) do
    if size == value then
      sizeIndex = index - 1
      return
    end
  end
end

-- Previews are rendered one at a time: each is a fresh process, and a theme
-- with a hundred cursors is still under a second.
-- Previews are optional decoration and don't hold `busy`: the list is usable,
-- and a queued Browse scan runs, as soon as `list` and `current` are in.
local function loadPreviews(index, gen)
  local theme = themes[index]
  if theme == nil or gen ~= refreshGen then
    return
  end
  call(`preview {shellQuote(theme.name)}`, function(result, err)
    if gen ~= refreshGen then
      return
    end
    if result ~= nil then
      previews[theme.name] = { path = result.preview, stamp = tostring(result.stamp or "") }
      render()
    elseif index == 1 then
      -- Previews are optional: without wand the panel still lists and applies
      -- themes, so explain the blank strips rather than failing the panel. Only
      -- the first theme reports; a missing dependency fails all of them.
      setStatus(err, "tertiary")
    end
    loadPreviews(index + 1, gen)
  end)
end

local function loadCurrent(done)
  call("current", function(result)
    if result ~= nil then
      current = result
      if selected == "" then
        selected = result.theme or ""
      end
      selectSize(tonumber(result.size) or 24)
      hideTyping = result.hide_when_typing == true
      local ms = tonumber(result.hide_after_inactive_ms) or 0
      hideMs = ms > 0 and tostring(ms) or ""
    end
    if done ~= nil then
      done()
    end
  end)
end

loadThemes = function()
  refreshGen += 1
  local gen = refreshGen
  busy = true
  -- Panel state outlives a close, so a reopen would otherwise draw last
  -- session's drift warning until the refresh lands.
  current = nil
  setStatus(tr("loading"))
  render()
  call("list", function(result, err)
    if gen ~= refreshGen then
      return
    end
    if result == nil then
      pendingScan = nil
      fail(err)
      return
    end
    themes = result.themes or {}
    setStatus("")
    loadCurrent(function()
      if gen ~= refreshGen then
        return
      end
      busy = false
      render()
      local scan = pendingScan
      pendingScan = nil
      if scan == "import" then
        onScanImport()
      elseif scan == "build" then
        onScanBuild()
      end
      loadPreviews(1, gen)
    end)
  end)
end

-- ── rendering ───────────────────────────────────────────────────────────────

local function tileWidth()
  return math.floor((PANEL_WIDTH - PANEL_PADDING - GRID_GAP * (COLUMNS - 1)) / COLUMNS)
end

local function themeTile(theme)
  local isSelected = theme.name == selected
  local width = tileWidth()
  local preview = previews[theme.name]
  local border = isSelected and "primary" or "outline"
  local borderWidth = isSelected and 3 or 1
  local onClick = function()
    selected = theme.name
    render()
  end

  local frame
  if preview ~= nil then
    -- Keyed on the stamp: a re-rendered strip lands on the same path, and an
    -- unchanged key would keep the host's cached texture (see serial).
    frame = ui.image({
      key = `strip_{theme.name}_{preview.stamp}`,
      width = width, height = STRIP_HEIGHT, path = preview.path, fit = "contain",
      radius = 12, border = border, borderWidth = borderWidth, onClick = onClick,
    })
  else
    frame = ui.box({
      width = width, height = STRIP_HEIGHT, fill = "surface_variant",
      radius = 12, border = border, borderWidth = borderWidth, onClick = onClick,
    })
  end

  local caption = theme.title or theme.name
  if current ~= nil and current.theme == theme.name then
    caption = `{caption}  ·  {tr("active")}`
  end

  return ui.column({ gap = 4, key = theme.name, flexGrow = 1, align = "center" }, {
    frame,
    ui.label({
      text = caption, fontSize = 12, maxLines = 1, maxWidth = width,
      textAlign = "center",
      color = isSelected and "on_surface" or "on_surface_variant",
      fontWeight = isSelected and "bold" or "normal",
    }),
  })
end

local function themeGrid()
  if #themes == 0 then
    return ui.label({ text = busy and tr("loading") or tr("no_themes"), color = "on_surface_variant" })
  end
  local rows, row = {}, {}
  for index, theme in ipairs(themes) do
    table.insert(row, themeTile(theme))
    if #row == COLUMNS or index == #themes then
      table.insert(rows, ui.row({ gap = GRID_GAP, align = "stretch" }, row))
      row = {}
    end
  end
  return ui.column({ gap = GRID_GAP, align = "stretch" }, rows)
end

local function sizeLabels()
  local labels = {}
  for index, size in ipairs(SIZES) do
    labels[index] = tostring(size)
  end
  return labels
end

-- pairs() order is not stable, and these lines would reshuffle on every render.
local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

-- "xdg_default" is how the engine names a layer, not something a user has ever
-- heard of. A missing translation (a new compositor) falls back to the name.
local function layerName(name)
  local key = `layer_{name}`
  local label = tr(key)
  return (label ~= nil and label ~= key) and label or name
end

-- The value most layers agree on. Deliberately not current.theme: that is the
-- first compositor's value, so when the compositor is the one that drifted it
-- would name every *other* layer as the odd one out.
local function majorityTheme(layers)
  local counts, best, bestCount = {}, "", 0
  for _, value in pairs(layers) do
    counts[value] = (counts[value] or 0) + 1
    if counts[value] > bestCount then
      best, bestCount = value, counts[value]
    end
  end
  return best
end

-- The whole point of the plugin: one theme name written to every layer. If a
-- layer drifted, name it - the engine already sends the per-layer values, and
-- "something disagrees" sends the user to the terminal to find out which.
local function driftWarning()
  if current == nil or current.consistent or busy or current.layers == nil or undone then
    return ui.box({ height = 0 })
  end
  local expected = majorityTheme(current.layers)
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "alert-triangle", color = "tertiary", size = 16 }),
      ui.label({ text = tr("drift"), fontSize = 12, color = "tertiary", flexGrow = 1 }),
    }),
  }
  -- Only the layers that disagree: this sits above the theme grid in a 640px
  -- panel, so listing all of them would push the grid off the bottom.
  for _, name in ipairs(sortedKeys(current.layers)) do
    local value = current.layers[name]
    if value ~= expected then
      table.insert(rows, ui.label({
        text = ("%s: %s"):format(layerName(name), value ~= "" and value or tr("not_set")),
        fontSize = 11, color = "tertiary",
      }))
    end
  end
  return ui.column({ gap = 2, align = "stretch" }, rows)
end

-- What the last apply could not write, and why. A layer this box simply does
-- not have (no flatpak, no gsettings) is never in here: the engine skips it.
local function failedWarning()
  local names = sortedKeys(failedLayers)
  if #names == 0 or busy then
    return ui.box({ height = 0 })
  end
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "alert-triangle", color = "tertiary", size = 16 }),
      ui.label({ text = tr("applied_partly"), fontSize = 12, color = "tertiary", flexGrow = 1 }),
    }),
  }
  for _, name in ipairs(names) do
    table.insert(rows, ui.label({ text = `{layerName(name)}: {failedLayers[name]}`, fontSize = 11,
                                  color = "tertiary", maxLines = 1 }))
  end
  return ui.column({ gap = 2, align = "stretch" }, rows)
end

-- Secondary and destructive, so it stays small until asked for. Armed, it says
-- exactly what it will do before the second click does it.
local function resetFooter()
  if not pendingReset then
    return ui.row({ gap = 8, align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
      ui.button({ key = "reset", text = tr("reset"), glyph = "arrow-back-up",
                  variant = "ghost", controlSize = "sm", enabled = not busy,
                  onClick = function()
                    pendingReset = true
                    render()
                  end }),
    })
  end
  return ui.column({ gap = 8, align = "stretch" }, {
    ui.label({ text = tr("reset_explain"), fontSize = 12, color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
      ui.button({ key = "reset_cancel", text = tr("cancel"), variant = "ghost",
                  controlSize = "sm",
                  onClick = function()
                    pendingReset = false
                    render()
                  end }),
      ui.button({ key = "reset_confirm", text = tr("reset_confirm"), variant = "destructive",
                  controlSize = "sm", enabled = not busy, onClick = "onReset" }),
    }),
  })
end

local function themesTab()
  return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    failedWarning(),
    driftWarning(),
    -- ui.scroll centres content shorter than its viewport, so a one-theme list
    -- sits mid-panel. It fills from the top as soon as the grid is taller.
    ui.scroll({ flexGrow = 1, gap = GRID_GAP }, { themeGrid() }),
    ui.separator({}),
    ui.row({ gap = 12, align = "center" }, {
      ui.label({ text = tr("size"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({ key = "size", options = sizeLabels(), selectedIndex = sizeIndex,
                  onChange = "onSizeChange", width = 96 }),
      ui.button({ key = "hide_typing", text = tr("hide_when_typing"),
                  variant = hideTyping and "primary" or "outline",
                  onClick = "onToggleHideTyping" }),
      ui.input({ key = "hide_ms", placeholder = tr("hide_after_ms"), value = hideMs,
                 width = 150, onChange = "onHideMsChange" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ key = "apply", text = tr("apply"), variant = "primary",
                  onClick = "onApply", enabled = not busy and selected ~= "" }),
    }),
    resetFooter(),
  })
end

local MAP_TILE = 44
local MAP_COLUMNS = 10

-- Rows of fixed-width tiles, wrapped at `columns` per row. Both the role grid
-- and the file strip below it use this; only the tile contents differ.
local function wrapTiles(tiles, columns)
  local rows, row = {}, {}
  for index, tile in ipairs(tiles) do
    table.insert(row, tile)
    if #row == columns or index == #tiles then
      table.insert(rows, ui.row({ gap = 8, align = "start" }, row))
      row = {}
    end
  end
  return ui.column({ gap = 8, align = "stretch" }, rows)
end

-- Shared by both the click-to-arm flow and a drag-and-drop, so a file always
-- lands the same way regardless of which gesture placed it.
local function assign(st, role, rel)
  st.mapping[role] = rel
  st.target = ""
  render()
end

local function mapRoleTile(st, role, byRel)
  local tip = tr(`role_{role}`)
  local isArmed = st.target == role
  local override = st.mapping[role]
  local border = isArmed and "primary" or (override ~= nil and "tertiary" or "outline")
  -- An override is a pending intent: the engine only re-renders role previews
  -- on the next convert, so show the assigned file's own thumbnail meanwhile.
  -- Without this the tile keeps last convert's art (or stays empty) until the
  -- user converts again, which makes a drop look like it did nothing.
  local preview = override ~= nil and byRel[override] or st.previews[role]
  local onClick = function()
    if st.target == role then
      -- second click on an armed role clears any override, back to the guess
      st.mapping[role] = nil
      st.target = ""
    else
      st.target = role
    end
    render()
  end
  -- Tooltip on frame *and* label: the host ignores a prop a node type does not
  -- know, and an empty role - the one most in need of explaining - is a box,
  -- not an image.
  local frame
  if preview ~= nil then
    frame = ui.image({ key = `role_img_{st.tab}_{role}_{st.serial}_{override or "auto"}`,
                       width = MAP_TILE, height = MAP_TILE, path = preview, fit = "contain",
                       radius = 8, border = border, borderWidth = isArmed and 3 or 1,
                       tooltip = tip, onClick = onClick })
  else
    frame = ui.box({ width = MAP_TILE, height = MAP_TILE, fill = "surface_variant",
                     radius = 8, border = border, borderWidth = isArmed and 3 or 1,
                     tooltip = tip, onClick = onClick })
  end
  local tile = ui.column({ key = `role_{st.tab}_{role}`, gap = 2, align = "center", width = 60 }, {
    frame,
    ui.label({ text = role, fontSize = 10, maxLines = 1, maxWidth = 60,
               textAlign = "center", color = "on_surface_variant", tooltip = tip }),
  })
  -- Every role is a drop target: dragging a file tile onto it assigns it,
  -- the same as arming the role then clicking the file. The drag type carries
  -- the tab, so the two grids can never accept each other's files.
  return ui.dropZone({
    key = `dropzone_{st.tab}_{role}`, accepts = { `{st.tab}-file` }, value = role,
    onDrop = function(payload) assign(st, role, payload) end,
    direction = "column", radius = 8, hitSlop = 6,
  }, { tile })
end

local function mapFileTile(st, file)
  local onClick = function()
    if st.target == "" then
      return
    end
    assign(st, st.target, file.rel)
  end
  local tile = ui.column({ key = `file_{st.tab}_{file.rel}`, gap = 2, align = "center", width = 60 }, {
    ui.image({ key = `file_img_{st.tab}_{file.rel}_{st.serial}`,
               width = MAP_TILE, height = MAP_TILE, path = file.preview, fit = "contain",
               radius = 8, border = "outline", borderWidth = 1, onClick = onClick }),
    ui.label({ text = file.file, fontSize = 10, maxLines = 1, maxWidth = 60,
               textAlign = "center", color = "on_surface_variant" }),
  })
  -- Click-to-arm still works (see mapRoleTile) for anything that can't drag;
  -- this just adds dragging the tile itself onto a role as a shortcut.
  return ui.dragSource({
    key = `dragsource_{st.tab}_{file.rel}`, dragType = `{st.tab}-file`, payload = file.rel,
    tooltip = file.file,
  }, { tile })
end

-- Built from st.roles, not a list of its own, so it stays in the grid's order
-- and never names a role this grid does not show.
local function roleLegend(st)
  local rows = {}
  for _, role in ipairs(st.roles) do
    table.insert(rows, ui.row({ gap = 8, align = "baseline" }, {
      ui.label({ text = role, fontSize = 11, minWidth = 90, color = "on_surface" }),
      ui.label({ text = tr(`role_{role}`), fontSize = 11, flexGrow = 1,
                 color = "on_surface_variant" }),
    }))
  end
  return ui.column({ gap = 2, align = "stretch" }, rows)
end

-- Always shown after a scan, even when every role mapped: any tile can be
-- reassigned, not only the empty ones. Click a role, then a file, to assign.
local function mappingGrid(st)
  if #st.roles == 0 then
    return ui.box({ height = 0 })
  end
  -- rel -> thumbnail, so a role tile can paint the file assigned to it before
  -- the engine has re-rendered anything.
  local byRel = {}
  for _, file in ipairs(st.files) do
    byRel[file.rel] = file.preview
  end
  local roleTiles = {}
  for _, role in ipairs(st.roles) do
    table.insert(roleTiles, mapRoleTile(st, role, byRel))
  end
  local fileTiles = {}
  for _, file in ipairs(st.files) do
    table.insert(fileTiles, mapFileTile(st, file))
  end
  return ui.column({ gap = 8, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = tr("map_roles"), fontSize = 12, color = "on_surface_variant" }),
      ui.button({ key = `map_help_{st.tab}`, glyph = "help-circle", variant = "ghost",
                  controlSize = "sm", tooltip = tr("role_legend"),
                  onClick = function()
                    mapHelp = not mapHelp
                    render()
                  end }),
    }),
    -- ui.box, not ui.spacer: a spacer with no height eats the column's slack.
    mapHelp and roleLegend(st) or ui.box({ height = 0 }),
    wrapTiles(roleTiles, MAP_COLUMNS),
    ui.label({
      text = st.target ~= "" and `{tr("map_pick")} {st.target}` or tr("map_source_files"),
      fontSize = 11, color = st.target ~= "" and "primary" or "on_surface_variant",
    }),
    wrapTiles(fileTiles, MAP_COLUMNS),
  })
end

-- `st` is the grid this report belongs to, nil for a tab that has none. Both
-- builders return the same shape now, so one view serves Import and Build.
local function reportView(rep, st)
  if rep == nil then
    return ui.box({ height = 0 })
  end
  local lines = {}
  if rep.method ~= nil then
    table.insert(lines, ui.label({ text = `{tr("method")}: {rep.method}`,
                                   fontSize = 12, color = "on_surface_variant" }))
  end
  -- Keyed on the actual condition, not on `written`: a scan writes nothing by
  -- design, so `written == false` no longer means the arrow is missing.
  if rep.mapped ~= nil and table.find(rep.mapped, "arrow") == nil then
    table.insert(lines, ui.label({ text = tr("needs_arrow"), fontSize = 12, color = "tertiary" }))
  end
  if rep.mapped ~= nil and #rep.mapped > 0 then
    table.insert(lines, ui.label({ text = `{tr("mapped")}: {table.concat(rep.mapped, ", ")}`,
                                   fontSize = 12, color = "on_surface_variant" }))
  end
  if rep.unmapped_roles ~= nil and #rep.unmapped_roles > 0 then
    table.insert(lines, ui.label({
      text = `{tr("unmapped")}: {table.concat(rep.unmapped_roles, ", ")}`,
      fontSize = 12, color = "tertiary",
    }))
    table.insert(lines, ui.label({ text = tr("unmapped_hint"), fontSize = 11,
                                   color = "on_surface_variant" }))
  end
  if st ~= nil then
    table.insert(lines, mappingGrid(st))
  end
  return ui.column({ gap = 8, align = "stretch" }, lines)
end

local function importTab()
  -- Nothing scanned for the path in the field: read the pack and show the grid
  -- first, so the convert that follows is the only one that writes a theme.
  local st = maps.import
  local needsScan = st.scanned ~= trim(importPath)
  local label = needsScan and tr("scan")
    or (next(st.mapping) ~= nil and tr("convert_again") or tr("convert"))
  return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.label({ text = tr("import_hint"), fontSize = 12, color = "on_surface_variant" }),
    ui.input({ key = `import_path_{pickSeq}`, placeholder = tr("import_path"), value = importPath,
               onChange = "onImportPathChange", onSubmit = "onImportPathChange" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ key = "pick_import_dir", text = tr("pick_folder"), glyph = "folder",
                  variant = "outline", controlSize = "sm", onClick = "onPickImportDir" }),
      ui.spacer({ flexGrow = 1 }),
    }),
    ui.input({ key = "import_name", placeholder = tr("theme_name"), value = importName,
               onChange = "onImportNameChange", onSubmit = "onImportNameChange" }),
    ui.row({ gap = 12, align = "center" }, {
      ui.button({ key = "shadow", text = tr("shadow"),
                  variant = importShadow and "primary" or "outline",
                  tooltip = tr("shadow_tooltip"), onClick = "onToggleShadow" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ key = "convert", text = label, variant = "primary",
                  onClick = needsScan and "onScanImport" or "onImport",
                  enabled = not busy and trim(importPath) ~= "" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 8 }, { reportView(importReport, st) }),
  })
end

local function buildTab()
  -- Same scan-then-write flow as Import: the PNGs are read and shown, and only
  -- the second press writes a theme.
  local st = maps.build
  local needsScan = st.scanned ~= trim(buildPath)
  local label = needsScan and tr("scan_build")
    or (next(st.mapping) ~= nil and tr("build_again") or tr("build"))
  return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.label({ text = tr("build_hint"), fontSize = 12, color = "on_surface_variant" }),
    ui.input({ key = `build_path_{pickSeq}`, placeholder = tr("build_path"), value = buildPath,
               onChange = "onBuildPathChange", onSubmit = "onBuildPathChange" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ key = "pick_build_dir", text = tr("pick_folder"), glyph = "folder",
                  variant = "outline", controlSize = "sm", onClick = "onPickBuildDir" }),
      ui.spacer({ flexGrow = 1 }),
    }),
    ui.input({ key = "build_name", placeholder = tr("theme_name"), value = buildName,
               onChange = "onBuildNameChange", onSubmit = "onBuildNameChange" }),
    ui.row({ gap = 12, align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
      ui.button({ key = "build", text = label, variant = "primary",
                  onClick = needsScan and "onScanBuild" or "onBuild",
                  enabled = not busy and trim(buildPath) ~= "" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 8 }, { reportView(buildReport, st) }),
  })
end

-- Only themes in the install folder are ours to delete; list_themes marks
-- those `removable`, so system themes simply never appear here.
local function removableRows()
  local rows = {}
  for _, theme in ipairs(themes) do
    if theme.removable then
      local name = theme.name
      local armed = pendingRemove == name
      table.insert(rows, ui.row({ key = `rm_{name}`, gap = 8, align = "center" }, {
        ui.label({ text = theme.title or name, fontSize = 13, maxLines = 1, flexGrow = 1 }),
        ui.button({
          key = `rmbtn_{name}`,
          text = armed and tr("confirm_remove") or nil,
          glyph = not armed and "trash" or nil,
          variant = armed and "destructive" or "ghost",
          controlSize = "sm", enabled = not busy,
          tooltip = tr("remove"),
          onClick = function()
            if armed then
              onRemoveTheme(name)
            else
              pendingRemove = name
              render()
            end
          end,
        }),
      }))
    end
  end
  if #rows == 0 then
    return { ui.label({ text = tr("none_removable"), fontSize = 12,
                        color = "on_surface_variant" }) }
  end
  return rows
end

local function installTab()
  return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.label({ text = tr("install_hint"), fontSize = 12, color = "on_surface_variant" }),
    ui.input({ key = `install_path_{pickSeq}`, placeholder = tr("install_path"),
               value = installPath, onChange = "onInstallPathChange",
               onSubmit = "onInstallPathChange" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ key = "pick_install_dir", text = tr("pick_folder"), glyph = "folder",
                  variant = "outline", controlSize = "sm", onClick = "onPickInstallDir" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ key = "install", text = tr("install"), variant = "primary",
                  onClick = "onInstall", enabled = not busy and trim(installPath) ~= "" }),
    }),
    ui.separator({}),
    ui.label({ text = tr("installed_themes"), fontSize = 12, fontWeight = "bold" }),
    ui.scroll({ flexGrow = 1, gap = 6 }, removableRows()),
  })
end

local function tabButton(id, labelKey)
  return ui.button({
    key = `tab_{id}`, text = tr(labelKey),
    variant = tab == id and "primary" or "ghost",
    onClick = function()
      tab = id
      render()
    end,
  })
end

render = function()
  local body
  if tab == "import" then
    body = importTab()
  elseif tab == "build" then
    body = buildTab()
  elseif tab == "install" then
    body = installTab()
  else
    body = themesTab()
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold",
                 color = "on_surface", flexGrow = 1 }),
      ui.button({ key = "reload", glyph = "refresh", variant = "ghost",
                  tooltip = tr("reload"), onClick = "onReload", enabled = not busy }),
      ui.button({ key = "close", glyph = "close", onClick = "onCloseClicked" }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      tabButton("themes", "tab_themes"),
      tabButton("install", "tab_install"),
      tabButton("import", "tab_import"),
      tabButton("build", "tab_build"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = status, fontSize = 12, color = statusTone, maxLines = 1 }),
    }),
    body,
  }))
end

-- ── handlers ────────────────────────────────────────────────────────────────

function onOpen(_context)
  -- The picker reopens this panel when it is done, so an open is also how a
  -- chosen path comes back.
  -- Through the path-change handlers, so a new pick also drops the previous
  -- pack's grid, report and hand-made mapping.
  consumePick("import", function(path)
    onImportPathChange(path)
    tab = "import"
  end)
  consumePick("build", function(path)
    onBuildPathChange(path)
    tab = "build"
  end)
  consumePick("install", function(path)
    installPath = path
    tab = "install"
  end)
  -- Picking a folder is the whole intent, so read it straight away: the user
  -- gets the mapping grid without a second click, and still decides when
  -- anything is written. Only the tab the pick landed on scans, and only after
  -- loadThemes() below is done with `busy`.
  if tab == "import" and trim(importPath) ~= "" and maps.import.scanned ~= trim(importPath) then
    pendingScan = "import"
  elseif tab == "build" and trim(buildPath) ~= "" and maps.build.scanned ~= trim(buildPath) then
    pendingScan = "build"
  end
  loadThemes()
end

function onPickImportDir()
  pick("import", importPath)
end

function onPickBuildDir()
  pick("build", buildPath)
end

function onPickInstallDir()
  pick("install", installPath)
end

function onInstallPathChange(value)
  installPath = trim(value)
end

function onInstall()
  local source = trim(installPath)
  if source == "" or busy then
    return
  end
  if not noctalia.fileExists(noctalia.expandPath(source)) then
    fail(tr("path_missing"))
    return
  end
  busy = true
  pendingRemove = ""
  setStatus(tr("installing"))
  render()

  call(`install {shellQuote(noctalia.expandPath(source))}`, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    busy = false
    local names = table.concat(result.installed, ", ")
    local verb = #result.replaced > 0 and tr("replaced") or tr("installed")
    setStatus(`{verb}: {names}`, "primary")
    noctalia.notify(tr("title"), `{verb}: {names}`)
    selected = result.installed[1] or selected
    loadThemes()
  end)
end

function onRemoveTheme(name)
  if busy then
    return
  end
  busy = true
  pendingRemove = ""
  setStatus(tr("removing"))
  render()

  call(`remove {shellQuote(name)}`, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    busy = false
    setStatus(`{tr("removed")}: {name}`, "primary")
    -- The removed theme may still be the one every layer points at; a refresh
    -- makes the drift warning tell the truth.
    loadThemes()
  end)
end

function onReset()
  if busy then
    return
  end
  busy = true
  pendingReset = false
  setStatus(tr("resetting"))
  render()

  call("uninstall", function(result, err)
    if result == nil then
      fail(err)
      return
    end
    busy = false
    undone = true
    failedLayers = {}
    -- The old pick would stay highlighted over the theme that is no longer
    -- applied; empty, loadCurrent() adopts what the reset left active.
    selected = ""
    local failed = {}
    for _, name in ipairs(sortedKeys(type(result.failed) == "table" and result.failed or {})) do
      table.insert(failed, layerName(name))
    end
    if #failed > 0 then
      setStatus(`{tr("reset_partly")} {table.concat(failed, ", ")}`, "tertiary")
    else
      setStatus(tr("reset_done"), "primary")
    end
    noctalia.notify(tr("title"), tr("reset_done"))
    loadThemes()
  end)
end

function onReload()
  previews = {}
  loadThemes()
end

function onCloseClicked()
  panel.close()
end

function onSizeChange(index, _text)
  sizeIndex = tonumber(index) or 2
  render()
end

function onToggleHideTyping()
  hideTyping = not hideTyping
  render()
end

function onHideMsChange(value)
  hideMs = trim(value)
end

function onApply()
  if selected == "" or busy then
    return
  end
  busy = true
  failedLayers = {}
  setStatus(tr("applying"))
  render()

  local args = `apply {shellQuote(selected)} --size {sizeValue()}`
  if hideTyping then
    args ..= " --hide-when-typing"
  end
  local ms = tonumber(hideMs)
  if ms ~= nil and ms > 0 then
    args ..= ` --hide-after-inactive-ms {math.floor(ms)}`
  end

  call(args, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    busy = false
    undone = false
    failedLayers = type(result.failed) == "table" and result.failed or {}
    local failed = sortedKeys(failedLayers)
    if #failed > 0 then
      local names, lines = {}, {}
      for _, name in ipairs(failed) do
        table.insert(names, layerName(name))
        table.insert(lines, `{layerName(name)}: {failedLayers[name]}`)
      end
      setStatus(`{tr("applied_partly")} {table.concat(names, ", ")}`, "tertiary")
      noctalia.notify(tr("title"), `{selected}. {tr("applied_partly")}\n{table.concat(lines, "\n")}`)
    else
      setStatus(tr("applied"), "primary")
      noctalia.notify(tr("title"), `{tr("applied")}: {selected}`)
    end
    loadCurrent(render)
  end)
end

function onImportPathChange(value)
  importPath = trim(value)
  -- A new source invalidates every relpath the old grid was built from.
  maps.import = newMapState("import")
  importReport = nil
end

function onImportNameChange(value)
  importName = trim(value)
end

function onToggleShadow()
  importShadow = not importShadow
  render()
end

-- Both builders now return the same grid payload, so both tabs land it the
-- same way. The grid stays on screen either way, which is why nothing here
-- switches tabs; the themes list is only refreshed, not reloaded with previews.
local function applyMapResult(st, source, result)
  st.files = result.files or {}
  st.previews = result.role_previews or {}
  -- Fresh art at the same cache paths: re-key every tile image (see serial).
  st.serial += 1
  st.roles = {}
  for _, role in ipairs(result.mapped or {}) do
    table.insert(st.roles, role)
  end
  for _, role in ipairs(result.unmapped_roles or {}) do
    table.insert(st.roles, role)
  end
  st.target = ""
  st.scanned = source

  if result.written then
    selected = result.name
    -- Same wording as install: overwriting a theme of that name shouldn't be silent.
    local verb = result.replaced and tr("replaced") or tr("built")
    setStatus(`{verb}: {result.name}`, "primary")
    noctalia.notify(tr("title"), `{verb}: {result.name}`)
    call("list", function(listResult)
      if listResult ~= nil then
        themes = listResult.themes or {}
        render()
      end
    end)
  elseif table.find(result.mapped or {}, "arrow") == nil then
    setStatus(tr("needs_arrow"), "tertiary")
  else
    setStatus(tr("map_roles"))
  end
  render()
end

-- Every override the grid holds, as engine flags.
local function mapArgs(st)
  local args = ""
  for role, rel in pairs(st.mapping) do
    args ..= ` --map {shellQuote(`{role}={rel}`)}`
  end
  return args
end

-- A scan and a write are the same run with the same mapping, differing only in
-- whether the engine writes the theme at the end - so they share a body rather
-- than drifting apart. `doImport`/`doBuild` are local; the globals below are
-- what the buttons reference by name.
local function doImport(dryRun)
  local st = maps.import
  local source = trim(importPath)
  if source == "" or busy then
    return
  end
  if not noctalia.fileExists(noctalia.expandPath(source)) then
    fail(tr("path_missing"))
    return
  end
  -- Typing in the path field clears the grid without a re-render, so the button
  -- can still read "Convert" for a pack nobody has scanned. Decide on the state,
  -- not on the label: an unscanned path always scans first.
  dryRun = dryRun or st.scanned ~= source
  busy = true
  importReport = nil
  setStatus(dryRun and tr("scanning") or tr("converting"))
  render()

  local args = `import-win {shellQuote(noctalia.expandPath(source))}{imageArgs()}`
  if importName ~= "" then
    args ..= ` --name {shellQuote(importName)}`
  end
  if importShadow then
    args ..= " --shadow"
  end
  if dryRun then
    args ..= " --dry-run"
  end
  args ..= mapArgs(st)

  call(args, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    busy = false
    importReport = result
    applyMapResult(st, source, result)
  end)
end

function onScanImport()
  doImport(true)
end

function onImport()
  doImport(false)
end

function onBuildPathChange(value)
  buildPath = trim(value)
  -- A new folder invalidates every relpath the old grid was built from.
  maps.build = newMapState("build")
  buildReport = nil
end

function onBuildNameChange(value)
  buildName = trim(value)
end

local function doBuild(dryRun)
  local st = maps.build
  local source = trim(buildPath)
  if source == "" or busy then
    return
  end
  -- build only ever reads a directory of PNGs, so say so here rather than
  -- letting curmgr reject it after the round trip.
  local info = noctalia.fileInfo(noctalia.expandPath(source))
  if info == nil then
    fail(tr("path_missing"))
    return
  end
  if not info.isDir then
    fail(tr("not_a_folder"))
    return
  end
  -- Same reasoning as doImport: the state decides, not the button label.
  dryRun = dryRun or st.scanned ~= source
  busy = true
  buildReport = nil
  setStatus(dryRun and tr("scanning") or tr("building"))
  render()

  local args = `build {shellQuote(noctalia.expandPath(source))}{imageArgs()}`
  if buildName ~= "" then
    args ..= ` --name {shellQuote(buildName)}`
  end
  if dryRun then
    args ..= " --dry-run"
  end
  args ..= mapArgs(st)

  call(args, function(result, err)
    if result == nil then
      fail(err)
      return
    end
    busy = false
    buildReport = result
    applyMapResult(st, source, result)
  end)
end

function onScanBuild()
  doBuild(true)
end

function onBuild()
  doBuild(false)
end
