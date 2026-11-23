--!nonstrict
-- Keyboard layout picker: layouts (ordered, each with its variant) and XKB options, from XKB's own list.
-- Edits [input.keyboard] (route without editor) or one [[input.device]] entry (route.editor, route.index).
local kit = require("../ui/kit.luau")

local M = {}

local RESULTS = kit.LIST_CAP

local function split(text)
  local list = {}
  if type(text) ~= "string" or text == "" then return list end
  for part in string.gmatch(text .. ",", "([^,]*),") do table.insert(list, noctalia.string.trim(part)) end
  return list
end

-- Lookup tables, built once when the list arrives (the list itself never changes while running).
local function index(data)
  local layouts, options = {}, {}
  for _, layout in ipairs(data.layouts or {}) do layouts[layout.name] = layout.desc end
  for _, group in ipairs(data.options or {}) do
    for _, item in ipairs(group.items) do options[item.name] = group.desc .. ": " .. item.desc end
  end
  data.layoutDesc, data.optionDesc = layouts, options
end

-- get(part) / set(part, text) for the keys of the keyboard being edited; nil when the entry is gone.
local function target(ctx, route)
  local store = ctx.store
  if route.editor then
    local eid, at = route.editor, route.index
    local item = store.entryItems(eid)[at]
    if not item then return nil end
    return {
      title = store.entryTitle(eid, at, item),
      get = function(part) return (store.entryItems(eid)[at] or { values = {} }).values[part] end,
      set = function(part, text)
        if text == "" then
          store.entryOp(eid, { op = "unset", index = at - 1, field = part })
        else
          store.entryOp(eid, { op = "set", index = at - 1, field = part, value = text })
        end
      end,
    }
  end
  local view = ctx.view
  if not view.xkbFields then
    view.xkbFields = {}
    for fid, field in pairs(store.meta.fields) do
      if field.xkb and not string.find(fid, ":", 1, true) then view.xkbFields[field.xkb] = fid end
    end
  end
  local fids = view.xkbFields
  return {
    title = "Keyboard",
    get = function(part) return fids[part] and (store.value(fids[part])) or nil end,
    set = function(part, text)
      if not fids[part] then return end
      if text == "" then store.unsetField(fids[part]) else store.setField(fids[part], text) end
    end,
  }
end

-- Writes the layouts and their variants as one undo step (the variants only when they change).
local function writeLayouts(ctx, keyboard, layouts, variants)
  local any = false
  for i = 1, #layouts do
    variants[i] = variants[i] or ""
    if variants[i] ~= "" then any = true end
  end
  for i = #variants, #layouts + 1, -1 do table.remove(variants, i) end
  local variant = any and table.concat(variants, ",") or ""
  ctx.store.group(function()
    keyboard.set("layout", table.concat(layouts, ","))
    if variant ~= tostring(keyboard.get("variant") or "") then keyboard.set("variant", variant) end
  end)
end

local function layoutRows(ctx, data, keyboard, layouts, variants)
  local rows = { kit.section("Layouts", "xkb-layouts") }
  if #layouts == 0 then
    table.insert(rows, kit.muted("No layout set: Umbriel uses XKB's default (us). Add one below.", { key = "xkb-none" }))
  end
  for i, name in ipairs(layouts) do
    local choices, labels, selected = { "" }, { "Default variant" }, 0
    for _, variant in ipairs(data.variants[name] or {}) do
      table.insert(choices, variant.name)
      table.insert(labels, variant.desc .. " (" .. variant.name .. ")")
      if variant.name == variants[i] then selected = #choices - 1 end
    end
    if (variants[i] or "") ~= "" and selected == 0 then
      table.insert(choices, variants[i])
      table.insert(labels, variants[i] .. " (not a known variant)")
      selected = #choices - 1
    end
    local function move(to)
      layouts[i], layouts[to] = layouts[to], layouts[i]
      variants[i], variants[to] = variants[to] or "", variants[i] or ""
      writeLayouts(ctx, keyboard, layouts, variants)
      ctx.render()
    end
    table.insert(rows, kit.card({ key = "xkb-layout-" .. i .. "-" .. name }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = (data.layoutDesc[name] or name), fontSize = kit.FONT.item, fontWeight = "bold" }),
          kit.muted(i == 1 and (name .. " · first layout") or name),
        }),
        ui.select({ key = "xkb-variant-" .. i .. "-" .. name, options = labels, selectedIndex = selected, width = 260,
                    controlSize = "sm", onChange = function(value)
                      variants[i] = choices[(tonumber(value) or 0) + 1] or ""
                      writeLayouts(ctx, keyboard, layouts, variants)
                      ctx.render()
                    end }),
        kit.iconButton("arrow-up", "Move up", function() move(i - 1) end, i > 1, "xkb-up-" .. i),
        kit.iconButton("arrow-down", "Move down", function() move(i + 1) end, i < #layouts, "xkb-down-" .. i),
        kit.iconButton("x", "Remove " .. name, function()
          table.remove(layouts, i)
          table.remove(variants, i)
          writeLayouts(ctx, keyboard, layouts, variants)
          ctx.render()
        end, true, "xkb-remove-" .. i),
      }),
    }))
  end
  return rows
end

local function search(ctx, key, placeholder) return kit.filterBox(ctx, key, { placeholder = placeholder }) end
local query = kit.filterText

local function addLayoutRows(ctx, data, keyboard, layouts, variants)
  local rows = { search(ctx, "xkb-layout-q", "Search layouts to add, e.g. German or de") }
  local q = query(ctx, "xkb-layout-q")
  if q == "" then return rows end
  local chosen, shown = {}, 0
  for _, name in ipairs(layouts) do chosen[name] = true end
  for _, layout in ipairs(data.layouts) do
    if not chosen[layout.name] and kit.contains(layout.name .. " " .. layout.desc, q) then
      shown = shown + 1
      if shown > RESULTS then break end
      table.insert(rows, kit.optionRow("xkb-add-" .. layout.name, layout.desc .. " (" .. layout.name .. ")",
        ui.button({ text = "Add", glyph = "plus", controlSize = "sm", variant = "outline", onClick = function()
          table.insert(layouts, layout.name)
          table.insert(variants, "")
          writeLayouts(ctx, keyboard, layouts, variants)
          ctx.bump("xkb-layout-q")
          ctx.view["xkb-layout-q"] = nil
          ctx.render()
        end })))
    end
  end
  if shown == 0 then table.insert(rows, kit.muted("No layouts match.", { key = "xkb-add-none" })) end
  return rows
end

local function optionRows(ctx, data, keyboard, options)
  local rows = { kit.section("Options", "xkb-options") }
  local on = {}
  for _, name in ipairs(options) do on[name] = true end
  local function toggle(name, enable)
    local list = {}
    for _, current in ipairs(options) do if current ~= name then table.insert(list, current) end end
    if enable then table.insert(list, name) end
    keyboard.set("options", table.concat(list, ","))
    ctx.render()
  end
  for _, name in ipairs(options) do
    table.insert(rows, kit.optionRow("xkb-opt-on-" .. name, data.optionDesc[name] or (name .. " (not a known option)"),
      kit.iconButton("x", "Remove " .. name, function() toggle(name, false) end, true, "xkb-opt-off-" .. name)))
  end
  table.insert(rows, search(ctx, "xkb-option-q", "Search options, e.g. caps, compose or grp"))
  local q = query(ctx, "xkb-option-q")
  if q == "" then
    table.insert(rows, kit.muted("For example a key that switches layouts (grp:…) or what Caps Lock does (caps:…).",
                                 { key = "xkb-opt-hint" }))
    return rows
  end
  local shown = 0
  for _, group in ipairs(data.options) do
    for _, item in ipairs(group.items) do
      if not on[item.name] and kit.contains(item.name .. " " .. group.desc .. " " .. item.desc, q) then
        shown = shown + 1
        if shown <= RESULTS then
          table.insert(rows, kit.optionRow("xkb-opt-" .. item.name, group.desc .. ": " .. item.desc,
            ui.button({ text = "Add", glyph = "plus", controlSize = "sm", variant = "outline",
                        tooltip = item.name, onClick = function() toggle(item.name, true) end })))
        end
      end
    end
  end
  if shown == 0 then table.insert(rows, kit.muted("No options match.", { key = "xkb-opt-none" }))
  elseif shown > RESULTS then
    table.insert(rows, kit.muted(kit.plural(shown - RESULTS, "more match", "more matches") .. "; search to narrow.",
                                 { key = "xkb-opt-more" }))
  end
  return rows
end

function M.render(ctx, route)
  local view = ctx.view
  local keyboard = target(ctx, route)
  if not keyboard then
    return kit.gone(ctx, "Keyboard layouts")
  end
  local header = { kit.header(ctx, "Keyboard layouts", keyboard.title .. " · layouts, variants and XKB options") }
  if view.xkbData == nil and not view.xkbLoading then
    view.xkbLoading = true
    ctx.helper.call("xkb", {}, function(err, data)
      view.xkbLoading = false
      if err then
        view.xkbError = err.error
      else
        index(data)
        view.xkbData, view.xkbError = data, nil
      end
      ctx.render()
    end)
  end
  if view.xkbError then
    return { header = header, content = { kit.retryNotice("xkb", view.xkbError, function()
      view.xkbError = nil
      ctx.render()
    end) } }
  end
  local data = view.xkbData
  if not data then return { header = header, content = { kit.empty("Reading XKB's layout list…", "loader") } } end
  local layouts, variants = split(keyboard.get("layout")), split(keyboard.get("variant"))
  local content = {}
  if type(data.current) == "string" and data.current ~= "" then
    table.insert(content, kit.muted("Active now: " .. data.current, { key = "xkb-current" }))
  end
  for _, row in ipairs(layoutRows(ctx, data, keyboard, layouts, variants)) do table.insert(content, row) end
  for _, row in ipairs(addLayoutRows(ctx, data, keyboard, layouts, variants)) do table.insert(content, row) end
  for _, row in ipairs(optionRows(ctx, data, keyboard, split(keyboard.get("options")))) do table.insert(content, row) end
  return { header = header, content = content }
end

return M
