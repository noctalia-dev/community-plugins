--!nonstrict
-- Shelf panel: browse, reorder, open, copy, and remove what is on the shelf.
-- Dragging files in from other apps (and out to them) happens in the drop
-- window, which this panel opens through the service.

local store = require("./lib/store.luau")
local shortcut = require("./lib/shortcut.luau")

local DRAG_TYPE = "shelf-item"
local FLASH_MS = 2200
local MAX_THUMB_BYTES = 12 * 1000 * 1000

local items = store.current()
local infos = {} -- infos[i] is fileInfo(items[i].path), or false when missing
local totalBytes, missingCount = 0, 0
local hovered = nil
local flash = nil -- { text = string, untilMs = number, isError = bool }
local helperOpen = noctalia.state.get(store.HELPER_KEY) == true
-- While the panel is closed nothing is stat'ed or rendered: fileInfo runs on
-- the shell's thread, and a large shelf or a stalled network mount would stall
-- the shell for a panel nobody sees. onOpen catches up.
local isOpen = noctalia.state.get(store.PANEL_OPEN_KEY) == true -- true after a hot reload while open
local CLOSED_POLL_MS = 60000

local render -- forward declaration

-- Stats every item once. Renders reuse the result, so hovering a row never
-- touches the disk; it runs when the items change and when the panel opens.
local function refreshInfos()
  infos = {}
  totalBytes, missingCount = 0, 0
  for i, item in ipairs(items) do
    local info = noctalia.fileInfo(item.path)
    infos[i] = info or false
    if info == nil then
      missingCount = missingCount + 1
    elseif not info.isDir then
      totalBytes = totalBytes + (info.size or 0)
    end
  end
end

local function showFlash(text, isError)
  if not isOpen then
    -- An async result (a paste) can land after the panel closed.
    return
  end
  flash = { text = text, untilMs = noctalia.nowMs() + (isError and FLASH_MS * 3 or FLASH_MS), isError = isError }
  noctalia.setUpdateInterval(250)
  render()
end

-- Detached, so a slow app opener is never killed with a capture timeout.
local function run(argv)
  if not noctalia.runAsync(argv) then
    noctalia.log("shelf: could not start " .. argv[1])
  end
end

-- Actions ----------------------------------------------------------------------

local function openItem(path)
  if not noctalia.fileExists(path) then
    showFlash(noctalia.tr("panel.flash.missing"))
    return
  end
  run({ "xdg-open", path })
  panel.close()
end

local function revealItem(path)
  -- Ask the file manager to select the file; fall back to opening its folder.
  local uri = store.fileUri(path)
  noctalia.runAsync({
    "gdbus", "call", "--session",
    "--dest", "org.freedesktop.FileManager1",
    "--object-path", "/org/freedesktop/FileManager1",
    "--method", "org.freedesktop.FileManager1.ShowItems",
    "['" .. string.gsub(uri, "'", "%%27") .. "']", "",
  }, function(result)
    if result.exitCode ~= 0 then
      run({ "xdg-open", store.dirname(path) })
    end
  end)
  panel.close()
end

local function copyItems(paths)
  local existing = {}
  for _, p in ipairs(paths) do
    if noctalia.fileExists(p) then
      table.insert(existing, p)
    end
  end
  if #existing == 0 then
    showFlash(noctalia.tr("panel.flash.nothing_to_copy"))
    return
  end
  if noctalia.copyToClipboard(store.uriList(existing), "text/uri-list") then
    showFlash(noctalia.trp("panel.flash.copied", #existing))
  end
end

local function allPaths()
  local paths = {}
  for _, item in ipairs(items) do
    table.insert(paths, item.path)
  end
  return paths
end

local function pasteFromClipboard()
  store.readClipboardPaths(function(paths)
    if paths == nil then
      showFlash(noctalia.tr("panel.flash.paste_no_wl_paste"), true)
    elseif #paths == 0 then
      showFlash(noctalia.tr("panel.flash.paste_empty"))
    else
      showFlash(noctalia.trp("panel.flash.added", store.add(paths)))
    end
  end)
end

local function removeMissing()
  local missing = {}
  for i, item in ipairs(items) do
    if not infos[i] then
      table.insert(missing, item.path)
    end
  end
  store.remove(missing)
end

function onReorder(path, target)
  if target == "end" then
    store.move(path, nil)
  else
    store.move(path, string.sub(target, #"before:" + 1))
  end
end

-- Only the innermost hovered node reports hover: moving onto a row's button
-- makes the row report "false". Track row and button hover apart, so the row
-- stays highlighted under its own buttons whatever order the events come in.
local rowHovered, buttonHovered = nil, nil

local function syncHover()
  local next = buttonHovered or rowHovered
  if next ~= hovered then
    hovered = next
    render()
  end
end

function onRowHover(state, key)
  if state == "true" then
    rowHovered = key
  elseif rowHovered == key then
    rowHovered = nil
  end
  syncHover()
end

local function keepHover(path)
  return function(state)
    if state == "true" then
      buttonHovered = path
    elseif buttonHovered == path then
      buttonHovered = nil
    end
    syncHover()
  end
end

-- Views --------------------------------------------------------------------------

-- Keyboard shortcut section ----------------------------------------------------

local shortcutOpen = false
local shortcutConfirm = false
local sc = nil -- what the section shows; see refreshShortcut

local function prettyPath(path)
  local home = noctalia.getenv("HOME") or ""
  if home ~= "" and string.sub(path, 1, #home + 1) == home .. "/" then
    return "~" .. string.sub(path, #home + 1)
  end
  return path
end

-- Reads the setting and the compositor config once, when the section opens
-- or changes, not on every render.
local function refreshShortcut()
  local combo = shortcut.parse(noctalia.getConfig("shortcut") or shortcut.DEFAULT)
  local compositor = shortcut.detect()
  local path, syntax = shortcut.target(compositor)
  sc = {
    combo = combo,
    compositor = compositor,
    name = compositor and shortcut.NAMES[compositor] or nil,
    path = path,
    syntax = syntax,
    line = combo and syntax and shortcut.line(syntax, combo) or nil,
    installed = combo ~= nil and path ~= nil and shortcut.installed(path, syntax, combo),
  }
end

local function copyText(text)
  if noctalia.copyToClipboard(text, "text/plain") then
    showFlash(noctalia.tr("panel.shortcut.flash.copied"))
  end
end

local function afterConfigChange(ok, err, flashKey)
  shortcutConfirm = false
  if not ok then
    showFlash(noctalia.tr("panel.shortcut.error", { error = tostring(err) }), true)
    return
  end
  local reload = shortcut.reloadCommand(sc.compositor)
  if reload ~= nil then
    noctalia.runAsync(reload)
  end
  refreshShortcut()
  showFlash(noctalia.tr(flashKey))
end

local function codeBlock(text)
  return ui.column({
    key = "shortcut-code", fill = "surface_variant", radius = 8, paddingH = 10, paddingV = 8, align = "stretch",
  }, {
    ui.label({ text = text, fontSize = 11, fontFamily = "monospace", color = "on_surface" }),
  })
end

local function shortcutSection()
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "keyboard", size = 16, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.shortcut.title"), fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        key = "shortcut-close",
        glyph = "x", variant = "ghost", controlSize = "sm",
        onClick = function()
          shortcutOpen = false
          shortcutConfirm = false
          render()
        end,
      }),
    }),
  }
  local function add(node)
    table.insert(children, node)
  end
  local function note(text)
    add(ui.label({ text = text, fontSize = 12, color = "on_surface_variant" }))
  end

  if sc.combo == nil then
    note(noctalia.tr("panel.shortcut.invalid"))
  else
    local keys = shortcut.display(sc.combo)
    if sc.line ~= nil then
      note(noctalia.tr("panel.shortcut.summary", { keys = keys }))
      note(noctalia.tr("panel.shortcut.config", { compositor = sc.name, path = prettyPath(sc.path) }))
      add(codeBlock(sc.line))
      if sc.installed then
        add(ui.row({ gap = 6, align = "center" }, {
          ui.glyph({ name = "check", size = 14, color = "primary" }),
          ui.label({
            text = noctalia.tr("panel.shortcut.installed", { compositor = sc.name }),
            fontSize = 12, color = "primary", fontWeight = "semibold",
          }),
        }))
      end
      if shortcutConfirm then
        note(noctalia.tr("panel.shortcut.confirm", { path = prettyPath(sc.path) }))
        add(ui.row({ gap = 6, justify = "start" }, {
          ui.button({
            key = "shortcut-confirm-add",
            text = noctalia.tr("panel.shortcut.confirm_add"), glyph = "check", variant = "primary", controlSize = "sm",
            onClick = function()
              local ok, err = shortcut.install(sc.path, sc.syntax, sc.combo)
              afterConfigChange(ok, err, "panel.shortcut.flash.added")
            end,
          }),
          ui.button({
            key = "shortcut-cancel",
            text = noctalia.tr("panel.shortcut.cancel"), glyph = "x", variant = "ghost", controlSize = "sm",
            onClick = function()
              shortcutConfirm = false
              render()
            end,
          }),
        }))
      else
        local buttons = {
          ui.button({
            key = "shortcut-copy",
            text = noctalia.tr("panel.shortcut.copy"), glyph = "copy", variant = "outline", controlSize = "sm",
            onClick = function() copyText(sc.line) end,
          }),
        }
        if sc.installed then
          table.insert(buttons, ui.button({
            key = "shortcut-remove",
            text = noctalia.tr("panel.shortcut.remove"), glyph = "trash", variant = "ghost", controlSize = "sm",
            onClick = function()
              local ok, err = shortcut.uninstall(sc.path)
              afterConfigChange(ok, err, "panel.shortcut.flash.removed")
            end,
          }))
        else
          table.insert(buttons, ui.button({
            key = "shortcut-add",
            text = noctalia.tr("panel.shortcut.add"), glyph = "plus", variant = "primary", controlSize = "sm",
            onClick = function()
              shortcutConfirm = true
              render()
            end,
          }))
        end
        add(ui.row({ gap = 6, justify = "start" }, buttons))
      end
    else
      -- KDE and GNOME bind keys in their settings app; anything else, show
      -- the command to bind.
      local desktop = sc.compositor == "kde" or sc.compositor == "gnome"
      note(noctalia.tr(desktop and "panel.shortcut.desktop" or "panel.shortcut.unknown", { keys = keys }))
      add(codeBlock(shortcut.COMMAND))
      add(ui.row({ gap = 6, justify = "start" }, {
        ui.button({
          key = "shortcut-copy-command",
          text = noctalia.tr("panel.shortcut.copy_command"), glyph = "copy", variant = "outline", controlSize = "sm",
          onClick = function() copyText(shortcut.COMMAND) end,
        }),
      }))
    end
  end

  -- Keyed and fully specified, so the reconciler never reuses the empty
  -- state's centred column for it.
  return ui.column({
    key = "shortcut-section", gap = 8, padding = 12, radius = 14, align = "stretch", justify = "start",
    fill = "surface_variant/0.45", border = "outline/0.5", borderWidth = 1,
  }, children)
end

local function header(summary, showDropButton)
  return ui.row({ key = "header", gap = 10, align = "center" }, {
    ui.column({
      width = 36, height = 36, radius = 12, fill = "primary/0.16", align = "center", justify = "center",
    }, {
      ui.glyph({ name = "stack-2", size = 20, color = "primary" }),
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = summary, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      key = "drop-window",
      visible = showDropButton,
      text = helperOpen and noctalia.tr("panel.drop_window.close") or noctalia.tr("panel.drop_window.open"),
      glyph = "drag-drop",
      variant = helperOpen and "secondary" or "primary",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.drop_window.tooltip"),
      onClick = function()
        store.request(helperOpen and "close" or "open")
      end,
    }),
    ui.button({
      key = "shortcut",
      glyph = "keyboard",
      variant = shortcutOpen and "secondary" or "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.shortcut.button"),
      onClick = function()
        shortcutOpen = not shortcutOpen
        shortcutConfirm = false
        if shortcutOpen then
          refreshShortcut()
        end
        render()
      end,
    }),
  })
end

local function emptyState()
  return ui.column({
    key = "empty-state",
    flexGrow = 1, gap = 10, align = "center", justify = "center",
    fill = "surface_variant/0.45", radius = 18, padding = 24,
    border = "outline/0.5", borderWidth = 1,
  }, {
    ui.column({
      width = 64, height = 64, radius = 32, fill = "primary/0.14", align = "center", justify = "center",
    }, {
      ui.glyph({ name = "drag-drop", size = 30, color = "primary" }),
    }),
    ui.label({ text = noctalia.tr("panel.empty.title"), fontSize = 15, fontWeight = "bold", textAlign = "center" }),
    ui.label({
      text = noctalia.tr("panel.empty.body"), fontSize = 12, color = "on_surface_variant",
      textAlign = "center", maxWidth = 300,
    }),
    ui.row({ gap = 8, justify = "center" }, {
      ui.button({
        key = "empty-drop-window",
        text = noctalia.tr("panel.drop_window.open"), glyph = "drag-drop", variant = "primary",
        controlSize = "sm", onClick = function() store.request("open") end,
      }),
      ui.button({
        key = "empty-paste",
        text = noctalia.tr("panel.paste.label"), glyph = "clipboard-plus", variant = "outline",
        controlSize = "sm", tooltip = noctalia.tr("panel.paste.tooltip"), onClick = pasteFromClipboard,
      }),
    }),
  })
end

local function thumbnail(path, info)
  if info ~= nil and not info.isDir and store.isImage(path) and info.size <= MAX_THUMB_BYTES then
    return ui.image({ path = path, width = 40, height = 40, radius = 10, fit = "cover" })
  end
  local missing = info == nil
  return ui.column({
    width = 40, height = 40, radius = 10, align = "center", justify = "center",
    fill = missing and "error/0.14" or "surface_variant",
  }, {
    ui.glyph({
      name = missing and "file-off" or store.glyphFor(path, info.isDir),
      size = 20,
      color = missing and "error" or "primary",
    }),
  })
end

local function metaText(path, info)
  if info == nil then
    return noctalia.tr("panel.row.missing") .. " · " .. store.prettyDir(path)
  end
  if info.isDir then
    return noctalia.tr("panel.row.folder") .. " · " .. store.prettyDir(path)
  end
  return store.formatSize(info.size) .. " · " .. store.prettyDir(path)
end

local function insertionZone(value)
  return ui.dropZone({
    key = "gap-" .. value,
    accepts = { DRAG_TYPE },
    value = value,
    onDrop = "onReorder",
    height = 2,
    expandOnDrag = true,
    hitSlop = 22,
  })
end

local function row(item, info)
  local path = item.path
  local isHovered = hovered == path
  local missing = info == nil
  local actions = {}

  if not missing then
    table.insert(actions, ui.button({
      key = "reveal-" .. path, glyph = "folder-open", variant = "ghost", controlSize = "sm", onHover = keepHover(path),
      tooltip = noctalia.tr("panel.row.reveal"), onClick = function() revealItem(path) end,
    }))
    table.insert(actions, ui.button({
      key = "copy-" .. path, glyph = "copy", variant = "ghost", controlSize = "sm", onHover = keepHover(path),
      tooltip = noctalia.tr("panel.row.copy"), onClick = function() copyItems({ path }) end,
    }))
  end
  table.insert(actions, ui.button({
    key = "remove-" .. path, glyph = "x", variant = "ghost", controlSize = "sm", onHover = keepHover(path),
    tooltip = noctalia.tr("panel.row.remove"), onClick = function() store.remove({ path }) end,
  }))

  return ui.row({
    key = path,
    gap = 10,
    align = "center",
    paddingH = 6,
    paddingV = 6,
    radius = 12,
    fill = isHovered and "on_surface/0.07" or "#00000000",
    onHover = "onRowHover",
    onClick = function() openItem(path) end,
  }, {
    ui.dragSource({
      key = "grip-" .. path,
      dragType = DRAG_TYPE,
      payload = path,
      -- The row is clickable, so the host wraps it in an input area. Lifting
      -- only the row (1) leaves that wrapper in the list at full height, an
      -- empty gap next to the drop gap; lift the wrapper (2) instead.
      previewAncestor = 2,
      liftFromLayout = true,
      width = 14,
      height = 40,
      tooltip = noctalia.tr("panel.row.reorder"),
    }, {
      ui.glyph({ name = "grip-vertical", size = 14, color = isHovered and "on_surface_variant" or "outline" }),
    }),
    thumbnail(path, info),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = store.basename(path), fontSize = 13, fontWeight = "semibold", maxLines = 1,
        color = missing and "error" or "on_surface",
      }),
      ui.label({ text = metaText(path, info), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.row({ gap = 2, align = "center", opacity = isHovered and 1 or 0.55 }, actions),
  })
end

local function footer(missingCount)
  local left = {
    ui.button({
      key = "footer-copy-all",
      text = noctalia.tr("panel.copy_all.label"), glyph = "copy", variant = "ghost", controlSize = "sm",
      tooltip = noctalia.tr("panel.copy_all.tooltip"), onClick = function() copyItems(allPaths()) end,
    }),
    ui.button({
      key = "footer-paste",
      text = noctalia.tr("panel.paste.label"), glyph = "clipboard-plus", variant = "ghost", controlSize = "sm",
      tooltip = noctalia.tr("panel.paste.tooltip"), onClick = pasteFromClipboard,
    }),
  }
  if missingCount > 0 then
    table.insert(left, ui.button({
      key = "remove-missing",
      text = noctalia.trp("panel.remove_missing", missingCount), glyph = "file-off", variant = "ghost",
      controlSize = "sm", onClick = removeMissing,
    }))
  end
  table.insert(left, ui.spacer({ flexGrow = 1 }))
  table.insert(left, ui.button({
    key = "footer-clear",
    text = noctalia.tr("panel.clear.label"), glyph = "trash", variant = "ghost", controlSize = "sm",
    tooltip = noctalia.tr("panel.clear.tooltip"), onClick = function() store.clear() end,
  }))
  return ui.row({ key = "footer", gap = 4, align = "center" }, left)
end

render = function()
  if not isOpen then
    return
  end
  local summary
  if #items == 0 then
    summary = noctalia.tr("panel.summary.empty")
  elseif totalBytes > 0 then
    summary = noctalia.trp("common.files", #items) .. " · " .. store.formatSize(totalBytes)
  else
    summary = noctalia.trp("common.files", #items)
  end

  -- The empty state has its own call to action, so the header button would repeat it.
  local children = { header(summary, #items > 0 or helperOpen) }

  if shortcutOpen and sc ~= nil then
    -- The section is a view of its own: it replaces the list, so the two
    -- never have to share the panel's fixed height.
    table.insert(children, shortcutSection())
  elseif #items == 0 then
    table.insert(children, emptyState())
  else
    local rows = {}
    for i, item in ipairs(items) do
      table.insert(rows, insertionZone("before:" .. item.path))
      table.insert(rows, row(item, infos[i] or nil))
    end
    table.insert(rows, insertionZone("end"))
    table.insert(children, ui.scroll({ key = "list", flexGrow = 1, gap = 0 }, rows))
    table.insert(children, ui.separator({ key = "footer-line", color = "outline/0.4" }))
    table.insert(children, footer(missingCount))
  end

  if flash ~= nil then
    local tone = flash.isError and "error" or "primary"
    table.insert(children, ui.row({
      key = "flash", gap = 8, align = "center", justify = "center", paddingV = 6, paddingH = 12, radius = 14,
      fill = tone .. "/0.16",
    }, {
      ui.glyph({ name = flash.isError and "alert-triangle" or "check", size = 14, color = tone }),
      ui.label({ text = flash.text, fontSize = 12, color = tone, fontWeight = "semibold", flexGrow = 1 }),
    }))
  end

  panel.render(ui.column({ gap = 12, flexGrow = 1 }, children))
end

noctalia.state.watch(store.ITEMS_KEY, function(value)
  if type(value) == "table" then
    items = value
    if isOpen then
      refreshInfos()
      render()
    end
  end
end)

noctalia.state.watch(store.HELPER_KEY, function(value)
  helperOpen = value == true
  render()
end)

local OPEN_POLL_MS = 5000

local lastViewId = nil
local VIEW_REQUEST_MAX_AGE_MS = 5000

-- Shows a section another entry asked for (see the service's "shortcut" IPC).
-- The request outlives a plugin reload in shared state, so an old one is
-- ignored rather than reopening the section on the next open.
local function applyView(request)
  if type(request) ~= "table" or request.id == lastViewId then
    return false
  end
  lastViewId = request.id
  local sentAt = tonumber(request.id)
  if sentAt == nil or noctalia.nowMs() - sentAt > VIEW_REQUEST_MAX_AGE_MS then
    return false
  end
  if request.view == "shortcut" then
    shortcutOpen = true
    shortcutConfirm = false
    refreshShortcut()
    return true
  end
  return false
end

noctalia.state.watch(store.PANEL_VIEW_KEY, function(request)
  if applyView(request) and noctalia.state.get(store.PANEL_OPEN_KEY) == true then
    render()
  end
end)

function onOpen()
  isOpen = true
  noctalia.state.set(store.PANEL_OPEN_KEY, true)
  applyView(noctalia.state.get(store.PANEL_VIEW_KEY))
  noctalia.setUpdateInterval(OPEN_POLL_MS)
  items = store.current()
  refreshInfos()
  helperOpen = noctalia.state.get(store.HELPER_KEY) == true
  hovered, rowHovered, buttonHovered = nil, nil, nil
  render()
end

function onClose()
  isOpen = false
  noctalia.state.set(store.PANEL_OPEN_KEY, false)
  shortcutOpen = false
  shortcutConfirm = false
  flash = nil
  hovered, rowHovered, buttonHovered = nil, nil, nil
  noctalia.setUpdateInterval(CLOSED_POLL_MS)
end

function update()
  if not isOpen then
    return
  end
  local changed = false
  if flash ~= nil and noctalia.nowMs() >= flash.untilMs then
    flash = nil
    noctalia.setUpdateInterval(OPEN_POLL_MS)
    changed = true
  end
  if flash == nil then
    -- Notice files deleted or changed while the panel is open.
    local before = tostring(missingCount) .. ":" .. tostring(totalBytes)
    refreshInfos()
    changed = changed or (tostring(missingCount) .. ":" .. tostring(totalBytes)) ~= before
  end
  if changed then
    render()
  end
end

if isOpen then
  refreshInfos()
  render()
end
