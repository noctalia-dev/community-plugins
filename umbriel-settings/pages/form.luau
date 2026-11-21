--!nonstrict
-- Settings pages: groups as an accordion (one open at a time keeps renders small), rows from ui/fields.
local kit = require("../ui/kit.luau")
local fields = require("../ui/fields.luau")
local titlebar = require("../lib/titlebar.luau")

local M = {}

-- KDE color buttons for title-bar colors. On the followable backgrounds they also show without a readable qt6ct
-- scheme when Noctalia is installed, because following uses Noctalia's palette roles, not the scheme file.
local function kdeSources(ctx, path, follows)
  if string.sub(path, 1, 17) ~= "colors.title_bar." then return nil end
  ctx.loadKde()
  local kde = ctx.kde or { colors = {}, backgrounds = {} }
  local state = follows and titlebar.state(ctx) or nil
  local noctalia = state ~= nil and state.noctalia == true
  local sources = {}
  if kde.colors[path] or noctalia then
    table.insert(sources, { label = "KDE", source = "kde", hex = kde.colors[path],
                           tooltip = "the KDE window decoration colors" })
  end
  if kde.backgrounds[path] or noctalia then
    table.insert(sources, { label = "KDE header", source = "kde_header", hex = kde.backgrounds[path],
                           tooltip = "the KDE header background" })
  end
  return #sources > 0 and sources or nil
end

local function pageFieldSpec(ctx, fid)
  local store = ctx.store
  local field = store.meta.fields[fid]
  local value, set = store.value(fid)
  local changed = store.isChanged(fid)
  local follows = field.opacity and field.kind == "color"  -- title-bar backgrounds can follow Noctalia
  return {
    key = fields.rowKey(fid), field = field, value = value, set = set, changed = changed,
    -- a fixed color (or none) stops following once saved
    onSet = function(v)
      if follows then titlebar.setFixed(ctx, fid, v) else store.setField(fid, v) end
    end,
    onUnset = field.opt and function()
      if follows then titlebar.setFixed(ctx, fid, nil) else store.unsetField(fid) end
    end or nil,
    onRevert = changed and function() store.revertField(fid) end or nil,
    diagnostic = ctx.diagnostics and ctx.diagnostics[fid] or nil,
    kdeColors = kdeSources(ctx, field.path, follows),
    follow = follows and titlebar.following(ctx, fid) or nil,
    onFollow = follows and function(source, opacity) titlebar.follow(ctx, fid, source, opacity) end or nil,
  }
end

-- groups: { { title, help, fields = { ids } } }; spec(fid) builds the row spec; counts(fids) -> changed, customized
function M.groups(ctx, pageKey, groups, spec, counts)
  local view = ctx.view
  if view.expanded[pageKey] == nil then
    view.expanded[pageKey] = false  -- every group closed until one is opened
  end
  local open = view.expanded[pageKey]
  local onlyCustomized = view.onlyCustomized
  local content = {}
  for _, group in ipairs(groups) do
    local changed, customized = counts(group.fields)
    local isOpen = open == group.title
    local badges = {}
    if changed > 0 then table.insert(badges, kit.badge(changed .. " unsaved", "primary", "gc-" .. group.title)) end
    if customized > 0 then
      table.insert(badges, kit.badge(customized .. " customized", "secondary", "go-" .. group.title))
    end
    if not onlyCustomized or customized > 0 or changed > 0 then
      if group.restart then
        table.insert(badges, 1, ui.row({ key = "gr-" .. group.title, tooltip = "Takes effect after restarting Umbriel" },
          { ui.glyph({ name = "refresh-alert", size = kit.GLYPH.small, color = "tertiary" }) }))
      end
      table.insert(content, kit.navRow({
        key = "group-" .. group.title, title = group.title, subtitle = group.help,
        bold = true, badges = badges, trailing = isOpen and "chevron-up" or "chevron-down",
        fill = isOpen and "surface_container_high" or "surface_container",
        onClick = function()
          view.expanded[pageKey] = (not isOpen) and group.title or false
          ctx.render()
        end,
      }))
    end
    if isOpen then
      local rows = {}
      local shown = 0
      for _, fid in ipairs(group.fields) do
        local row = spec(fid)
        if not onlyCustomized or row.changed or (row.set and ctx.store.differs(row.field, row.value)) then
          if shown > 0 then
            table.insert(rows, ui.separator({ key = "sep-" .. fid, thickness = 1, opacity = 0.5 }))
          end
          table.insert(rows, fields.row(ctx, row))
          shown = shown + 1
        end
      end
      if shown == 0 then table.insert(rows, kit.muted("No customized settings in this group.")) end
      if changed > 0 and string.sub(pageKey, 1, 6) ~= "entry:" then  -- page fields only: entries are ops
        table.insert(rows, ui.row({ key = "group-revert-row-" .. group.title }, {
          ui.spacer({ flexGrow = 1 }),
          kit.confirmButton(ctx, { key = "group-revert-" .. group.title, text = "Undo unsaved in this group",
                                   armedText = "Click again to undo " .. kit.plural(changed, "change"),
                                   glyph = "arrow-back-up", controlSize = "sm" }, function()
            ctx.store.group(function()
              for _, fid in ipairs(group.fields) do
                if ctx.store.isChanged(fid) then ctx.store.revertField(fid) end
              end
            end)
            ctx.resetInputs()
            ctx.render()
          end),
        }))
      end
      table.insert(content, ui.column({ key = "group-body-" .. group.title, gap = 2, paddingH = 4 }, rows))
    end
  end
  if #content == 0 then
    table.insert(content, kit.empty("No settings on this page differ from their defaults.", "filter"))
  end
  return content
end

local function onlyCustomizedToggle(ctx)
  return ui.row({ key = "only", gap = 6, align = "center", tooltip = "Show only settings that differ from the default" }, {
    kit.muted("Only customized"),
    ui.toggle({ checked = ctx.view.onlyCustomized == true, onChange = function(value)
      ctx.view.onlyCustomized = value == "true"
      ctx.render()
    end }),
  })
end

function M.render(ctx, route)
  local store = ctx.store
  local page = store.meta.pages[route.page]
  if route.group and not route.opened then
    ctx.view.expanded[route.page] = route.group
    route.opened = true
  end
  local header = { kit.header(ctx, route.page, page.help, { onlyCustomizedToggle(ctx) }) }
  if not store.state then return { header = header, content = { kit.loading("Loading config…") } } end
  local filterKey = "page-filter-" .. route.page
  local filter = kit.filterText(ctx, filterKey)
  local content = { kit.filterBox(ctx, filterKey, { placeholder = "Filter settings on this page" }) }
  if filter == "" then
    for _, row in ipairs(M.groups(ctx, route.page, page.groups, function(fid) return pageFieldSpec(ctx, fid) end,
                                  store.groupCounts)) do
      table.insert(content, row)
    end
  else
    -- Matching rows of every group, flat and capped (rows are the costly part of a render).
    local shown = 0
    for _, group in ipairs(page.groups) do
      for _, fid in ipairs(group.fields) do
        local field = store.meta.fields[fid]
        local text = string.lower(field.label .. " " .. field.path .. " " .. group.title)
        if shown < 30 and string.find(text, filter, 1, true) then
          if shown > 0 then table.insert(content, ui.separator({ key = "sep-" .. fid, thickness = 1, opacity = 0.5 })) end
          table.insert(content, fields.row(ctx, pageFieldSpec(ctx, fid)))
          shown = shown + 1
        end
      end
    end
    if shown == 0 then table.insert(content, kit.empty("No settings on this page match.", "filter")) end
    if shown == 30 then table.insert(content, kit.muted("Showing 30 settings; type more to narrow it down.")) end
  end
  return { header = header, content = content }
end

return M
