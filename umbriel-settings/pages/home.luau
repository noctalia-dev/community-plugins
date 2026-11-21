--!nonstrict
-- Home: search everything, or pick a page from cards grouped like the app's sidebar.
local kit = require("../ui/kit.luau")
local search = require("../lib/search.luau")
local fields = require("../ui/fields.luau")
local format = require("../ui/format.luau")

local M = {}

-- Unsaved changes and customized items of a page (home cards).
local function pageCounts(store, name)
  local page = store.meta.pages[name]
  if page.kind == "form" then
    local changed, customized = 0, 0
    for _, group in ipairs(page.groups) do
      local c, o = store.groupCounts(group.fields)
      changed, customized = changed + c, customized + o
    end
    return changed, customized
  end
  local customized = 0
  if page.kind == "entries" then
    for _, eid in ipairs(page.editors) do customized = customized + #store.entryItems(eid) end
  elseif page.kind == "map" then
    for _, eid in ipairs(page.maps) do customized = customized + #store.mapRows(eid) end
  elseif page.kind == "keybinds" then
    customized = store.keybinds and #store.keybinds.rows or 0
  end
  return M.pageChanges(store, name), customized
end

-- Only the unsaved changes of a page: the app's sidebar shows them on every render, so this skips the
-- per-field default comparison pageCounts needs for "customized".
function M.pageChanges(store, name)
  local page = store.meta.pages[name]
  local changed = 0
  if page.kind == "form" then
    if next(store.fieldChanges) == nil then return 0 end
    for _, group in ipairs(page.groups) do
      for _, fid in ipairs(group.fields) do
        if store.fieldChanges[fid] then changed = changed + 1 end
      end
    end
  elseif page.kind == "entries" then
    for _, eid in ipairs(page.editors) do changed = changed + store.entryOpCount(eid) end
  elseif page.kind == "map" then
    for _, eid in ipairs(page.maps) do changed = changed + store.mapOpCount(eid) end
  elseif page.kind == "keybinds" then
    changed = store.keybindsDirty and 1 or 0
  end
  return changed
end

local function countLabel(kind, count)
  if kind == "form" then return kit.plural(count, "customized setting") end
  if kind == "keybinds" then return kit.plural(count, "shortcut") end
  if kind == "map" or kind == "entries" then return kit.plural(count, "entry", "entries") end
  return nil
end

local function pageCard(ctx, name)
  local store = ctx.store
  local page = store.meta.pages[name]
  local changed, customized = pageCounts(store, name)
  local badges = {}
  if changed > 0 then table.insert(badges, kit.badge(changed .. " unsaved", "primary", "b-" .. name)) end
  local summary = countLabel(page.kind, customized)
  return kit.rowCard({ key = "card-" .. name, gap = 12, align = "center", paddingH = 12, paddingV = 7, flexGrow = 1,
                       tooltip = page.help, onClick = function() ctx.openPage(name) end }, {
    ui.glyph({ name = page.glyph or "settings", size = kit.GLYPH.row, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = name, fontSize = kit.FONT.item, fontWeight = "bold", maxLines = 1 }),
      kit.muted(summary or page.help or "", { maxLines = 1 }),
    }),
    ui.row({ gap = 4 }, badges),
  })
end

local function results(ctx, query)
  local store = ctx.store
  if not store.searchIndex then
    ctx.loadSearchIndex()
    return { kit.empty("Preparing search…", "search") }
  end
  local hits, cut = search.run(store, query)
  if #hits == 0 then return { kit.empty("Nothing matches “" .. query .. "”.", "search") } end
  local rows = {}
  for index, hit in ipairs(hits) do
    local key = "hit-" .. index
    if hit.kind == "page" then
      local page = store.meta.pages[hit.page]
      table.insert(rows, kit.navRow({ key = key, glyph = page.glyph, title = hit.page, subtitle = page.help,
                                      bold = true, onClick = function() ctx.openPage(hit.page) end }))
    elseif hit.kind == "field" then
      local field = store.meta.fields[hit.id]
      local where = search.locate(store.meta, hit.id)
      local subtitle = where and (where.page .. (where.group and (" › " .. where.group) or "")) or field.path
      local value, set = store.value(hit.id)
      local badges = {}
      if store.isChanged(hit.id) then table.insert(badges, kit.badge("unsaved", "primary", key .. "-c")) end
      if where and not where.editor and set then
        table.insert(badges, kit.badge(format.value(field, value), "secondary", key .. "-v"))
      end
      table.insert(rows, kit.navRow({ key = key, glyph = "adjustments", title = field.label, subtitle = subtitle,
        badges = badges, tooltip = field.help, onClick = function()
          ctx.openField(hit.id, where)
        end }))
    elseif hit.kind == "entry" then
      local editor = store.meta.editors[hit.editor]
      table.insert(rows, kit.navRow({ key = key, glyph = store.meta.pages[editor.page].glyph, title = hit.title,
        subtitle = editor.page, onClick = function()
          ctx.go({ name = "entry", editor = hit.editor, index = hit.index })
        end }))
    else
      local row = store.keybinds.rows[hit.index]
      table.insert(rows, kit.navRow({ key = key, glyph = "command", title = row.key, subtitle = row.action,
        onClick = function() ctx.go({ name = "keybind", index = hit.index }) end }))
    end
  end
  if cut then table.insert(rows, kit.muted("Showing the best " .. search.LIMIT .. " matches. Type more to narrow the search.")) end
  return rows
end

-- Every page setting that differs from Umbriel's default, page by page; rows open the setting.
local CUSTOMIZED_LIMIT = kit.LIST_CAP
-- Rows for settings that differ from Umbriel's defaults, in sidebar order: (rows, shown, total).
-- `sections` adds a page heading before each page's first row; else the subtitle names the page.
local function customizedRows(ctx, limit, sections)
  local store = ctx.store
  local rows, shown, total = {}, 0, 0
  for _, section in ipairs(store.meta.nav) do
    for _, name in ipairs(section.pages) do
      local page = store.meta.pages[name]
      local first = true
      for _, group in ipairs(page and page.groups or {}) do
        for _, fid in ipairs(group.fields) do
          if store.isOverridden(fid) then
            total = total + 1
            if shown < limit then
              shown = shown + 1
              if first and sections then table.insert(rows, kit.section(name, "cs-" .. name)) end
              first = false
              local field = store.meta.fields[fid]
              local value = store.value(fid)
              local badges = { kit.badge(format.value(field, value), "secondary", "cv-" .. fid) }
              if store.isChanged(fid) then table.insert(badges, 1, kit.badge("unsaved", "primary", "cc-" .. fid)) end
              local where = sections and group.title or (name .. " › " .. group.title)
              table.insert(rows, kit.navRow({ key = "cust-" .. fid, glyph = page.glyph, title = field.label,
                subtitle = where .. (field.default ~= nil and ("  ·  default " .. format.value(field, field.default)) or ""),
                badges = badges, tooltip = field.help, onClick = function()
                  ctx.openPage(name, { group = group.title, reveal = fields.rowKey(fid) })
                end }))
            end
          end
        end
      end
    end
  end
  return rows, shown, total
end

function M.renderCustomized(ctx)
  local store = ctx.store
  local header = { kit.header(ctx, "Customized settings", "Settings that differ from Umbriel's defaults") }
  if not store.state then return { header = header, content = { kit.loading("Loading config…") } } end
  local content, shown, total = customizedRows(ctx, CUSTOMIZED_LIMIT, true)
  if total == 0 then
    table.insert(content, kit.empty("Every setting uses Umbriel's default.", "adjustments-check"))
  elseif total > shown then
    table.insert(content, kit.muted("Showing " .. shown .. " of " .. total .. " customized settings; the pages' "
                                    .. "“Only customized” switch shows the rest."))
  end
  return { header = header, content = content }
end

local function openInEditor(ctx, path)
  ctx.helper.call("open-config", { config = path }, function(err)
    if err then ctx.flash(err.error, "error") end
  end)
end

local function editFileButton(ctx, path, variant)
  return ui.button({ text = "Edit file", glyph = "file-text", controlSize = "sm", variant = variant,
                     tooltip = "Open the config in your editor (set under About)",
                     onClick = function() openInEditor(ctx, path) end })
end

local function pathRow(ctx, path)
  local view = ctx.view
  return ui.row({ key = "path-row", gap = 8, align = "center" }, {
    ui.input({ key = "path:" .. ctx.gen("path"), value = path, flexGrow = 1, controlSize = "sm",
               placeholder = "~/.config/umbriel/config.toml",
               onChange = function(text) view.pathDraft = text end,
               onSubmit = function(text) view.pathDraft = text; ctx.switchConfig() end }),
    ui.button({ text = "Open", controlSize = "sm", tooltip = "Load this config file", enabled = not ctx.loading.config,
                onClick = function() ctx.switchConfig() end }),
    kit.iconButton("refresh", "Reload from disk", function() ctx.reload() end, not ctx.loading.config),
  })
end

local function footer(ctx)
  local store = ctx.store
  local path = store.state and store.state.path or ""
  local rows = { kit.section("Config file"), pathRow(ctx, path) }
  local tools = {
    ui.button({ text = "Customized", glyph = "adjustments-check", controlSize = "sm", variant = "outline",
                tooltip = "Settings that differ from Umbriel's defaults",
                onClick = function() ctx.go({ name = "customized" }) end }),
    ui.button({ text = "Backups", glyph = "history", controlSize = "sm", variant = "outline",
                onClick = function() ctx.go({ name = "backups" }) end }),
    editFileButton(ctx, path, "outline"),
  }
  if not ctx.isApp then  -- the app is the standalone app
    table.insert(tools, ui.button({ text = "Standalone app", glyph = "external-link", controlSize = "sm",
      variant = "outline", onClick = function()
        ctx.helper.call("launch-app", {}, function(err)
          if err then ctx.flash(err.error, "error") else panel.close() end
        end)
      end }))
  end
  table.insert(tools, ui.button({ text = "About", glyph = "info-circle", controlSize = "sm", variant = "ghost",
                                  onClick = function() ctx.go({ name = "about" }) end }))
  table.insert(rows, ui.row({ key = "tools", gap = 8 }, tools))
  return rows
end

-- The app's Home (its sidebar already lists the pages): the config file, what is customized, recent backups.
local DASHBOARD_ROWS, DASHBOARD_BACKUPS = 8, 3

local function card(key, title, glyph, actions, children)
  local head = { ui.glyph({ name = glyph, size = kit.GLYPH.large, color = "primary" }),
                 ui.label({ text = title, fontSize = kit.FONT.item, fontWeight = "bold", flexGrow = 1 }) }
  for _, action in ipairs(actions or {}) do table.insert(head, action) end
  local body = { ui.row({ key = key .. "-head", gap = 8, align = "center" }, head) }
  for _, child in ipairs(children) do table.insert(body, child) end
  return kit.card({ key = key }, body)
end

local function recentBackups(ctx, path)
  local view = ctx.view
  local revision = ctx.store.state.revision and ctx.store.state.revision.config or ""
  local cache = view.homeBackups
  if not cache or cache.path ~= path or cache.revision ~= revision then  -- again after every save or restore
    cache = { path = path, revision = revision, loading = true }
    view.homeBackups = cache
    ctx.helper.call("backups", { config = path }, function(err, data)
      cache.loading = false
      if err then cache.error = err.error else cache.list = data.backups end
      ctx.render()
    end)
  end
  if cache.error then return { kit.notice(cache.error, "error", nil, "home-bk-error") } end
  if cache.loading then return { kit.muted("Loading…") } end
  local rows = {}
  for index, item in ipairs(cache.list or {}) do
    if index > DASHBOARD_BACKUPS then break end
    table.insert(rows, ui.row({ key = "home-bk-" .. index, gap = 8, align = "center", paddingH = 4 }, {
      ui.glyph({ name = "history", size = kit.GLYPH.body, color = kit.MUTED }),
      kit.label(item.time, { flexGrow = 1 }),
      kit.muted(kit.fileSize(item.size)),
    }))
  end
  if #rows == 0 then table.insert(rows, kit.muted("No backups yet; one is taken before every save.")) end
  return rows
end

local function dashboard(ctx, content)
  local store = ctx.store
  local path = store.state.path
  local pending = store.pendingCount()
  table.insert(content, card("home-config", "Config file", "file-settings", {
    editFileButton(ctx, path, "ghost"),
  }, {
    pathRow(ctx, path),
    kit.muted(pending > 0 and (kit.plural(pending, "unsaved change") .. " — review them with Ctrl+S.")
      or "No unsaved changes."),
  }))
  local rows, shown, total = customizedRows(ctx, DASHBOARD_ROWS, false)
  if total == 0 then rows = { kit.muted("Every setting uses Umbriel's default.") } end
  table.insert(content, card("home-custom", "Customized settings", "adjustments-check",
    total > shown and { ui.button({ text = "Show all " .. total, controlSize = "sm", variant = "ghost",
                                    onClick = function() ctx.go({ name = "customized" }) end }) } or nil,
    rows))
  table.insert(content, card("home-backups", "Recent backups", "history", {
    ui.button({ text = "All backups", controlSize = "sm", variant = "ghost",
                onClick = function() ctx.go({ name = "backups" }) end }),
  }, recentBackups(ctx, path)))
end

function M.render(ctx)
  local store, view = ctx.store, ctx.view
  local subtitle = store.state and store.state.path or (ctx.loading.config and "Loading config…" or "")
  local header = { kit.header(ctx, ctx.isApp and "Home" or "Umbriel Settings", subtitle) }
  -- the app's sidebar has the search box; the panel shows it here
  if not ctx.isApp then
    table.insert(header, kit.searchBox(ctx, {
      placeholder = "Search settings, rules and shortcuts  (Ctrl+F)",
      onChange = function(text)
        view.query = text
        ctx.render()
      end,
    }))
  end
  local content = {}
  if ctx.configError then
    table.insert(content, kit.notice(ctx.configError, "error", nil, "config-error"))
    table.insert(content, ui.row({ key = "config-retry", gap = 8 }, {
      ui.button({ text = "Try again", glyph = "refresh", controlSize = "sm", variant = "outline",
                  enabled = not ctx.loading.config, onClick = function() ctx.reload() end }),
    }))
  end
  local query = noctalia.string.trim(view.query or "")
  if query ~= "" then
    for _, row in ipairs(results(ctx, query)) do table.insert(content, row) end
    return { header = header, content = content }
  end
  if not store.state then
    if not ctx.configError then table.insert(content, kit.loading("Loading config…")) end
  elseif ctx.isApp then
    dashboard(ctx, content)
    return { header = header, content = content }
  else
    for i, section in ipairs(store.meta.nav) do
      for _, node in ipairs(kit.groupHeading(section.title, nil, i == 1)) do table.insert(content, node) end
      local row = {}
      for _, name in ipairs(section.pages) do
        if store.meta.pages[name] then
          table.insert(row, pageCard(ctx, name))
          if #row == 2 then
            table.insert(content, ui.row({ key = "cards-" .. name, gap = 8 }, row))
            row = {}
          end
        end
      end
      if #row == 1 then
        table.insert(row, ui.column({ flexGrow = 1, paddingH = 12, paddingV = 7 }, {}))  -- as a card: columns match
        table.insert(content, ui.row({ key = "cards-end-" .. section.title, gap = 8 }, row))
      end
    end
  end
  for _, item in ipairs(footer(ctx)) do table.insert(content, item) end
  return { header = header, content = content }
end

return M
