--!nonstrict
-- Key/value maps: environment variables and named animation curves.
local kit = require("../ui/kit.luau")

local M = {}

local EXAMPLES = {
  environment = { "Variable name, e.g. QT_QPA_PLATFORM", "Value, e.g. wayland" },
  beziers = { "Curve name, e.g. soft", "[x1, y1, x2, y2], e.g. [0.05, 0.9, 0.1, 1.0]" },
  springs = { "Spring name, e.g. bouncy", "{ damping = 1.0, stiffness = 900 }" },
}
local RESERVED = {
  WAYLAND_DISPLAY = true, WAYLAND_SOCKET = true, DISPLAY = true, UMBRIEL_SOCKET = true, LIBEI_SOCKET = true,
  XDG_CURRENT_DESKTOP = true, XDG_SESSION_DESKTOP = true, XDG_SESSION_TYPE = true,
}

local function check(store, eid, name, from)
  if name == "" then return "Enter a name." end
  if eid == "environment" then
    if not string.match(name, "^[%a_][%w_]*$") then return "“" .. name .. "” is not a valid variable name." end
    if RESERVED[name] then return name .. " is managed by Umbriel and cannot be set here." end
  end
  if name ~= from then
    for _, row in ipairs(store.mapRows(eid)) do
      if row[1] == name then return "“" .. name .. "” already exists." end
    end
  end
  return nil
end

local function editor(ctx, eid)
  local store, view = ctx.store, ctx.view
  local spec = store.meta.maps[eid]
  local rows = { kit.section(spec.title) }
  local editing = view.mapEdit
  for index, row in ipairs(store.mapRows(eid)) do
    local key = "map-" .. eid .. "-" .. row[1]
    if editing and editing.editor == eid and editing.from == row[1] then
      local gen = ctx.gen(key)
      table.insert(rows, kit.card({ key = key, fill = "surface_container_high" }, {
        ui.input({ key = key .. ":n:" .. gen, value = row[1], controlSize = "sm", placeholder = EXAMPLES[eid][1],
                   onChange = function(text) editing.name = text end }),
        ui.input({ key = key .. ":v:" .. gen, value = row[2], controlSize = "sm", placeholder = EXAMPLES[eid][2],
                   focus = true, onChange = function(text) editing.value = text end,
                   onSubmit = function(text) editing.value = text; editing.apply() end }),
        ui.row({ gap = 6 }, {
          ui.button({ text = "Apply", glyph = "check", variant = "primary", controlSize = "sm",
                      onClick = function() editing.apply() end }),
          ui.button({ text = "Cancel", variant = "ghost", controlSize = "sm",
                      onClick = function() view.mapEdit = nil; ctx.render() end }),
        }),
      }))
      editing.apply = function()
        local name = noctalia.string.trim(editing.name or row[1])
        local problem = check(store, eid, name, row[1])
        if problem then ctx.flash(problem, "warning"); return end
        store.mapSet(eid, name, editing.value or row[2], name ~= row[1] and row[1] or nil)
        view.mapEdit = nil
        ctx.render()
      end
    else
      table.insert(rows, ui.row({ key = key, gap = 8, align = "center", paddingH = 12, paddingV = 8, radius = kit.RADIUS.md,
                                  fill = "surface_container" }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = row[1], fontSize = kit.FONT.body, fontWeight = "bold" }),
          kit.muted(row[2], { maxLines = 2 }),
        }),
        kit.iconButton("pencil", "Edit", function() view.mapEdit = { editor = eid, from = row[1] }; ctx.render() end),
        kit.iconButton("trash", "Remove", function() store.mapRemove(eid, row[1]); ctx.render() end),
      }))
    end
  end
  if #store.mapRows(eid) == 0 then table.insert(rows, kit.muted("Nothing defined yet.")) end
  local addKey = "add-" .. eid
  local draft = view[addKey] or {}
  view[addKey] = draft
  local gen = ctx.gen(addKey)
  local function add()
    local name = noctalia.string.trim(draft.name or "")
    local problem = check(store, eid, name, nil)
    if problem then ctx.flash(problem, "warning"); return end
    if noctalia.string.trim(draft.value or "") == "" and eid ~= "environment" then
      ctx.flash("Enter a value.", "warning")
      return
    end
    store.mapSet(eid, name, draft.value or "", nil)
    view[addKey] = {}
    ctx.bump(addKey)
    ctx.render()
  end
  table.insert(rows, ui.row({ key = addKey, gap = 6, align = "center" }, {
    ui.input({ key = addKey .. ":n:" .. gen, value = "", width = 220, controlSize = "sm", placeholder = EXAMPLES[eid][1],
               onChange = function(text) draft.name = text end }),
    ui.input({ key = addKey .. ":v:" .. gen, value = "", flexGrow = 1, controlSize = "sm", placeholder = EXAMPLES[eid][2],
               onChange = function(text) draft.value = text end,
               onSubmit = function(text) draft.value = text; add() end }),
    ui.button({ text = "Add", glyph = "plus", variant = "outline", controlSize = "sm", onClick = add }),
  }))
  return rows
end

function M.render(ctx, route)
  local store = ctx.store
  local page = store.meta.pages[route.page]
  local header = { kit.header(ctx, route.page, page.help) }
  if not store.state then return { header = header, content = { kit.loading("Loading config…") } } end
  local content = {}
  if route.page == "Animation curves" then
    table.insert(content, kit.muted("Name a curve here, then pick it in an animation's Curve setting. "
      .. "Bézier x values (first and third numbers) must be between 0 and 1.", { maxLines = 3 }))
  end
  for _, eid in ipairs(page.maps) do
    for _, row in ipairs(editor(ctx, eid)) do table.insert(content, row) end
  end
  return { header = header, content = content }
end

return M
