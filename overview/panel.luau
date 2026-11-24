--!nonstrict
-- Overview panel: every workspace as a small picture of its windows. A click on a window
-- goes to it, a click on a workspace switches to it, and a window dragged onto another
-- workspace moves there. Windows show as pictures once the service has taken them. Renders "overview.model" and sends actions on "overview.command".

local Layout = require("./lib/layout.luau")

local GAP = 4
local DRAG_TYPE = "omerfuyar/overview:window"
-- A card's title line and the gap below it.
local CARD_HEADER = 26
local CARD_GAP = 16 -- between cards in a row
local ROW_GAP = 14 -- between rows, and below a monitor's name
local SECTION_GAP = 20 -- between monitors
local NAME_HEIGHT = 20
local PADDING = 20
local TITLE_HEIGHT = 24
-- The panel's width in plugin.toml. Noctalia keeps it 8 from each screen edge, and pads its
-- content by 14 on each side.
local PANEL_WIDTH = 1120
local SCREEN_EDGE = 8
local PANEL_PADDING = 14
-- A scroll pads its content by 4 on each side and 8 above and below, and its scrollbar takes
-- 11 beside the content.
local SCROLL_PAD_H = 4
local SCROLL_PAD_V = 8
local SCROLLBAR = 11
-- Room the bar and the panel's own margins take from the screen's height.
local SCREEN_RESERVE = 120

local model = nil

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("overview.command", command)
end

local function focusWindow(window)
  send({ action = "focus", address = window.address })
  panel.close()
end

-- The window's picture when there is one; its app icon and title until then.
local function tileContent(window, width, height)
  if window.preview then
    return { ui.image({ path = window.preview, width = width - 4, height = height - 4, fit = "cover", radius = 4 }) }
  end
  local iconSize = math.max(math.min(32, width - 12, height - 12), 12)
  local children = {
    window.icon and ui.image({ path = window.icon, width = iconSize, height = iconSize })
      or ui.glyph({ name = "app-window", size = iconSize, color = "on_surface_variant" }),
  }
  if height >= 56 and width >= 72 then
    table.insert(children, ui.label({ text = window.title, maxLines = 1, fontSize = 11,
      width = width - 12, color = "on_surface_variant" }))
  end
  return { ui.column({ gap = 4, align = "center", justify = "center", flexGrow = 1 }, children) }
end

local function windowTile(window, width, height)
  return ui.dragSource({
    key = window.address,
    dragType = DRAG_TYPE,
    payload = window.address,
    grabCursor = false,
    width = width,
    height = height,
    padding = window.preview and 2 or 4,
    align = "center",
    justify = "center",
    radius = 6,
    fill = "surface_container_high",
    border = window.focused and "primary" or "outline_variant",
    borderWidth = window.focused and 2 or 1,
    tooltip = window.title,
    onClick = function() focusWindow(window) end,
  }, tileContent(window, width, height))
end

local function renderNode(node, width, height)
  if node.window then
    return windowTile(node.window, width, height)
  end
  local row = node.direction == "row"
  local sizes = Layout.sizes(row and width or height, node.shares, GAP)
  local children = {}
  for index, child in ipairs(node.children) do
    table.insert(children, row and renderNode(child, sizes[index], height) or renderNode(child, width, sizes[index]))
  end
  local container = row and ui.row or ui.column
  return container({ gap = GAP, width = width, height = height }, children)
end

local function preview(workspace, width, height)
  local tiled, floating = {}, {}
  for _, window in ipairs(workspace.windows) do
    table.insert(window.floating and floating or tiled, window)
  end
  local children = {}
  if #tiled > 0 then
    local floatHeight = #floating > 0 and 28 + GAP or 0
    table.insert(children, renderNode(Layout.tree(tiled), width, height - floatHeight))
  end
  if #floating > 0 then
    local chips = {}
    for _, window in ipairs(floating) do
      table.insert(chips, windowTile(window, 28, 28))
    end
    table.insert(children, ui.row({ gap = GAP, height = #tiled > 0 and 28 or height, align = "center",
      justify = "center" }, chips))
  end
  return children
end

-- A workspace's card, <width> wide and as tall as its monitor's shape.
local function cardHeight(monitor, width)
  return math.floor(width * monitor.height / monitor.width)
end

local function card(workspace, monitor, active, width)
  local height = cardHeight(monitor, width)
  local inner = height - 2 * 6
  local zone = ui.dropZone({
    accepts = { DRAG_TYPE },
    value = tostring(workspace.id),
    onDrop = function(address, value)
      send({ action = "move", address = address, workspace = value })
    end,
    width = width,
    height = height,
    padding = 6,
    gap = GAP,
    radius = 10,
    align = "center",
    justify = "center",
    fill = active and "primary/0.12" or "surface_container",
    border = active and "primary" or "outline_variant",
    borderWidth = active and 2 or 1,
  }, #workspace.windows > 0 and preview(workspace, width - 12, inner)
    or { ui.label({ text = noctalia.tr("workspace.empty"), color = "on_surface_variant" }) })
  local count = #workspace.windows
  return ui.column({
    key = "ws" .. workspace.id,
    gap = 6,
    width = width,
    onClick = function()
      send({ action = "switch", workspace = workspace.id })
      panel.close()
    end,
  }, {
    ui.row({ gap = 6, align = "center", height = CARD_HEADER - 6 }, {
      ui.label({ text = noctalia.tr("workspace.name", { name = workspace.name }),
        color = active and "primary" or "on_surface", fontWeight = "semibold", flexGrow = 1 }),
      ui.label({ text = noctalia.trp("workspace.windows", count), color = "on_surface_variant" }),
    }),
    zone,
  })
end

local function setting(key, low, high, default)
  return math.clamp(math.floor(tonumber(noctalia.getConfig(key)) or default), low, high)
end

-- A monitor's workspaces, <perRow> to a row of cards <width> wide. Returns the section and
-- the height of each of its parts: its name, then each row.
local function monitorSection(monitor, showName, perRow, width)
  local cards = {}
  for _, workspace in ipairs(model.workspaces) do
    if workspace.monitor == monitor.name then
      table.insert(cards, card(workspace, monitor, workspace.id == monitor.active, width))
    end
  end
  local children, heights = {}, {}
  if showName then
    table.insert(children, ui.row({ gap = 6, align = "center", height = NAME_HEIGHT }, {
      ui.glyph({ name = "device-desktop", size = 16, color = "on_surface_variant" }),
      ui.label({ text = monitor.name, color = "on_surface_variant" }),
    }))
    table.insert(heights, NAME_HEIGHT)
  end
  for start = 1, #cards, perRow do
    table.insert(children, ui.row({ gap = CARD_GAP },
      table.move(cards, start, math.min(start + perRow - 1, #cards), 1, {})))
    table.insert(heights, CARD_HEADER + cardHeight(monitor, width))
  end
  return ui.column({ key = "mon" .. monitor.name, gap = ROW_GAP }, children), heights
end

local function render()
  if model == nil then
    panel.render(ui.column({ padding = 20 }, {
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }))
    return
  end
  if not model.hyprland then
    panel.render(ui.column({ padding = 20, gap = 8 }, {
      ui.label({ text = noctalia.tr("panel.not_hyprland"), color = "on_surface_variant" }),
    }))
    return
  end
  if model.error then
    panel.render(ui.column({ padding = 20, gap = 8, width = 420 }, {
      ui.label({ text = noctalia.tr("panel.error"), fontWeight = "semibold" }),
      ui.label({ text = model.error, color = "on_surface_variant", maxLines = 6 }),
    }))
    return
  end

  -- The panel opens on the focused monitor, which may be narrower or shorter than the panel.
  local screen = model.monitors[1]
  for _, monitor in ipairs(model.monitors) do
    if monitor.focused then
      screen = monitor
    end
  end
  local panelWidth = math.min(PANEL_WIDTH, screen and screen.width - 2 * SCREEN_EDGE or PANEL_WIDTH)
  local listWidth = panelWidth - 2 * (PANEL_PADDING + PADDING + SCROLL_PAD_H) - SCROLLBAR
  -- Cards fill a row of perRow cards.
  local perRow = setting("per_row", 1, 8, 4)
  local width = math.max(math.floor((listWidth - CARD_GAP * (perRow - 1)) / perRow), 80)

  -- The list is as tall as its rows, up to max_rows rows and what fits on the screen; then it
  -- scrolls. A scroll keeps the height of its first content, so it fills a column of the
  -- list's height (DESIGN.md, section 6.3).
  local maxRows = setting("max_rows", 1, 10, 3)
  local fits = (screen and screen.height or 1080) - SCREEN_RESERVE
    - 2 * (PANEL_PADDING + PADDING) - TITLE_HEIGHT - 16
  local sections, height, cap, rows = {}, 2 * SCROLL_PAD_V, nil, 0
  for index, monitor in ipairs(model.monitors) do
    local section, heights = monitorSection(monitor, #model.monitors > 1, perRow, width)
    table.insert(sections, section)
    local named = #model.monitors > 1
    for part, partHeight in ipairs(heights) do
      height += partHeight + (part > 1 and ROW_GAP or (index > 1 and SECTION_GAP or 0))
      -- Rows of cards count toward max_rows; a monitor's name does not.
      if not (named and part == 1) then
        rows += 1
        if rows == maxRows then
          cap = height
        end
      end
    end
  end
  local listHeight = math.min(height, cap or height, fits)

  panel.render(ui.column({ gap = 16, padding = PADDING }, {
    ui.row({ gap = 8, align = "center", height = TITLE_HEIGHT }, {
      ui.glyph({ name = "layout-grid", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold", flexGrow = 1 }),
      ui.label({ text = noctalia.tr("panel.hint"), color = "on_surface_variant" }),
    }),
    ui.column({ height = listHeight }, {
      ui.scroll({ key = "list", flexGrow = 1, gap = SECTION_GAP }, sections),
    }),
  }))
end

noctalia.state.watch("overview.model", function(value)
  model = value
  render()
end)

function onOpen(_context)
  send({ action = "open" })
  model = noctalia.state.get("overview.model") or model
  render()
end

function onClose()
  send({ action = "close" })
end
