--!nonstrict
-- The Outputs page: the connected displays as numbered tiles drawn to scale. Dragging one onto an edge of
-- another places it there (lib/arrange.luau keeps displays centered on each other); a click opens its entry.
-- The star on a tile marks the default display: Umbriel focuses it at startup and XWayland makes it primary.
local kit = require("../ui/kit.luau")
local arrange = require("../lib/arrange.luau")
local displays = require("../lib/displays.luau")
local trymode = require("./trymode.luau")

local M = {}

-- The drawing fills the page: in the app the canvas card reports its size (onResize); Noctalia panels have a
-- fixed size (plugin.toml: 980×760), which leaves about this much inside the card.
local PANEL_AREA = { w = 880, h = 490 }
local CANVAS_PAD = 16
local EXTRA_ROW, EXTRA_MAX = 56, 168  -- rows for disabled and unplugged outputs scroll below the drawing
local GAP = 2  -- drawn between neighbouring tiles
local PRIMARY_FIELD = "general.xwayland_primary_output"

local round = displays.round

-- The connected displays matched to the config's output entries (empty while Umbriel hasn't answered).
local function connected(ctx)
  return displays.list(ctx.connectedOutputs().outputs, ctx.store.entryItems("output"))
end

-- "Display 2" for an output entry named `name` while that output is connected, else nil.
function M.label(ctx, name)
  local display = displays.forEntry(connected(ctx), name)
  return display and ("Display " .. display.number) or nil
end

local function arranged(list)
  local shown = {}
  for _, display in ipairs(list) do
    if displays.enabled(display) then table.insert(shown, display) end
  end
  return shown
end

-- The entry index of `display`, adding an entry (named after the monitor) to `ops` when it has none.
local function entryIndex(ctx, display, ops)
  if display.index then return display.index end
  table.insert(ops, { op = "add", name = display.entryName })
  local adds = 0
  for _, op in ipairs(ops) do if op.op == "add" then adds = adds + 1 end end
  return #ctx.store.entryItems("output") + adds
end

-- Writes `positions` as one undo step: every arranged display gets its position, and an entry when it has
-- none.
local function apply(ctx, list, positions)
  local ops = {}
  for _, display in ipairs(list) do
    local pos = positions[display.id]
    if pos then
      local old = display.index and display.values.position or nil
      local index = entryIndex(ctx, display, ops)
      if type(old) ~= "table" or old.x ~= pos.x or old.y ~= pos.y then
        table.insert(ops, { op = "set", index = index - 1, field = "position", value = { x = pos.x, y = pos.y } })
      end
    end
  end
  ctx.store.entryOpsBatch("output", ops)
end

local function place(ctx, id, target, side)
  local list = connected(ctx)
  local rects = displays.rects(list)
  local known = {}
  for _, rect in ipairs(rects) do known[rect.id] = true end
  if not (known[id] and known[target]) or id == target then return end
  local positions = arrange.move(rects, id, target, side)
  if positions then apply(ctx, list, positions) end
  ctx.render()
end

-- Opens the display's entry; one added for it goes again if the page is left without an edit.
local function open(ctx, display)
  local ops = {}
  local index = entryIndex(ctx, display, ops)
  ctx.store.entryOpsBatch("output", ops)
  ctx.go({ name = "entry", editor = "output", index = index })
  if #ops > 0 then ctx.markProvisional() end
end

-- The default display: the one whose entry focuses it at startup, else XWayland's primary output (nil: none).
local function defaultDisplay(ctx, list)
  for _, display in ipairs(list) do
    if display.values.focus_at_startup == true then return display end
  end
  local primary = ctx.store.value(PRIMARY_FIELD)
  if type(primary) == "string" and primary ~= "" then return displays.forEntry(list, primary) end
  return nil
end

-- Makes `display` (nil: none) the default, as one undo step: only its entry focuses at startup, and it is
-- XWayland's primary.
local function setDefault(ctx, display)
  local store = ctx.store
  store.group(function()
    local ops, chosen = {}, nil
    if display then chosen = entryIndex(ctx, display, ops) end
    for index, item in ipairs(store.entryItems("output")) do
      if index ~= chosen and item.values.focus_at_startup == true then
        table.insert(ops, { op = "unset", index = index - 1, field = "focus_at_startup" })
      end
    end
    if chosen and (not display.index or display.values.focus_at_startup ~= true) then
      table.insert(ops, { op = "set", index = chosen - 1, field = "focus_at_startup", value = true })
    end
    store.entryOpsBatch("output", ops)
    local name = chosen and store.entryItems("output")[chosen].name or nil
    local primary = store.value(PRIMARY_FIELD)
    if name and primary ~= name then
      store.setField(PRIMARY_FIELD, name)
    elseif not name and primary ~= nil and primary ~= "" then
      store.unsetField(PRIMARY_FIELD)
    end
  end)
  ctx.render()
end

local TRY_CARD = 60  -- height of the Try confirm card and its gap, taken from the drawing in the panel
local MAX_ACCEPTS = 16  -- Noctalia's limit of drag types per drop zone

-- Each display drags as its own type, and a tile's zones accept only the others: Noctalia keeps the dragged
-- tile in place (dimmed) and never skips its zones, so the one under the pointer would win otherwise. With
-- more displays than a zone can name, they share one type. Returns {id → drag type}, {id → accepted types}.
local function dragTypes(shown)
  local shared = #shown > MAX_ACCEPTS + 1
  local types, accepts = {}, {}
  for _, display in ipairs(shown) do types[display.id] = shared and "display" or ("display:" .. display.id) end
  for _, display in ipairs(shown) do
    local list = {}
    for _, other in ipairs(shown) do
      if other ~= display then table.insert(list, types[other.id]) end
    end
    accepts[display.id] = shared and { "display" } or list
  end
  return types, accepts
end

-- An edge or corner zone of a tile. Zones with a hitSlop are found by position (closest first): Noctalia's
-- hit test stops at the input area of a drag source, which a tile's middle is.
local function zone(id, side, accepts, props, children)
  props.key = "display-" .. side .. "-" .. id
  props.hitSlop = 1
  props.accepts = accepts
  props.value = side .. "|" .. id
  props.onDrop = "onDrop"
  return ui.dropZone(props, children)
end

-- One display, `w`×`h` on the canvas. Noctalia's drag source covers its subtree with its own input area, so
-- only the middle (the number and a grip) is the drag source and the click that opens the display; around it
-- are the drop zones: the four edges (dropping another display there places it on that side, centered) and the
-- four corners (above or below, hanging off that half: its edge on this display's center line). The top zone
-- holds the star (filled for the default display; a click sets or clears it) and the resolution, the bottom
-- one the name.
local function tile(ctx, display, w, h, isDefault, onStar, dragType, accepts)
  local iw, ih = math.max(w - 2 * GAP, 8), math.max(h - 2 * GAP, 8)
  local edgeH, edgeW = math.max(math.floor(ih * 0.3), 4), math.max(math.floor(iw * 0.22), 4)
  local roomy = iw >= 80 and edgeH >= 18
  local captionSize = edgeH >= 60 and 15 or edgeH >= 30 and 13 or 11
  local rw, rh = displays.resolution(display)
  local name = displays.name(display)
  local top = {}
  if edgeH >= 16 then
    table.insert(top, ui.row({ key = "display-star-" .. display.id, padding = 2, radius = kit.RADIUS.sm, onClick = onStar,
      tooltip = isDefault and "Default display: click to clear" or "Make " .. name .. " the default display" }, {
      ui.glyph({ name = isDefault and "star-filled" or "star", size = captionSize + 3,
                 color = isDefault and "primary" or kit.MUTED }),
    }))
  end
  if roomy and rw then table.insert(top, kit.muted(rw .. "×" .. rh, { fontSize = captionSize, maxLines = 1 })) end
  local bottom = {}
  if roomy then
    table.insert(bottom, ui.label({ text = name, fontSize = captionSize, maxLines = 1,
                                    color = display.label and "on_surface" or kit.MUTED }))
  end
  -- the middle holds the number and, when there is room, a grip under it (so it reads as something to drag)
  local middle = ih - 2 * edgeH
  local grip = middle >= 44 and math.min(24, math.floor(middle / 3)) or 0
  local numberSize = math.max(12, math.min(64, middle - grip - 8))
  local center = { ui.label({ text = tostring(display.number), fontWeight = "bold", fontSize = numberSize }) }
  if grip > 0 then table.insert(center, ui.glyph({ name = "grip-horizontal", size = grip, color = kit.MUTED })) end
  local function strip(side, props, children)
    return ui.row({ height = edgeH, gap = 0 }, {
      zone(display.id, side .. "-start", accepts, { width = edgeW }),
      zone(display.id, side, accepts, props, children),
      zone(display.id, side .. "-end", accepts, { width = edgeW }),
    })
  end
  return ui.column({ key = "display-tile-" .. display.id, width = w, height = h, padding = GAP }, {
    -- a see-through face: Noctalia draws the floating copy of a dragged tile at a fixed 96 % opacity
    ui.column({ key = "display-face-" .. display.id, flexGrow = 1, gap = 0, radius = kit.RADIUS.md,
                fill = "surface_container_highest/0.55", border = isDefault and "primary" or "outline_variant",
                borderWidth = isDefault and 2 or 1 }, {
      strip("above", { flexGrow = 1, align = "center", justify = "end", paddingV = 4 },
            { ui.row({ gap = 6, align = "center" }, top) }),
      ui.row({ flexGrow = 1, gap = 0 }, {
        zone(display.id, "left", accepts, { width = edgeW }),
        ui.dragSource({
          key = "display-" .. display.id, dragType = dragType, payload = display.id,
          previewAncestor = 2, flexGrow = 1, align = "center", justify = "center",
          tooltip = "Display " .. display.number .. " · " .. name
            .. (name ~= display.id and (" (" .. display.id .. ")") or "") .. (isDefault and " · default" or "")
            .. ": click to edit; drag onto an edge or corner of another display to move it there",
          onClick = function() open(ctx, display) end,
        }, { ui.column({ gap = 0, align = "center" }, center) }),
        zone(display.id, "right", accepts, { width = edgeW }),
      }),
      strip("below", { flexGrow = 1, align = "center", justify = "start", paddingH = 6, paddingV = 4 }, bottom),
    }),
  })
end

local function spacer(w, h) return ui.box({ width = w, height = h }) end

-- A band from arrange.bands, drawn as nested rows/columns with spacer boxes for the gaps.
local function drawBand(band, draw)
  if band.rect then return draw(band.rect) end
  local row = band.dir == "row"
  local children, cursor = {}, row and band.x or band.y
  for _, part in ipairs(band.parts) do
    local lead = (row and part.x or part.y) - cursor
    if lead > 0 then table.insert(children, row and spacer(lead, 1) or spacer(1, lead)) end
    local cross = row and (part.y - band.y) or (part.x - band.x)
    local inner = drawBand(part, draw)
    if cross > 0 then
      inner = row and ui.column({ gap = 0, align = "start" }, { spacer(1, cross), inner })
        or ui.row({ gap = 0, align = "start" }, { spacer(cross, 1), inner })
    end
    table.insert(children, inner)
    cursor = row and (part.x + part.w) or (part.y + part.h)
  end
  if row then return ui.row({ gap = 0, align = "start" }, children) end
  return ui.column({ gap = 0, align = "start" }, children)
end

-- Canvas rectangles: scaled to fit, edges rounded once so neighbours stay flush.
local function scaled(rects, area)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for _, r in ipairs(rects) do
    minX, minY = math.min(minX, r.x), math.min(minY, r.y)
    maxX, maxY = math.max(maxX, r.x + r.w), math.max(maxY, r.y + r.h)
  end
  local f = math.min(area.w / math.max(maxX - minX, 1), area.h / math.max(maxY - minY, 1))
  local out = {}
  for _, r in ipairs(rects) do
    local x1, y1 = round((r.x - minX) * f), round((r.y - minY) * f)
    local x2, y2 = round((r.x + r.w - minX) * f), round((r.y + r.h - minY) * f)
    table.insert(out, { id = r.id, x = x1, y = y1, w = math.max(x2 - x1, 1), h = math.max(y2 - y1, 1) })
  end
  return out
end

local function canvas(ctx, shown, rects, default, area)
  local byId = {}
  for _, display in ipairs(shown) do byId[display.id] = display end
  local types, accepts = dragTypes(shown)
  local function draw(r, w, h)
    local display = byId[r.id]
    local isDefault = display == default
    return tile(ctx, display, w or r.w, h or r.h, isDefault, function()
      setDefault(ctx, (not isDefault) and display or nil)
    end, types[display.id], accepts[display.id])
  end
  local small = scaled(rects, area)
  local band = arrange.bands(small)
  local drawn
  if band then
    drawn = { drawBand(band, draw) }
  else
    -- overlapping or interlocked displays can't be cut into rows and columns: show them side by side
    local tiles = {}
    for _, r in ipairs(small) do table.insert(tiles, draw(r, math.floor(r.w / 2), math.floor(r.h / 2))) end
    drawn = { ui.row({ key = "display-row", gap = 8, align = "center" }, tiles),
              kit.muted("Can't draw this arrangement to scale; Tidy up lines the displays up again.") }
  end
  local props = { key = "display-canvas", align = "center", justify = "center", padding = CANVAS_PAD, flexGrow = 1 }
  if ctx.isApp then
    props.onResize = function(w, h)
      w, h = tonumber(w) or 0, tonumber(h) or 0
      if w <= 0 or h <= 0 then return end  -- the card left the page
      local inner = { w = math.max(w - 2 * CANVAS_PAD - 2, 120), h = math.max(h - 2 * CANVAS_PAD - 2, 80) }
      local known = ctx.view.displayArea
      if not known or known.w ~= inner.w or known.h ~= inner.h then
        ctx.view.displayArea = inner
        ctx.render()
      end
    end
  end
  return kit.card(props, drawn)
end

-- Connected displays that are turned off: not drawn, still editable.
local function offRows(ctx, list)
  local rows = {}
  for _, display in ipairs(list) do
    if not displays.enabled(display) then
      table.insert(rows, kit.navRow({ key = "display-off-" .. display.id, glyph = "device-desktop-off",
        title = "Display " .. display.number .. " · " .. displays.name(display), subtitle = "Off",
        onClick = function() open(ctx, display) end }))
    end
  end
  return rows
end

-- Output entries for outputs that aren't connected (all of them while Umbriel can't be asked): still editable.
local function others(ctx, list)
  local rows = {}
  for index, item in ipairs(ctx.store.entryItems("output")) do
    if not displays.forEntry(list, item.name) then
      local count = 0
      for _ in pairs(item.values) do count = count + 1 end
      local label = type(item.label) == "string" and item.label ~= "" and item.label or nil
      table.insert(rows, kit.navRow({ key = "entry-output-" .. index, glyph = "device-desktop-off",
        title = label or tostring(item.name), subtitle = (label and (tostring(item.name) .. " · ") or "")
          .. kit.plural(count, "setting"),
        onClick = function() ctx.go({ name = "entry", editor = "output", index = index }) end }))
    end
  end
  if #rows > 0 then table.insert(rows, 1, kit.section("Not connected")) end
  return rows
end

-- The page content and whether it fills the page (the arrangement does; loading and error states scroll).
function M.content(ctx)
  local live = ctx.connectedOutputs()
  if not live.error then ctx.watchLive({ "outputs" }, function() ctx.refreshLiveOutputs(); ctx.render() end) end
  local list = connected(ctx)
  local shown = arranged(list)
  if live.loading or live.error or #shown == 0 then
    local rows = {}
    if live.loading then
      table.insert(rows, kit.empty("Asking Umbriel for outputs…", "loader"))
    elseif live.error then
      local notice, retry = kit.retryNotice("outputs", live.error, function()
        ctx.forgetLiveOutputs()
        ctx.render()
      end)
      table.insert(rows, notice)
      table.insert(rows, retry)
    elseif #list == 0 then
      table.insert(rows, kit.empty("Umbriel reported no outputs.", "device-desktop-off"))
    else
      table.insert(rows, kit.empty("Every connected display is turned off.", "device-desktop-off"))
    end
    for _, row in ipairs(offRows(ctx, list)) do table.insert(rows, row) end
    for _, row in ipairs(others(ctx, list)) do table.insert(rows, row) end
    return rows, false
  end
  local rects = displays.rects(list)
  local default = defaultDisplay(ctx, list)
  local untidy = false
  local tidy = arrange.tidy(rects)
  for _, rect in ipairs(rects) do
    local pos = tidy[rect.id]
    if pos.x ~= rect.x or pos.y ~= rect.y then untidy = true end
  end
  local extra = offRows(ctx, list)
  for _, row in ipairs(others(ctx, list)) do table.insert(extra, row) end
  local extraHeight = #extra > 0 and math.min(#extra * EXTRA_ROW, EXTRA_MAX) or 0
  local area
  if ctx.isApp then
    area = ctx.view.displayArea or { w = 720, h = 300 }  -- until the card reports its size
  else
    -- the panel's fixed height, less the scrolling rows under the drawing
    area = { w = PANEL_AREA.w, h = PANEL_AREA.h - (extraHeight > 0 and extraHeight + 8 or 0) }
  end
  local tryCard = trymode.card(ctx)
  if tryCard and not ctx.isApp then area.h = area.h - TRY_CARD end
  local rows = {
    ui.row({ key = "display-tools", gap = 8, align = "center" }, {
      kit.muted("Drag a display by its number onto an edge or corner of another to place it there; click it to edit it.",
                { fontSize = kit.FONT.body, flexGrow = 1, maxLines = 2 }),
      trymode.button(ctx),
      ui.button({ key = "display-tidy", text = "Tidy up", glyph = "layout-align-center", variant = "outline",
                  enabled = untidy, tooltip = "Center the displays on each other again, starting at 0, 0",
                  onClick = function()
                    apply(ctx, list, tidy)
                    ctx.render()
                  end }),
      ui.button({ key = "display-refresh", glyph = "refresh", variant = "ghost",
                  tooltip = "Ask Umbriel again (after plugging a monitor in or out)",
                  onClick = function()
                    ctx.forgetLiveOutputs()
                    ctx.render()
                  end }),
    }),
    canvas(ctx, shown, rects, default, area),
  }
  if tryCard then table.insert(rows, 2, tryCard) end
  ctx.dropHandler = function(payload, value)
    local side, target = string.match(value, "^([%a%-]+)|(.+)$")
    if target and payload ~= target then place(ctx, payload, target, side) end
  end
  if #extra > 0 then
    table.insert(rows, ui.scroll({ key = "display-extra", gap = 6, height = extraHeight }, extra))
  end
  return rows, true
end

return M
