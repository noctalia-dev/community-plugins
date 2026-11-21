--!nonstrict
-- Keybinds: grouped list and a detail page with a shortcut builder (the action picker: keybind_actions.luau).
local kit = require("../ui/kit.luau")
local order = require("./keybind_order.luau")
local actions = require("./keybind_actions.luau")

local M = {}

local MODIFIERS = { "Mod", "Super", "Ctrl", "Alt", "Shift" }
local OPTION_CHOICES = { "Default", "On", "Off" }

local function normalizeKey(key) return string.lower((string.gsub(noctalia.string.trim(key), "%s+", " "))) end

local function splitShortcut(key)
  local mods, rest = {}, {}
  for part in string.gmatch(key or "", "[^+]+") do
    local known = false
    for _, mod in ipairs(MODIFIERS) do
      if string.lower(part) == string.lower(mod) and #rest == 0 then mods[mod] = true; known = true end
    end
    if not known then table.insert(rest, part) end
  end
  return mods, table.concat(rest, "+")
end

local function joinShortcut(mods, key)
  local parts = {}
  for _, mod in ipairs(MODIFIERS) do if mods[mod] then table.insert(parts, mod) end end
  if key ~= "" then table.insert(parts, key) end
  return table.concat(parts, "+")
end

local function conflict(store, key, index)
  local wanted = normalizeKey(key)
  if wanted == "" then return nil end
  for i, row in ipairs(store.keybinds.rows) do
    if i ~= index and normalizeKey(row.key) == wanted then return row.key end
  end
  return nil
end

-- Whether a group of that name exists (and says so).
local function groupTaken(ctx, name)
  for _, other in ipairs(ctx.store.keybinds.groups) do
    if other == name then ctx.flash("That group already exists.", "warning"); return true end
  end
  return false
end

local GAP = 8        -- the list's spacing; between rows it is an insertion zone while sorting is possible
local SLOP = 32      -- drag-only reach of a gap: about half a row, so the nearest gap follows the pointer

local function gapZone(key, accepts, value, height)
  return ui.dropZone({ key = key, accepts = { accepts }, value = value, onDrop = "onDrop", height = height,
                       expandOnDrag = true, hitSlop = SLOP })
end

local function grip(key, dragType, payload, ancestors, tooltip)
  return ui.dragSource({ key = key, dragType = dragType, payload = payload, previewAncestor = ancestors,
                         liftFromLayout = true, tooltip = tooltip, width = 20, height = 24, align = "center",
                         justify = "center" },
                       { ui.glyph({ name = "grip-vertical", size = kit.GLYPH.body, color = kit.MUTED }) })
end

-- ------------------------------------------------------------------ list
local function listPage(ctx)
  local store, view = ctx.store, ctx.view
  local header = { kit.header(ctx, "Keybinds", "Shortcuts, grouped. Locked shortcuts are protected from edits.", {
    ui.button({ key = "add", text = "Add shortcut", glyph = "plus", variant = "primary", controlSize = "sm",
                onClick = function()
                  view.kbNew = { key = "", action = "", opts = {}, group = view.kbGroup or "" }
                  ctx.go({ name = "keybind", index = nil })
                end }),
  }) }
  if not store.keybinds then return { header = header, content = { kit.loading() } } end
  local content = {
    kit.filterBox(ctx, "kbFilter", { placeholder = "Filter shortcuts and actions" }),
  }
  local filter = kit.filterText(ctx, "kbFilter")
  -- Sorting needs every row of a group on screen: a gap between filtered rows would be ambiguous.
  local sortable = filter == ""
  if sortable then
    ctx.dropHandler = function(payload, value) order.drop(ctx, payload, value) end
  elseif #store.keybinds.rows > 1 then
    table.insert(content, kit.muted("Clear the filter to reorder shortcuts and groups."))
  end
  local groups = {}
  for _, name in ipairs(store.keybinds.groups) do table.insert(groups, name) end
  table.insert(groups, "")
  view.kbCollapsed = view.kbCollapsed or {}
  local others = store.state and store.state.keybinds.other or {}
  local keyUses = {}  -- normalized shortcut -> rows using it (a conflict badge on each)
  for _, row in ipairs(store.keybinds.rows) do
    local normalized = normalizeKey(row.key)
    if normalized ~= "" then keyUses[normalized] = (keyUses[normalized] or 0) + 1 end
  end
  for position, group in ipairs(groups) do
    local groupIndex = position < #groups and position or 0
    local groupRef = "g|" .. groupIndex .. "|" .. group
    local name = group == "" and "Ungrouped" or group
    local collapsed = view.kbCollapsed[name] and filter == ""
    local rows, count = {}, 0
    for index, row in ipairs(store.keybinds.rows) do
      local inGroup = (row.group or "") == group
      if inGroup and (filter == "" or kit.contains(row.key .. " " .. row.action, filter)) then
        count = count + 1
        if not collapsed then
          local desc = actions.describe(store.meta, row.action)
          local badges = {}
          if (keyUses[normalizeKey(row.key)] or 0) > 1 then
            table.insert(badges, kit.badge("conflict", "error", "kbc-" .. index))
          end
          if row.locked then table.insert(badges, ui.glyph({ name = "lock", size = kit.GLYPH.small, color = kit.MUTED })) end
          local open = function() ctx.go({ name = "keybind", index = index }) end
          local ref = "r|" .. index .. "|" .. row.key
          if sortable then table.insert(rows, gapZone("kbgap-" .. index, "kbrow", ref, GAP)) end
          table.insert(rows, kit.navRow({ key = "kb-" .. index .. "-" .. row.key, title = row.key,
            subtitle = row.action .. (desc and ("  ·  " .. desc) or ""), badges = badges, onClick = open,
            leading = sortable and (row.locked and ui.box({ width = 20 })
              or grip("kbgrip-" .. index, "kbrow", ref, 1, "Drag to move this shortcut")) or nil }))
        end
      end
    end
    -- An empty group, and Ungrouped once groups exist, stay visible while sorting: they are drop targets.
    local shown = count > 0 or (filter == "" and (group ~= "" or (sortable and #groups > 1)))
    if shown then
      local headerChildren = {}
      if sortable then  -- Ungrouped stays last: a blank in place of the grip keeps the headers aligned
        table.insert(headerChildren, group == "" and ui.box({ width = 20 })
          or grip("kbggrip-" .. groupIndex, "kbgroup", groupRef, 2, "Drag to reorder this group"))
      end
      table.insert(headerChildren, ui.glyph({ name = collapsed and "chevron-right" or "chevron-down", size = kit.GLYPH.small,
                                              color = kit.MUTED }))
      table.insert(headerChildren, kit.section(name .. "  ·  " .. count, "kbgl-" .. name))
      local children = { ui.row({ key = "kbg-" .. name, gap = 8, align = "center", onClick = function()
        view.kbCollapsed[name] = not view.kbCollapsed[name]
        ctx.render()
      end }, headerChildren) }
      for _, row in ipairs(rows) do table.insert(children, row) end
      local key = groupIndex .. "-" .. name
      if sortable then
        if not collapsed and count > 0 then table.insert(children, gapZone("kbgend-" .. key, "kbrow", groupRef, 4)) end
        table.insert(content, gapZone("kbggap-" .. key, "kbgroup", groupRef, 4))
        -- the whole group takes rows (appended) and groups (placed before it)
        table.insert(content, ui.dropZone({ key = "kbgroup-" .. key, accepts = { "kbrow", "kbgroup" }, value = groupRef,
                                            onDrop = "onDrop", gap = 0 }, children))
      else
        table.insert(content, ui.column({ key = "kbgroup-" .. key, gap = GAP }, children))
      end
    end
  end
  if #others > 0 then
    table.insert(content, kit.notice("Kept as written (not editable here): " .. table.concat(others, ", "), "info",
      nil, "kb-others"))
  end
  -- group management
  table.insert(content, kit.section("Groups"))
  for index, group in ipairs(store.keybinds.groups) do
    table.insert(content, ui.row({ key = "grp-" .. index, gap = 6, align = "center" }, {
      ui.input({ key = "grp-name-" .. index .. "-" .. group, value = group, flexGrow = 1, controlSize = "sm",
                 onSubmit = function(text)
                   text = noctalia.string.trim(text)
                   if text == "" or text == group then return end
                   if groupTaken(ctx, text) then return end
                   store.keybinds.groups[index] = text
                   for _, row in ipairs(store.keybinds.rows) do if row.group == group then row.group = text end end
                   store.keybindsChanged()
                   ctx.render()
                 end }),
      -- the keyboard way to reorder groups (dragging is pointer-only)
      kit.iconButton("arrow-up", "Move group up", function()
        order.moveGroup(store.keybinds, index, index - 1)
        store.keybindsChanged()
        ctx.render()
      end, index > 1, "grp-up-" .. index),
      kit.iconButton("arrow-down", "Move group down", function()
        order.moveGroup(store.keybinds, index + 1, index)
        store.keybindsChanged()
        ctx.render()
      end, index < #store.keybinds.groups, "grp-down-" .. index),
      kit.iconButton("trash", "Delete group (its shortcuts move to Ungrouped)", function()
        table.remove(store.keybinds.groups, index)
        for _, row in ipairs(store.keybinds.rows) do if row.group == group then row.group = "" end end
        store.keybindsChanged()
        ctx.render()
      end),
    }))
  end
  table.insert(content, kit.nameForm(ctx, "grpNew", "New group name", "Add group", function(text)
    if text == "" or groupTaken(ctx, text) then return end
    table.insert(store.keybinds.groups, text)
    ctx.bump("grpNew")
    store.keybindsChanged()
    ctx.render()
  end))
  return { header = header, content = content }
end

-- ------------------------------------------------------------------ detail
local function detailPage(ctx, route)
  local store, view = ctx.store, ctx.view
  local isNew = route.index == nil
  local row = isNew and view.kbNew or store.keybinds.rows[route.index]
  if not row then return kit.gone(ctx, "Keybind", "This shortcut no longer exists.") end
  local locked = row.locked == true
  local function edit(step) if not isNew then store.keybindsChanged(step and (step .. ":" .. route.index)) end end
  -- the keyboard way to reorder shortcuts (dragging is pointer-only): swap with the neighbor in the group
  local moves = {}
  if not isNew then
    local above, below
    for i, other in ipairs(store.keybinds.rows) do
      if (other.group or "") == (row.group or "") then
        if i < route.index then above = i elseif i > route.index and not below then below = i end
      end
    end
    local function move(from, before)
      order.moveRow(store.keybinds, from, row.group or "", before)
      store.keybindsChanged()
      for i, other in ipairs(store.keybinds.rows) do
        if other == row then ctx.replace({ name = "keybind", index = i }); return end
      end
    end
    moves = {
      kit.iconButton("arrow-up", "Move up in its group", function() move(route.index, above) end,
                     not locked and above ~= nil, "kb-up"),
      kit.iconButton("arrow-down", "Move down in its group", function() move(below, route.index) end,
                     not locked and below ~= nil, "kb-down"),
    }
  end
  local header = { kit.header(ctx, isNew and "New shortcut" or row.key, row.action, moves) }
  local content = {}
  if locked then
    table.insert(content, kit.notice("This shortcut is locked. Unlock it to change or delete it.", "info", nil, "locked"))
  end
  -- shortcut builder
  local mods, key = splitShortcut(row.key)
  local chips = {}
  for _, mod in ipairs(MODIFIERS) do
    table.insert(chips, ui.button({ key = "mod-" .. mod, text = mod, controlSize = "sm", selected = mods[mod] == true,
      variant = mods[mod] and "primary" or "outline", enabled = not locked,
      tooltip = mod == "Mod" and "The modifier chosen in General › Mod key" or nil,
      onClick = function()
        mods[mod] = not mods[mod] or nil
        row.key = joinShortcut(mods, key)
        ctx.bump("kbkey")
        edit(); ctx.render()
      end }))
  end
  table.insert(chips, ui.input({ key = "kb-key-" .. ctx.gen("kbkey"), value = key, flexGrow = 1,
    controlSize = "sm", enabled = not locked, placeholder = "Key: Return, Q, F1, XF86AudioMute…",
    onChange = function(text)
      row.key = joinShortcut(mods, noctalia.string.trim(text))
      edit("key"); ctx.render()
    end }))
  if ctx.isApp then  -- app only: Noctalia passes the panel only its capture_keys
    table.insert(chips, ui.button({ key = "kb-record", text = view.kbRecording and "Cancel" or "Record…",
      glyph = "keyboard", controlSize = "sm", variant = view.kbRecording and "primary" or "outline",
      enabled = not locked, tooltip = "Press the shortcut instead of typing it", onClick = function()
        view.kbRecording = not view.kbRecording or nil
        ctx.render()
      end }))
  end
  local clash = conflict(store, row.key, route.index)
  local shortcutCard = {
    kit.muted("Shortcut"),
    ui.row({ key = "kb-chips", gap = 6, align = "center" }, chips),
    kit.muted("Writes: " .. (row.key ~= "" and row.key or "—")),
  }
  if view.kbRecording and not locked then
    table.insert(shortcutCard, ui.row({ key = "kb-recorder", gap = 8, align = "center", padding = 10,
      radius = kit.RADIUS.md, fill = "primary/0.12",
      onKeyRecord = function(shortcut)
        view.kbRecording = nil
        if shortcut ~= "" then
          row.key = shortcut
          ctx.bump("kbkey")
          edit("key")
        end
        ctx.render()
      end }, {
      ui.glyph({ name = "keyboard", size = kit.GLYPH.body, color = "primary" }),
      kit.label("Press the shortcut now (Esc cancels). Shortcuts Umbriel already uses never reach this window.",
                { flexGrow = 1, maxLines = 2 }),
    }))
  end
  if clash then table.insert(shortcutCard, kit.notice("Conflicts with “" .. clash .. "”.", "error", nil, "clash")) end
  table.insert(content, kit.card({ key = "shortcut" }, shortcutCard))
  -- action
  local desc, template = actions.describe(store.meta, row.action)
  local actionCard = {
    kit.muted("Action"),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({ key = "kb-action-" .. ctx.gen("kbaction"), value = row.action, flexGrow = 1,
                 controlSize = "sm", enabled = not locked, placeholder = "e.g. spawn kitty",
                 onChange = function(text) row.action = text; edit("action"); ctx.render() end }),
      ui.button({ text = "Choose…", glyph = "list-search", controlSize = "sm", enabled = not locked,
                  onClick = function() ctx.go({ name = "actions", target = route.index }) end }),
    }),
  }
  if desc then table.insert(actionCard, kit.muted(desc, { maxLines = 3 })) end
  local args = actions.argHelp(store.meta, template)
  if args ~= "" then table.insert(actionCard, kit.muted(args, { maxLines = 6 })) end
  local picker = actions.argumentPicker(ctx, row.action, template, not locked, function(action)
    row.action = action
    edit("action")
    ctx.bump("kbaction")  -- the action box shows the new text
    ctx.render()
  end)
  if picker then table.insert(actionCard, picker) end
  table.insert(actionCard, ui.row({ key = "kb-run-row", gap = 8, align = "center" }, {
    actions.runButton(ctx, noctalia.string.trim(row.action or "")),
    kit.muted(ctx.isApp and "Window actions act on the focused window: this one."
              or "Window actions act on the window behind this panel.", { flexGrow = 1, maxLines = 2 }),
  }))
  table.insert(content, kit.card({ key = "action" }, actionCard))
  -- options
  local optionRows = {}
  for _, option in ipairs(store.meta.actions.options) do
    local name, label = option[1], option[2]
    local value = row.opts[name]
    table.insert(optionRows, kit.optionRow("opt-" .. name, label,
      ui.select({ options = OPTION_CHOICES, selectedIndex = value == nil and 0 or (value and 1 or 2), width = 160,
                  controlSize = "sm", enabled = not locked, onChange = function(i)
                    i = tonumber(i) or 0
                    -- (not `i == 2 and false or nil`: that is always nil, so "off" could never be chosen)
                    local chosen = nil
                    if i == 1 then chosen = true elseif i == 2 then chosen = false end
                    row.opts[name] = chosen
                    edit(); ctx.render()
                  end })))
  end
  for _, item in ipairs({ { "cooldown_ms", "Cooldown (ms)", "0 = none" }, { "submap", "Submap", "Name (optional)" } }) do
    local name = item[1]
    table.insert(optionRows, kit.optionRow("opt-" .. name, item[2],
      ui.input({ key = "opt-in-" .. name, value = row.opts[name] ~= nil and tostring(row.opts[name]) or "", width = 160,
                 controlSize = "sm", enabled = not locked, placeholder = item[3], onChange = function(text)
                   text = noctalia.string.trim(text)
                   if name == "cooldown_ms" then
                     local number = tonumber(text)
                     row.opts[name] = (number and number > 0) and math.floor(number) or nil
                   else
                     row.opts[name] = text ~= "" and text or nil
                   end
                   edit("opt-" .. name)
                 end })))
  end
  local groupOptions, selected = { "Ungrouped" }, 0
  for index, group in ipairs(store.keybinds.groups) do
    table.insert(groupOptions, group)
    if group == row.group then selected = index end
  end
  table.insert(optionRows, kit.optionRow("opt-group", "Group",
    ui.select({ options = groupOptions, selectedIndex = selected, width = 160, controlSize = "sm",
                enabled = not locked, onChange = function(i)
                  i = tonumber(i) or 0
                  row.group = i == 0 and "" or store.keybinds.groups[i]
                  edit(); ctx.render()
                end })))
  if not isNew then
    table.insert(optionRows, kit.optionRow("opt-lock", "Locked (protect from edits here and in the app)",
      ui.toggle({ checked = locked, onChange = function(value) row.locked = value == "true"; edit(); ctx.render() end })))
  end
  table.insert(content, kit.card({ key = "options" }, optionRows))
  -- actions
  if isNew then
    table.insert(content, ui.row({ key = "new-actions", gap = 6 }, {
      ui.button({ text = "Add shortcut", glyph = "plus", variant = "primary", onClick = function()
        if noctalia.string.trim(row.key) == "" or noctalia.string.trim(row.action) == "" then
          ctx.flash("Enter a shortcut and an action.", "warning"); return
        end
        if clash then ctx.flash("That shortcut is already used by “" .. clash .. "”.", "warning"); return end
        table.insert(store.keybinds.rows, row)
        store.keybindsChanged()
        view.kbNew = nil
        ctx.replace({ name = "keybind", index = #store.keybinds.rows })
      end }),
    }))
  else
    table.insert(content, ui.row({ key = "row-actions", gap = 6 }, {
      ui.button({ text = "Duplicate", glyph = "copy", controlSize = "sm", variant = "outline", onClick = function()
        local copy = store.deepCopy(row)
        copy.key, copy.locked = "", false
        view.kbNew = copy
        ctx.bump("kbkey")  -- the inputs keep their keys: show the copy's (empty) shortcut
        ctx.bump("kbaction")
        ctx.replace({ name = "keybind", index = nil })
      end }),
      ui.spacer({ flexGrow = 1 }),
      kit.confirmButton(ctx, { key = "kbdel", text = "Delete", armedText = "Click again to delete", glyph = "trash",
                               controlSize = "sm", enabled = not locked }, function()
        table.remove(store.keybinds.rows, route.index)
        store.keybindsChanged()
        ctx.back()
      end),
    }))
  end
  return { header = header, content = content }
end

function M.render(ctx, route)
  if route.name == "keybind" then return detailPage(ctx, route) end
  if route.name == "actions" then return actions.pickerPage(ctx, route) end
  return listPage(ctx)
end

return M
