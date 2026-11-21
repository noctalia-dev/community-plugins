--!nonstrict
-- Rule-style editors: a filterable entry list (Outputs adds the display arrangement), an entry page with the
-- field groups, and the open window/layer picker.
local kit = require("../ui/kit.luau")
local form = require("./form.luau")
local outputs = require("./outputs.luau")

local M = {}

local function fieldSpec(ctx, eid, index, fid)
  local store = ctx.store
  local field = store.meta.fields[fid]
  local fpath = string.sub(fid, #eid + 2)
  local item = store.entryItems(eid)[index]
  local value = item.values[fpath]
  return {
    key = "e:" .. eid .. ":" .. index .. ":" .. fid, field = field, value = value, set = value ~= nil, changed = false,
    entry = { editor = eid, index = index },
    onSet = function(v) store.entryOp(eid, { op = "set", index = index - 1, field = fpath, value = v }) end,
    onUnset = field.opt and function() store.entryOp(eid, { op = "unset", index = index - 1, field = fpath }) end or nil,
  }
end

local function nameTaken(store, eid, name)
  for _, item in ipairs(store.entryItems(eid)) do
    if item.name == name then return true end
  end
  return false
end

-- The filter matches the title, the entry name and any text or number value (e.g. an app id pattern).
local function matches(title, item, filter)
  if kit.contains(title, filter) then return true end
  if item.name and kit.contains(item.name, filter) then return true end
  for _, value in pairs(item.values) do
    local kind = type(value)
    if (kind == "string" or kind == "number") and kit.contains(tostring(value), filter) then
      return true
    end
  end
  return false
end

local function editorList(ctx, eid, filter, multiple)
  local store, view = ctx.store, ctx.view
  local editor = store.meta.editors[eid]
  local items = store.entryItems(eid)
  local rows = {}
  local unsaved = store.entryOpCount(eid)
  if multiple or unsaved > 0 then
    local heading = { kit.section(editor.title) }
    if unsaved > 0 then
      table.insert(heading, ui.spacer({ flexGrow = 1 }))
      table.insert(heading, kit.badge(kit.plural(unsaved, "unsaved change"), "primary"))
    end
    table.insert(rows, ui.row({ key = "heading-" .. eid, gap = 8, align = "center" }, heading))
  end
  local shown = 0
  for index, item in ipairs(items) do
    local title = store.entryTitle(eid, index, item)
    local count = 0
    for _ in pairs(item.values) do count = count + 1 end
    local subtitle = kit.plural(count, "setting")
    if filter == "" or matches(title, item, filter) then
      shown = shown + 1
      table.insert(rows, kit.navRow({ key = "entry-" .. eid .. "-" .. index, title = title, subtitle = subtitle,
        onClick = function() ctx.go({ name = "entry", editor = eid, index = index }) end }))
    end
  end
  if shown == 0 then
    table.insert(rows, kit.muted(#items == 0 and ("No " .. string.lower(editor.title) .. " yet.") or "No matches."))
  end
  if editor.mode == "aot" then
    table.insert(rows, ui.row({ key = "add-" .. eid, gap = 6 }, {
      ui.button({ text = "Add", glyph = "plus", variant = "outline", controlSize = "sm", onClick = function()
        store.entryOp(eid, { op = "add" })
        ctx.go({ name = "entry", editor = eid, index = #store.entryItems(eid) })
      end }),
    }))
  else
    local placeholder = eid == "output" and "Connector or monitor name, e.g. DP-1" or "Name"
    table.insert(rows, kit.nameForm(ctx, "new-" .. eid, placeholder, "Add", function(name)
      if name == "" then ctx.flash("Enter a name first.", "warning"); return end
      if nameTaken(store, eid, name) then ctx.flash("“" .. name .. "” already exists.", "warning"); return end
      store.entryOp(eid, { op = "add", name = name })
      ctx.bump("new-" .. eid)
      ctx.go({ name = "entry", editor = eid, index = #store.entryItems(eid) })
    end))
  end
  return rows
end

local function listPage(ctx, route)
  local store, view = ctx.store, ctx.view
  local page = store.meta.pages[route.page]
  local header = { kit.header(ctx, route.page, page.help) }
  local content = {}
  if not store.state then return { header = header, content = { kit.loading("Loading config…") } } end
  if route.page == "Outputs" then
    local content, fill = outputs.content(ctx)
    return { header = header, content = content, fill = fill }
  end
  local filterKey = "filter-" .. route.page
  table.insert(content, kit.filterBox(ctx, filterKey, { placeholder = "Filter by name or value" }))
  local filter = kit.filterText(ctx, filterKey)
  for _, eid in ipairs(page.editors) do
    for _, row in ipairs(editorList(ctx, eid, filter, #page.editors > 1)) do table.insert(content, row) end
  end
  return { header = header, content = content }
end

-- "windows" when the editor matches windows by app id, "layers" when it matches layer surfaces, else nil
-- (read from the field paths in meta).
local function liveKind(editor, eid)
  local found = nil
  for _, group in ipairs(editor.groups) do
    for _, fid in ipairs(group.fields) do
      local fpath = string.sub(fid, #eid + 2)
      if fpath == "match.app_id" then return "windows" end
      if fpath == "match.namespace" then found = "layers" end
    end
  end
  return found
end

-- The app is itself the focused window, so it waits FOCUS_DELAY seconds for a switch to the window to match;
-- the panel is a layer surface and leaves the focus where it is.
local FOCUS_DELAY = 3
local function focusedWindowButton(ctx, eid, index)
  local store, view = ctx.store, ctx.view
  local asked = store.entryItems(eid)[index]  -- the rule the button belongs to; the wait may outlast a move
  local function ask()
    ctx.helper.call("focused-window", {}, function(err, data)
      view.focusBusy = false
      local window = not err and data.window or nil
      if store.entryItems(eid)[index] ~= asked then
        ctx.flash("The rules changed while waiting; press the button again.", "warning")
      elseif err then
        ctx.flash(err.error, "error")
      elseif type(window) ~= "table" then
        ctx.flash("No window has the focus.", "warning")
      elseif window.app_id == "umbriel-settings" then
        ctx.flash("That is this window: switch to the other one within " .. FOCUS_DELAY .. " seconds.", "warning")
      else
        store.entryOpsBatch(eid, { { op = "set", index = index - 1, field = "match.app_id", value = window.pattern } })
        ctx.bump("e:" .. eid .. ":" .. index .. ":" .. eid .. ":match.app_id")  -- the input key fieldSpec gives
        ctx.flash("The rule now matches “" .. window.app_id .. "”.", "info")
      end
      ctx.render()
    end)
  end
  return ui.button({ key = "focused-window", glyph = "focus-2", controlSize = "sm", variant = "outline",
    text = view.focusBusy and (ctx.isApp and "Switch to the window…" or "Asking…") or "Use the focused window",
    enabled = not view.focusBusy,
    tooltip = ctx.isApp and ("Match the app of the window you switch to within " .. FOCUS_DELAY .. " seconds")
      or "Match the app of the focused window",
    onClick = function()
      view.focusBusy = true
      ctx.render()
      if ctx.isApp then
        ctx.helper.call("wait", { seconds = FOCUS_DELAY }, function() ask() end)
      else
        ask()
      end
    end })
end

local function entryPage(ctx, route)
  local store = ctx.store
  local eid, index = route.editor, route.index
  local editor = store.meta.editors[eid]
  local items = store.entryItems(eid)
  local item = items[index]
  if not item then
    return kit.gone(ctx, editor.page)
  end
  local title = store.entryTitle(eid, index, item)
  local nav = {
    ui.button({ key = "prev", glyph = "chevron-left", variant = "ghost", enabled = index > 1, tooltip = "Previous",
                onClick = function() ctx.replace({ name = "entry", editor = eid, index = index - 1 }) end }),
    ui.button({ key = "next", glyph = "chevron-right", variant = "ghost", enabled = index < #items, tooltip = "Next",
                onClick = function() ctx.replace({ name = "entry", editor = eid, index = index + 1 }) end }),
  }
  local subtitle = editor.page .. " · " .. index .. " of " .. #items
  local display = eid == "output" and outputs.label(ctx, item.name) or nil
  if display then subtitle = subtitle .. " · " .. display end
  local header = { kit.header(ctx, title, subtitle, nav) }
  local actions = {}
  if editor.mode == "aot" or eid == "output" then
    local labelKey = "label-" .. eid .. "-" .. index
    table.insert(actions, ui.input({ key = labelKey .. ":" .. ctx.gen(labelKey), value = item.label or "", width = 260,
      controlSize = "sm", placeholder = eid == "output" and "Name in the overview (optional)" or "Display name (optional)",
      onChange = function(text)
        store.entryOp(eid, { op = "label", index = index - 1, text = text })
        ctx.render()
      end }))
  end
  if editor.mode == "aot" then
    table.insert(actions, kit.iconButton("arrow-up", "Move up (rules are checked in order)", function()
      store.entryOp(eid, { op = "move", index = index - 1, to = index - 2 })
      ctx.replace({ name = "entry", editor = eid, index = index - 1 })
    end, index > 1))
    table.insert(actions, kit.iconButton("arrow-down", "Move down", function()
      store.entryOp(eid, { op = "move", index = index - 1, to = index })
      ctx.replace({ name = "entry", editor = eid, index = index + 1 })
    end, index < #items))
    table.insert(actions, kit.iconButton("copy", "Duplicate", function()
      store.entryOp(eid, { op = "duplicate", index = index - 1 })
      ctx.replace({ name = "entry", editor = eid, index = index + 1 })
    end))
  end
  table.insert(actions, ui.spacer({ flexGrow = 1 }))
  table.insert(actions, kit.confirmButton(ctx, { key = "delete-" .. eid .. "-" .. index, text = "Delete",
                                               armedText = "Click again to delete", glyph = "trash",
                                               controlSize = "sm" }, function()
    store.entryOp(eid, { op = "remove", index = index - 1 })
    ctx.back()
  end))
  local content = { ui.row({ key = "entry-actions", gap = 6, align = "center" }, actions) }
  local live = liveKind(editor, eid)
  if live then
    local liveButtons = {
      ui.button({ text = live == "windows" and "Pick from open windows" or "Pick from open layers",
                  glyph = live == "windows" and "app-window" or "stack-2", controlSize = "sm", variant = "outline",
                  onClick = function()
                    ctx.view.live, ctx.view.liveFilter = nil, nil
                    ctx.bump("liveFilter")
                    ctx.go({ name = "pick-live", editor = eid, index = index, kind = live })
                  end }),
    }
    if live == "windows" then table.insert(liveButtons, focusedWindowButton(ctx, eid, index)) end
    table.insert(content, ui.row({ key = "entry-live", gap = 6, align = "center" }, liveButtons))
  end
  if editor.mode == "map" and eid ~= "output" then  -- a copy of an effect preset or pool; outputs are hardware
    table.insert(content, kit.nameForm(ctx, "dup-" .. eid, "Name for a copy", "Duplicate", function(name)
      if name == "" or nameTaken(store, eid, name) then ctx.flash("Choose a new, unused name.", "warning"); return end
      store.entryOp(eid, { op = "duplicate", index = index - 1, name = name })
      ctx.replace({ name = "entry", editor = eid, index = #store.entryItems(eid) })
    end))
  end
  local groups = form.groups(ctx, "entry:" .. eid, editor.groups,
    function(fid) return fieldSpec(ctx, eid, index, fid) end,
    function(fids)
      local set = 0
      for _, fid in ipairs(fids) do
        if item.values[string.sub(fid, #eid + 2)] ~= nil then set = set + 1 end
      end
      return 0, set
    end)
  for _, row in ipairs(groups) do table.insert(content, row) end
  return { header = header, content = content }
end

local LIVE_ROWS = kit.LIST_CAP

-- Pick a rule's match from what the running Umbriel shows: open windows (app id, title) or layer surfaces.
local function pickLivePage(ctx, route)
  local store, view = ctx.store, ctx.view
  local eid, index, kind = route.editor, route.index, route.kind
  local windows = kind == "windows"
  local rule = store.entryItems(eid)[index]
  local title = windows and "Open windows" or "Open layers"
  if not rule then
    return kit.gone(ctx, title)
  end
  local header = { kit.header(ctx, title, "Pick one for " .. store.entryTitle(eid, index, rule)) }
  if view.live == nil or view.live.kind ~= kind then
    view.live = { kind = kind, loading = true }
    ctx.helper.call(kind, {}, function(err, data)
      if not view.live or view.live.kind ~= kind then return end
      view.live = { kind = kind, items = (not err) and data[kind] or nil, error = err and err.error or nil }
      ctx.render()
    end)
  end
  if not view.live.error then
    -- a window opening or closing updates the list in place (the old one stays until the new one arrives)
    ctx.watchLive({ kind }, function()
      ctx.helper.call(kind, {}, function(err, data)
        if err or not view.live or view.live.kind ~= kind or view.live.loading then return end
        view.live = { kind = kind, items = data[kind] }
        ctx.render()
      end)
    end)
  end
  local live = view.live
  if live.loading then
    return { header = header, content = { kit.empty("Asking Umbriel…", "loader") } }
  end
  if live.error then
    return { header = header, content = { kit.retryNotice("live", live.error, function()
      view.live = nil
      ctx.render()
    end) } }
  end
  local function choose(values, shown)
    local ops = {}
    for _, pair in ipairs(values) do
      table.insert(ops, { op = "set", index = index - 1, field = pair[1], value = pair[2] })
    end
    store.entryOpsBatch(eid, ops)  -- app id and title are one undo step
    ctx.back()
    ctx.flash("The rule now matches “" .. shown .. "”.", "info")
  end
  local filter = kit.filterText(ctx, "liveFilter")
  local content = {
    kit.filterBox(ctx, "liveFilter", { placeholder = windows and "Filter by app id or title" or "Filter by namespace" }),
  }
  local shown, matches = 0, 0
  for position, item in ipairs(live.items or {}) do
    local name = windows and item.app_id or item.namespace
    local detail = windows and item.title or (item.layer .. " · " .. table.concat(item.outputs or {}, ", "))
    if filter == "" or kit.contains(name .. " " .. detail, filter) then
      matches = matches + 1
      if shown < LIVE_ROWS then
        shown = shown + 1
        local buttons = {}
        if windows then
          table.insert(buttons, ui.button({ text = "Match app", glyph = "check", variant = "primary", controlSize = "sm",
            tooltip = "Sets App ID to " .. item.pattern,
            onClick = function() choose({ { "match.app_id", item.pattern } }, name) end }))
          if item.title ~= "" then
            table.insert(buttons, ui.button({ text = "App and title", variant = "outline", controlSize = "sm",
              tooltip = "Also sets Title to this window's title",
              onClick = function()
                choose({ { "match.app_id", item.pattern }, { "match.title", item.title_pattern } }, name)
              end }))
          end
        else
          table.insert(buttons, ui.button({ text = "Match", glyph = "check", variant = "primary", controlSize = "sm",
            tooltip = "Sets Namespace to " .. item.pattern,
            onClick = function() choose({ { "match.namespace", item.pattern } }, name) end }))
        end
        local count = windows and item.count > 1 and (" · " .. item.count .. " windows") or ""
        table.insert(content, kit.card({ key = "live-" .. position }, {
          ui.row({ gap = 8, align = "center" }, {
            ui.column({ gap = 2, flexGrow = 1 }, {
              ui.label({ text = name .. count, fontSize = kit.FONT.item, fontWeight = "bold" }),
              kit.muted(detail ~= "" and detail or "(no title)", { maxLines = 1 }),
            }),
            ui.row({ gap = 6 }, buttons),
          }),
        }))
      end
    end
  end
  if matches == 0 then
    table.insert(content, kit.empty(#(live.items or {}) == 0
      and (windows and "Umbriel reported no open windows." or "Umbriel reported no layer surfaces.")
      or "No matches.", "search"))
  elseif matches > shown then
    table.insert(content, kit.muted(kit.plural(matches - shown, "more match", "more matches") .. "; filter to narrow."))
  end
  return { header = header, content = content }
end

function M.render(ctx, route)
  if route.name == "entry" then return entryPage(ctx, route) end
  if route.name == "pick-live" then return pickLivePage(ctx, route) end
  return listPage(ctx, route)
end

return M
