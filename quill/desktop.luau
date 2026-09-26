--!nonstrict
local Text = require("./lib/text.luau")

local PANEL_ID = "fel/quill:panel"

local snapshot = noctalia.state.get("snapshot")

local function plural(n, word)
  return tostring(n) .. " " .. word .. (n == 1 and "" or "s")
end

local function openTodo(todo)
  noctalia.state.set("pending_action", { kind = "open_note", path = todo.path })
  noctalia.togglePanel(PANEL_ID)
end

local function render()
  local children = {}
  local counts = snapshot ~= nil and snapshot.counts or nil

  children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "notes", size = 20 }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = "Quill", fontSize = 14, fontWeight = "bold" }),
      ui.label({
        text = counts ~= nil and (plural(counts.open, "open") .. " · " .. plural(counts.notes, "note")) or "indexing…",
        fontSize = 10,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.button({
      glyph = "external-link",
      variant = "ghost",
      tooltip = "Open the panel",
      onClick = function()
        noctalia.togglePanel(PANEL_ID)
      end,
    }),
  })
  children[#children + 1] = ui.separator({ spacing = 4 })

  local limit = tonumber(noctalia.getConfig("desktop_items")) or 6
  local shown = 0
  for _, todo in ipairs(snapshot ~= nil and snapshot.todos or {}) do
    if not todo.done then
      local overdue = Text.isOverdue(todo.due, todo.time)
      children[#children + 1] = ui.row({
        key = todo.id,
        gap = 6,
        align = "center",
        paddingV = 1,
        onClick = function()
          openTodo(todo)
        end,
      }, {
        ui.glyph({ name = "square", size = 12, color = overdue and "error" or "on_surface_variant" }),
        ui.label({ text = todo.text, fontSize = 11, maxLines = 1, flexGrow = 1 }),
        ui.label({
          text = Text.fmtDue(todo.due, todo.time) or "",
          fontSize = 9,
          color = overdue and "error" or "on_surface_variant",
        }),
      })
      shown = shown + 1
      if shown >= limit then
        break
      end
    end
  end

  if shown == 0 then
    children[#children + 1] = ui.label({ text = "Nothing to do.", fontSize = 11, color = "on_surface_variant" })
  end

  desktopWidget.render(ui.column({
    gap = 6,
    padding = 12,
    fill = "surface",
    radius = 14,
    border = "outline",
    borderWidth = 1,
  }, children))
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  render()
end)

noctalia.setUpdateInterval(15000)

function update()
  render()
end

render()