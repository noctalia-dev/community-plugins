-- panel.luau
-- Popup shown when clicking the bar widget: lists the most recent items, or
-- an empty state with an icon when there's nothing new.

local items = {}
local hoveredKey = nil

-- declared upfront to allow cross-referencing between them
local render
local dismissItem
local itemRow
local emptyState

local function openLink(link)
  if not link or link == "" then
    return
  end
  -- escape single quotes so we don't break the shell command
  local safe = link:gsub("'", "'\\''")
  noctalia.runAsync("xdg-open '" .. safe .. "'")
end

dismissItem = function(item)
  -- remove locally (immediate feedback) and tell the service so it doesn't
  -- reappear on future updates
  for i, it in ipairs(items) do
    if it == item then
      table.remove(items, i)
      break
    end
  end
  render()

  local id = item.id or item.link or item.title
  if id then
    local safe = tostring(id):gsub("'", "'\\''")
    noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all dismiss '" .. safe .. "'")
  end
end

itemRow = function(item)
  local key = item.id or item.link or item.title
  local hovered = hoveredKey == key

  local showImages = noctalia.getConfig("show_feed_images")
  if showImages == nil then
    showImages = true -- default enabled
  end

  local rowChildren = {}

  if showImages then
    if item.image and item.image ~= "" then
      table.insert(rowChildren, ui.image({ path = item.image, width = 56, height = 56, radius = 10, fit = "cover" }))
    else
      table.insert(rowChildren, ui.row({ width = 56, height = 56, radius = 10, fill = "surface_variant/0.7", align = "center", justify = "center" }, {
        ui.glyph({ name = "rss", size = 20, color = "outline" }),
      }))
    end
  end

  table.insert(rowChildren, ui.column({
    gap      = 2,
    flexGrow = 1,
    onClick  = function() openLink(item.link) end,
  }, {
    ui.label({ text = item.title or "(sem titulo)", fontWeight = "bold", maxLines = 2 }),
    ui.label({ text = item.feedTitle or "", fontSize = 12, color = "outline" }),
  }))

  table.insert(rowChildren, ui.button({
    glyph       = "close",
    variant     = "outline",
    controlSize = "sm",
    tooltip     = "Dispensar",
    onClick     = function() dismissItem(item) end,
  }))

  return ui.row({
    key         = key,
    gap         = 6,
    padding     = 10,
    radius      = 8,
    fill        = "surface_variant/0.4",
    align       = "center",
    border      = "outline",
    borderWidth = hovered and 1 or 0,
    onHover     = function(isHovering)
      hoveredKey = isHovering and key or nil
      render()
    end,
  }, rowChildren)
end

emptyState = function()
  return ui.column({ gap = 10, align = "center", padding = 32, flexGrow = 1, justify = "center" }, {
    ui.glyph({ name = "rss", size = 32, color = "outline" }),
    ui.label({ text = "Nenhuma atualização", color = "outline" }),
  })
end

render = function()
  local body

  if #items == 0 then
    body = emptyState()
  else
    local rows = {}
    for _, item in ipairs(items) do
      table.insert(rows, itemRow(item))
    end
    -- flexGrow fills the leftover space inside the root column - only works
    -- if that column has a defined height (see below).
    body = ui.scroll({ gap = 6, flexGrow = 1 }, rows)
  end

  local headerButtons = {}
  if #items > 0 then
    table.insert(headerButtons, ui.button({ glyph = "trash", variant = "outline", controlSize = "sm", tooltip = "Limpar tudo", onClick = "onClearAllClicked" }))
  end
  table.insert(headerButtons, ui.button({ glyph = "refresh", variant = "outline", controlSize = "sm", tooltip = "Atualizar agora", onClick = "onRefreshClicked" }))
  table.insert(headerButtons, ui.button({ glyph = "close", variant = "outline", controlSize = "sm", onClick = "onCloseClicked" }))

  -- 560 (panel height, see plugin.toml) minus a 30px safety margin before
  -- the rounded edge, instead of touching it
  panel.render(ui.column({ gap = 10, padding = 12, height = 530 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "RSS/Atom Notifier", fontSize = 15, fontWeight = "bold" }),
      ui.row({ gap = 4 }, headerButtons),
    }),
    ui.separator({}),
    body,
  }))
end

noctalia.state.watch("items", function(raw)
  local ok, decoded = pcall(noctalia.json.decode, raw or "[]")
  items = (ok and decoded) or {}
  render()
end)

function onOpen(_context)
  -- the panel is only created the first time it's opened - if the service
  -- had already published items before that (e.g. on the boot-time check),
  -- watch() alone won't pick up that old value. Fetch the current state on open.
  local ok, raw = pcall(noctalia.state.get, "items")
  if ok and raw then
    local decodeOk, decoded = pcall(noctalia.json.decode, raw)
    if decodeOk and decoded then
      items = decoded
    end
  end

  render()
  -- opening the panel counts as "read the news": resets the badge on the service
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all mark-read")
end

function onRefreshClicked()
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all refresh")
end

function onClearAllClicked()
  items = {}
  render()
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all clear-all")
end

function onCloseClicked()
  panel.close()
end

function onConfigChanged()
  render() -- picks up show_feed_images (or other setting) changes immediately
end
