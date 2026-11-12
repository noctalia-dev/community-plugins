--!nonstrict
-- Pure panel view: the vscode.state snapshot and the panel's ui_state in, a ui tree out.
-- No noctalia.* calls; it uses the `ui` builders, and panel.luau passes tr and the handlers.
--
--   view_panel.build(snap, ui_state, tr, h) -> UiNode
--   view_panel.gitKeys(snap, ui_state) -> { key }     visible local rows, for a `git` request
--   view_panel.menuItems(entry, tr) -> { PanelContextMenuItem }
--   view_panel.menuRequest(id, key) -> request | nil  a menu pick as a vscode.request
--
-- snap may be nil (no snapshot yet: shown as loading). ui_state:
--   mode       which header field is open: "search", "open" (the path box) or nil
--   shown      how many recents are listed (the panel starts it at recent_count)
--   query      the search field's text; while mode is "search" and it isn't blank,
--              pinned and recent rows are those whose title holds it (plain text, any
--              case, trimmed); recent matches are capped at `shown` like the full list
--   querySeq   bumped to remount the search field empty (key "input.search#<seq>")
--   input      the path box's text as last typed (the input is uncontrolled)
--   inputSeq   bumped to remount the path box empty (key "input.path#<seq>")
--   cloneDir   the clone_dir setting, for the "Clones into" line
--   expandedKey  the one row whose inline actions are open (nil: none)
-- h: open(key), openPath(text), clone(url), pickFolder(), cancelClone(), openExisting(dest),
--   dismiss(), loadMore(), setInput(text), menu(entry), toggleActions(key), action(id, key),
--   close(), setMode(mode | nil), setQuery(text).
--
-- Row actions: only a ui.button's onRightClick may open the native menu, so each row ends in
-- a "⋮" ghost button: right click opens the menu (h.menu), left click toggles an inline list
-- of the same actions under the row (h.toggleActions). A missing row's click also toggles it
-- rather than trying to open a folder that is gone.
--
-- Host rule (Mullvad 9d26b1f, UFW f4e3e00): a retained node keeps a prop that a later
-- render leaves out, so rows and the clone box set fill, border, borderWidth and opacity on
-- every render, and labels always set a colour. Exactly one primary button per state or
-- none (see primaryOf); no `selected`; other buttons are outline or ghost.

local uris = require("./uris.luau")
local flavors = require("./flavors.luau")

local view_panel = {}

local MUTED = "on_surface_variant"
local TEXT = "on_surface"
local ROW_FILL = "surface_container"
local CLEAR = "#00000000"
-- The palette has no warning role; tertiary is the theme's accent for "attention".
local DIRTY = "tertiary"
local MORE_STEP = 10

local TAG_TEXT = {
  ssh = "tag.ssh",
  container = "tag.container",
  wsl = "tag.wsl",
  tunnel = "tag.tunnel",
  other = "tag.remote",
}

local MENU_ACTIONS = {
  pin = true, unpin = true, open_terminal = true, open_files = true, copy_path = true, hide = true, unhide = true,
}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isLocal(e)
  return e.remote == nil and (e.uri == nil or e.uri:sub(1, 7) == "file://")
end

local function label(key, text, over)
  local p = { key = key, text = text, color = TEXT }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  return ui.label(p)
end

local function small(key, text, color)
  return label(key, text, { fontSize = 10, color = color or MUTED, maxLines = 1 })
end

-- The lowercased search text, or nil when not searching.
local function searchText(ui_state)
  if ui_state.mode ~= "search" then
    return nil
  end
  local q = string.lower(trim(ui_state.query))
  if q == "" then
    return nil
  end
  return q
end

local function matching(list, q)
  local out = {}
  for _, e in ipairs(list) do
    local name = string.lower(tostring(e.title or e.path or e.key or ""))
    if string.find(name, q, 1, true) ~= nil then
      out[#out + 1] = e
    end
  end
  return out
end

-- The rows on screen: pinned, the first `shown` recent (of the matches when searching),
-- and whether more wait.
local function visible(snap, ui_state)
  local pinned, list = snap.pinned or {}, snap.recent or {}
  local q = searchText(ui_state)
  if q ~= nil then
    pinned, list = matching(pinned, q), matching(list, q)
  end
  local n = tonumber(ui_state.shown) or 5
  local out = {}
  for i = 1, math.min(n, #list) do
    out[i] = list[i]
  end
  return pinned, out, #list > n
end

-- The one primary button: "go" (the path box's Open / Clone), "open_existing", or nil.
local function primaryOf(snap, ui_state)
  if snap == nil or snap.loading or snap.flavor == nil then
    return nil
  end
  local st = snap.clone and snap.clone.state or "idle"
  if st == "running" then
    return nil
  end
  if st == "exists" then
    return "open_existing"
  end
  if ui_state.mode == "open" and snap.hasGit and uris.isGitUrl(trim(ui_state.input)) then
    return "go"
  end
  return nil
end

-- ── header ───────────────────────────────────────────────────────────────────

local function header(snap, ui_state, tr, h)
  local flavor = snap and snap.flavor
  local icon
  if flavor and type(flavor.iconPath) == "string" and flavor.iconPath ~= "" then
    icon = ui.image({ key = "hdr.image", path = flavor.iconPath, width = 22, height = 22, fit = "contain" })
  else
    icon = ui.glyph({ key = "hdr.glyph", name = "brand-vscode", size = 22, color = "primary" })
  end
  local kids = {
    icon,
    label("hdr.name", flavor and flavor.name or tr("plugin.name"), { fontSize = 16, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
  }
  local function toggle(key, glyph, mode, tip)
    local active = ui_state.mode == mode
    kids[#kids + 1] = ui.button({
      key = key,
      glyph = glyph,
      variant = active and "outline" or "ghost",
      controlSize = "sm",
      tooltip = tr(tip),
      onClick = function()
        if active then
          h.setMode()
        else
          h.setMode(mode)
        end
      end,
    })
  end
  if snap ~= nil and snap.flavor ~= nil and not snap.loading then
    toggle("btn.search", "search", "search", "panel.search")
    toggle("btn.add", "plus", "open", "panel.add")
  end
  kids[#kids + 1] = ui.button({
    key = "btn.settings",
    glyph = "settings",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.settings"),
    onClick = function()
      h.openSettings()
    end,
  })
  kids[#kids + 1] = ui.button({
      key = "btn.close",
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.close"),
      onClick = function()
        h.close()
      end,
    })
  return ui.row({ key = "hdr", gap = 6, align = "center" }, kids)
end

-- ── search box ───────────────────────────────────────────────────────────────

local function searchBox(ui_state, tr, h)
  return ui.row({ key = "box.search", gap = 6, align = "center" }, {
    ui.input({
      key = "input.search#" .. tostring(ui_state.querySeq or 0),
      value = ui_state.query or "",
      placeholder = tr("panel.search_placeholder"),
      controlSize = "sm",
      flexGrow = 1,
      focus = true,
      onChange = function(value)
        h.setQuery(value)
      end,
    }),
    ui.button({
      key = "btn.search_close",
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.search_close"),
      onClick = function()
        h.setMode()
      end,
    }),
  })
end

-- ── path box ─────────────────────────────────────────────────────────────────

local function pathBox(snap, ui_state, tr, h, primary)
  local text = trim(ui_state.input)
  local git = uris.isGitUrl(text)
  local running = snap.clone and snap.clone.state == "running"
  local function submit(value)
    local t = trim(value)
    if t == "" then
      return
    end
    if uris.isGitUrl(t) then
      if snap.hasGit and not running then
        h.clone(t)
      end
    else
      h.openPath(t)
    end
  end
  local row = {
    ui.input({
      key = "input.path#" .. tostring(ui_state.inputSeq or 0),
      value = ui_state.input or "",
      placeholder = tr("panel.path_placeholder"),
      controlSize = "sm",
      flexGrow = 1,
      focus = true,
      onChange = function(value)
        h.setInput(value)
      end,
      onSubmit = function(value)
        submit(value)
      end,
    }),
  }
  -- A path opens on Enter; a git URL also gets a Clone button, since it starts a download.
  if git and not snap.hasGit then
    row[#row + 1] = small("lbl.no_git", tr("clone.no_git"), "error")
  elseif git then
    row[#row + 1] = ui.button({
      key = "btn.go",
      text = tr("panel.clone"),
      variant = primary == "go" and "primary" or "outline",
      controlSize = "sm",
      enabled = not running,
      onClick = function()
        submit(text)
      end,
    })
  end
  if snap.hasPicker then
    row[#row + 1] = ui.button({
      key = "btn.pick",
      glyph = "folder-open",
      tooltip = tr("panel.open_folder"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        h.pickFolder()
      end,
    })
  end
  local children = { ui.row({ key = "box.path.row", gap = 6, align = "center" }, row) }
  if git and snap.hasGit then
    local name = uris.cloneName(text)
    if name ~= nil then
      local base = (tostring(ui_state.cloneDir or "~/Projects"):gsub("/+$", ""))
      children[#children + 1] = ui.row({ key = "box.clone_dest", gap = 6, align = "center" }, {
        small("lbl.clone_dest", tr("clone.dest", { dest = base .. "/" .. name })),
        ui.button({
          key = "btn.clone_settings",
          text = tr("clone.change"),
          variant = "ghost",
          controlSize = "sm",
          tooltip = tr("clone.change_tooltip"),
          onClick = function()
            h.openSettings()
          end,
        }),
      })
    end
  end
  if not snap.hasPicker then
    children[#children + 1] = small("lbl.pick_hint", tr("panel.pick_hint"))
  end
  return ui.column({ key = "box.path", gap = 6 }, children)
end

-- ── clone status and errors ──────────────────────────────────────────────────

local function dismissButton(key, tr, h)
  return ui.button({
    key = key,
    glyph = "x",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.dismiss"),
    onClick = function()
      h.dismiss()
    end,
  })
end

local function cloneBox(snap, tr, h, primary)
  local c = snap.clone or {}
  local st = c.state
  if st == nil or st == "idle" then
    return nil
  end
  local name = c.name or ""
  local failed = st == "failed"
  local lines, trailing = {}, nil
  if st == "running" then
    lines[1] = label("lbl.clone", tr("clone.running", { name = name }), { fontSize = 12, maxLines = 1 })
    lines[2] = small("lbl.clone_progress", c.progress or tr("clone.starting"))
    trailing = ui.button({
      key = "btn.cancel_clone",
      text = tr("clone.cancel"),
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        h.cancelClone()
      end,
    })
  elseif st == "exists" then
    lines[1] = label("lbl.clone", tr("clone.exists", { dest = c.dest or name }), { fontSize = 12, maxLines = 2 })
    local dest = c.dest
    trailing = ui.row({ key = "box.clone.actions", gap = 4, align = "center" }, {
      ui.button({
        key = "btn.open_existing",
        text = tr("clone.open_existing"),
        variant = primary == "open_existing" and "primary" or "outline",
        controlSize = "sm",
        onClick = function()
          h.openExisting(dest)
        end,
      }),
      dismissButton("btn.dismiss_clone", tr, h),
    })
  elseif st == "done" then
    lines[1] = label("lbl.clone", tr("clone.done", { name = name }), { fontSize = 12, maxLines = 1 })
  elseif st == "cancelled" then
    lines[1] = label("lbl.clone", tr("clone.cancelled"), { fontSize = 12, maxLines = 1 })
  else
    -- clone.error is display text from the service (git's line or a translated message)
    lines[1] = label("lbl.clone", c.error or tr("error.clone_failed"), { fontSize = 12, color = "error", maxLines = 3 })
  end
  local children = {
    ui.glyph({
      key = "box.clone.glyph",
      name = failed and "alert-triangle" or "git-branch",
      size = 16,
      color = failed and "error" or "primary",
    }),
    ui.column({ key = "box.clone.text", gap = 2, flexGrow = 1 }, lines),
  }
  children[#children + 1] = trailing or dismissButton("btn.dismiss_clone", tr, h)
  return ui.row({
    key = "box.clone",
    gap = 8,
    align = "center",
    padding = 8,
    radius = 8,
    fill = failed and "error/0.12" or ROW_FILL,
    border = CLEAR,
    borderWidth = 1,
    opacity = 1,
  }, children)
end

local function errorBox(snap, tr, h)
  local err = snap.lastError
  if type(err) ~= "table" or type(err.key) ~= "string" then
    return nil
  end
  return ui.row({
    key = "box.error", gap = 8, align = "center", padding = 8, radius = 8,
    fill = "error/0.12", border = CLEAR, borderWidth = 1, opacity = 1,
  }, {
    ui.glyph({ key = "box.error.glyph", name = "alert-triangle", size = 16, color = "error" }),
    label("lbl.error", tr(err.key, { detail = err.detail or "" }), { fontSize = 11, color = "error", flexGrow = 1, maxLines = 3 }),
    dismissButton("btn.dismiss_error", tr, h),
  })
end

-- ── rows ─────────────────────────────────────────────────────────────────────

local function tag(key, text, glyph)
  local kids = {}
  if glyph then
    kids[1] = ui.glyph({ key = key .. ".glyph", name = glyph, size = 10, color = MUTED })
  end
  kids[#kids + 1] = label(key .. ".text", text, { fontSize = 9, fontWeight = "bold", color = MUTED })
  return ui.row({ key = key, border = "outline_variant", borderWidth = 1, radius = 4, paddingH = 4, gap = 3, align = "center" }, kids)
end

local function rowGlyph(e)
  if e.kind == "workspace" then
    return "layout-grid"
  end
  if not isLocal(e) then
    return "world"
  end
  return "folder"
end

local MENU_GLYPH = {
  pin = "pin", unpin = "pinned-off", open_terminal = "terminal-2", open_files = "folder-open",
  copy_path = "copy", hide = "eye-off", unhide = "eye",
}

local function actionList(k, e, tr, h)
  local buttons = {}
  local key = e.key
  for _, item in ipairs(view_panel.menuItems(e, tr)) do
    if item.id ~= nil then
      local id = item.id
      buttons[#buttons + 1] = ui.button({
        key = k .. ".act." .. id,
        text = item.label,
        glyph = MENU_GLYPH[id],
        variant = "ghost",
        controlSize = "sm",
        contentAlign = "start",
        onClick = function()
          h.action(id, key)
        end,
      })
    end
  end
  return ui.column({
    key = k .. ".actions", gap = 2, padding = 4, radius = 8,
    fill = "surface_container_high", border = "outline_variant", borderWidth = 1, opacity = 1,
  }, buttons)
end

local function projectRow(prefix, e, snap, ui_state, tr, h)
  local k = prefix .. e.key
  local top = {
    label(k .. ".title", e.title or e.path or e.key, { fontSize = 13, fontWeight = "semibold", maxLines = 1 }),
  }
  if e.pinned then
    top[#top + 1] = ui.glyph({ key = k .. ".pin", name = "pin", size = 12, color = MUTED })
  end
  if e.remote ~= nil then
    top[#top + 1] = tag(k .. ".remote", tr(TAG_TEXT[e.remote] or "tag.remote"))
  end
  if e.kind == "workspace" then
    top[#top + 1] = tag(k .. ".ws", tr("tag.workspace"))
  end
  if snap.cloned and snap.cloned[e.key] then
    top[#top + 1] = tag(k .. ".cloned", tr("tag.cloned"), "download")
  end
  if e.missing then
    top[#top + 1] = tag(k .. ".missing", tr("panel.missing"))
  end
  if e.hidden then
    top[#top + 1] = tag(k .. ".hidden", tr("tag.hidden"), "eye-off")
  end
  local sub = {
    label(k .. ".sub", e.subtitle or e.path or "", { fontSize = 10, color = MUTED, maxLines = 1, flexGrow = 1 }),
  }
  local g = snap.git and snap.git[e.key]
  if isLocal(e) and type(g) == "table" and g.branch ~= nil then
    sub[#sub + 1] = ui.glyph({ key = k .. ".branch.glyph", name = "git-branch", size = 11, color = MUTED })
    sub[#sub + 1] = small(k .. ".branch", g.branch)
    if g.dirty then
      sub[#sub + 1] = ui.box({ key = k .. ".dirty", width = 6, height = 6, radius = 3, fill = DIRTY })
    end
  end
  local key = e.key
  local missing = e.missing == true
  local dim = missing or e.hidden == true
  local rowKids = {
    ui.glyph({ key = k .. ".icon", name = rowGlyph(e), size = 18, color = MUTED }),
    ui.column({ key = k .. ".text", gap = 2, flexGrow = 1 }, {
      ui.row({ key = k .. ".top", gap = 6, align = "center" }, top),
      ui.row({ key = k .. ".bottom", gap = 4, align = "center" }, sub),
    }),
  }
  if e.hidden then
    rowKids[#rowKids + 1] = ui.button({
      key = k .. ".unhide",
      glyph = "eye",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.unhide"),
      onClick = function()
        h.unhide(key)
      end,
    })
  end
  rowKids[#rowKids + 1] = ui.button({
    key = k .. ".menu",
    glyph = "dots-vertical",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.actions"),
    onClick = function()
      h.toggleActions(key)
    end,
    onRightClick = function()
      h.menu(e)
    end,
  })
  local row = ui.row({
    key = k,
    gap = 10,
    align = "center",
    paddingH = 10,
    paddingV = 6,
    radius = 8,
    fill = ROW_FILL,
    border = CLEAR,
    borderWidth = 1,
    opacity = dim and 0.5 or 1,
    onClick = function()
      if missing then
        h.toggleActions(key)
      else
        h.open(key)
      end
    end,
  }, rowKids)
  local children = { row }
  if ui_state.expandedKey == key then
    children[2] = actionList(k, e, tr, h)
  end
  -- Always wrapped, so expanding never re-parents (and remounts) the row.
  return ui.column({ key = k .. ".wrap", gap = 4 }, children)
end

local function section(key, title, children)
  local list = { label(key .. ".title", title, { fontSize = 11, fontWeight = "semibold", color = MUTED }) }
  for _, c in ipairs(children) do
    list[#list + 1] = c
  end
  return ui.column({ key = key, gap = 6 }, list)
end

local function lists(snap, ui_state, tr, h)
  local out = {}
  local pinned, shown, more = visible(snap, ui_state)
  if #pinned > 0 then
    local rows = {}
    for _, e in ipairs(pinned) do
      rows[#rows + 1] = projectRow("row.pin.", e, snap, ui_state, tr, h)
    end
    out[#out + 1] = section("sec.pinned", tr("panel.pinned"), rows)
  end
  if #shown > 0 then
    local rows = {}
    for _, e in ipairs(shown) do
      rows[#rows + 1] = projectRow("row.rec.", e, snap, ui_state, tr, h)
    end
    if more then
      rows[#rows + 1] = ui.button({
        key = "btn.more",
        text = tr("panel.load_more"),
        glyph = "chevron-down",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          h.loadMore()
        end,
      })
    end
    out[#out + 1] = section("sec.recent", tr("panel.recent"), rows)
  end
  if #out == 0 then
    local empty = searchText(ui_state) ~= nil and "panel.no_match" or "panel.empty"
    out[1] = label("lbl.empty", tr(empty), { fontSize = 12, color = MUTED })
  end
  return out
end

-- ── build ────────────────────────────────────────────────────────────────────

local function flavorNames()
  local out = {}
  for _, f in ipairs(flavors.LIST) do
    out[#out + 1] = f.name
  end
  return table.concat(out, ", ")
end

function view_panel.build(snap, ui_state, tr, h)
  ui_state = ui_state or {}
  local children = { header(snap, ui_state, tr, h) }
  local function add(node)
    if node ~= nil then
      children[#children + 1] = node
    end
  end
  if type(snap) ~= "table" then
    add(label("lbl.loading", tr("panel.loading"), { fontSize = 12, color = MUTED }))
    return ui.column({ key = "root", gap = 12, padding = 14, flexGrow = 1 }, children)
  end
  if snap.flavor == nil and not snap.loading then
    add(ui.column({ key = "box.no_flavor", gap = 6, padding = 10, radius = 8, fill = ROW_FILL }, {
      label("lbl.no_flavor", tr("panel.no_flavor"), { fontSize = 12, maxLines = 2 }),
      small("lbl.looked_for", tr("panel.looked_for", { editors = flavorNames() })),
    }))
    add(errorBox(snap, tr, h))
    return ui.column({ key = "root", gap = 12, padding = 14, flexGrow = 1 }, children)
  end
  local primary = primaryOf(snap, ui_state)
  local fb = snap.flavorFallback
  if type(fb) == "table" and fb.wanted ~= nil and snap.flavor ~= nil then
    local key = fb.reason == "not_installed" and "panel.fallback_not_installed" or "panel.fallback_not_set_up"
    add(label("lbl.fallback", tr(key, { wanted = fb.wanted, using = snap.flavor.name }), { fontSize = 11, color = DIRTY, maxLines = 3 }))
  end
  if ui_state.mode == "search" then
    add(searchBox(ui_state, tr, h))
  elseif ui_state.mode == "open" then
    add(pathBox(snap, ui_state, tr, h, primary))
  end
  -- Outside the box: a failed open_path can land after the panel reopens with it closed.
  if snap.pathError ~= nil then
    add(label("lbl.path_error", tr(snap.pathError), { fontSize = 11, color = "error", maxLines = 2 }))
  end
  add(cloneBox(snap, tr, h, primary))
  add(errorBox(snap, tr, h))
  if snap.loading then
    add(label("lbl.loading", tr("panel.loading"), { fontSize = 12, color = MUTED }))
  else
    add(ui.scroll({ key = "list", gap = 12, flexGrow = 1 }, lists(snap, ui_state, tr, h)))
  end
  return ui.column({ key = "root", gap = 12, padding = 14, flexGrow = 1 }, children)
end

function view_panel.gitKeys(snap, ui_state)
  local out = {}
  if type(snap) ~= "table" or snap.loading then
    return out
  end
  local function addEntry(e)
    if isLocal(e) and not e.missing then
      out[#out + 1] = e.key
    end
  end
  local pinned, shown = visible(snap, ui_state or {})
  for _, e in ipairs(pinned) do
    addEntry(e)
  end
  for _, e in ipairs(shown) do
    addEntry(e)
  end
  return out
end

view_panel.MORE_STEP = MORE_STEP

function view_panel.menuItems(e, tr)
  local items = {
    { kind = "header", label = e.title or e.path or "" },
    { id = e.pinned and "unpin" or "pin", label = tr(e.pinned and "menu.unpin" or "menu.pin") },
  }
  if isLocal(e) then
    items[#items + 1] = { id = "open_terminal", label = tr("menu.open_terminal") }
    items[#items + 1] = { id = "open_files", label = tr("menu.open_files") }
  end
  items[#items + 1] = { id = "copy_path", label = tr("menu.copy_path") }
  items[#items + 1] = { kind = "separator" }
  if e.hidden then
    items[#items + 1] = { id = "unhide", label = tr("menu.unhide") }
  else
    items[#items + 1] = { id = "hide", label = tr("menu.hide") }
  end
  return items
end

function view_panel.menuRequest(id, key)
  if not MENU_ACTIONS[id] or type(key) ~= "string" then
    return nil
  end
  return { action = id, key = key }
end

return view_panel
