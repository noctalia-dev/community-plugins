-- panel.luau
-- Popup shown when clicking the bar widget: lists the most recent items, or
-- an empty state with an icon when there's nothing new.

local items = {}
local feeds = {}
local hoveredKey = nil

local showAddForm = false
local feedDraft = ""
local feedDraftKey = 0
local feedError = ""

local function tr(key)
  return noctalia.tr(key)
end

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

local function sendFeedIpc(event, url)
  local safe = tostring(url):gsub("'", "'\\''")
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all " .. event .. " '" .. safe .. "'")
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
      table.insert(rowChildren, ui.image({ path = item.image, width = 120, height = 80, radius = 10, fit = "cover" }))
    else
      table.insert(rowChildren, ui.row({ width = 120, height = 80, radius = 10, fill = "surface_variant/0.7", align = "center", justify = "center" }, {
        ui.glyph({ name = "rss", size = 26, color = "outline" }),
      }))
    end
  end

  table.insert(rowChildren, ui.column({
    gap      = 4,
    flexGrow = 1,
    onClick  = function() openLink(item.link) end,
  }, {
    ui.label({ text = item.title or tr("panel.untitled_item"), fontWeight = "bold", maxLines = 2 }),
    ui.label({ text = item.description or item.feedTitle or "", fontSize = 12, color = "outline", maxLines = 3 }),
  }))

  table.insert(rowChildren, ui.button({
    glyph       = "trash",
    variant     = "outline",
    controlSize = "sm",
    tooltip     = tr("panel.dismiss_tooltip"),
    onClick     = function() dismissItem(item) end,
  }))

  return ui.row({
    key         = key,
    gap         = 8,
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
    ui.label({ text = tr("panel.empty_state"), color = "outline" }),
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
    table.insert(headerButtons, ui.button({ glyph = "trash", variant = "outline", controlSize = "sm", tooltip = tr("panel.clear_all_tooltip"), onClick = "onClearAllClicked" }))
  end
  table.insert(headerButtons, ui.button({
    glyph       = showAddForm and "x" or "plus",
    variant     = "outline",
    controlSize = "sm",
    tooltip     = showAddForm and tr("panel.close_form_tooltip") or tr("panel.add_feed_tooltip"),
    onClick     = "onToggleAddForm",
  }))
  table.insert(headerButtons, ui.button({ glyph = "refresh", variant = "outline", controlSize = "sm", tooltip = tr("panel.refresh_tooltip"), onClick = "onRefreshClicked" }))
  table.insert(headerButtons, ui.button({ glyph = "settings", variant = "outline", controlSize = "sm", tooltip = tr("panel.settings_tooltip"), onClick = "onSettingsClicked" }))
  table.insert(headerButtons, ui.button({ glyph = "close", variant = "outline", controlSize = "sm", onClick = "onCloseClicked" }))

  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
      ui.row({ gap = 4 }, headerButtons),
    }),
    ui.separator({}),
  }

  if showAddForm then
    local feedRows = {}
    for i, url in ipairs(feeds) do
      table.insert(feedRows, ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "rss", size = 13, color = "outline" }),
        ui.label({ text = url, fontSize = 12, flexGrow = 1, maxLines = 1 }),
        ui.button({
          glyph       = "x",
          variant     = "ghost",
          controlSize = "sm",
          tooltip     = tr("panel.remove_feed_tooltip"),
          onClick     = function() removeFeed(url) end,
        }),
      }))
    end

    table.insert(children, ui.column({ gap = 6, padding = 8, radius = 8, fill = "surface_variant/0.65" }, {
      ui.label({ text = tr("panel.add_feed_title"), fontWeight = "bold" }),
      ui.input({
        key         = "feed-url-" .. feedDraftKey,
        value       = feedDraft,
        width       = "100%",
        placeholder = tr("panel.add_feed_placeholder"),
        onChange    = function(value) feedDraft = value; feedError = "" end,
        onSubmit    = "onAddFeed",
      }),
      (feedError ~= "" and ui.label({ text = feedError, color = "#e05252", fontSize = 11 }) or nil),
      ui.button({
        text         = tr("panel.add_feed_button"),
        glyph        = "plus",
        variant      = "primary",
        flexGrow     = 1,
        contentAlign = "center",
        onClick      = "onAddFeed",
      }),
      ui.separator({}),
      ui.label({ text = tr("panel.feeds_title"), fontSize = 12, color = "outline", fontWeight = "bold" }),
      (#feeds > 0 and ui.column({ gap = 4 }, feedRows) or ui.label({ text = tr("panel.feeds_empty"), fontSize = 12, color = "outline" })),
    }))
    table.insert(children, ui.separator({}))
  end

  table.insert(children, body)

  -- 720 (panel height, see plugin.toml) minus a 30px safety margin before
  -- the rounded edge, instead of touching it
  panel.render(ui.column({ gap = 10, padding = 12, height = 690 }, children))
end

noctalia.state.watch("items", function(raw)
  local ok, decoded = pcall(noctalia.json.decode, raw or "[]")
  items = (ok and decoded) or {}
  render()
end)

noctalia.state.watch("feeds", function(raw)
  local ok, decoded = pcall(noctalia.json.decode, raw or "[]")
  feeds = (ok and decoded) or {}
  render()
end)

function onToggleAddForm()
  showAddForm = not showAddForm
  if not showAddForm then
    feedDraft = ""
    feedDraftKey = feedDraftKey + 1
    feedError = ""
  end
  render()
end

function removeFeed(url)
  feedError = ""
  sendFeedIpc("remove-feed", url)
  render()
end

function onAddFeed()
  local url = noctalia.string.trim(feedDraft)
  if url == "" then
    feedError = tr("panel.feed_error_empty")
    render()
    return
  end
  if url:sub(1, 7) ~= "http://" and url:sub(1, 8) ~= "https://" then
    feedError = tr("panel.feed_error_invalid")
    render()
    return
  end
  for _, existing in ipairs(feeds) do
    if existing == url then
      feedError = tr("panel.feed_error_duplicate")
      render()
      return
    end
  end

  feedDraft = ""
  feedDraftKey = feedDraftKey + 1
  feedError = ""
  showAddForm = true -- keep the form open so more feeds can be added
  sendFeedIpc("add-feed", url)
  render()
end

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
  local feedsOk, feedsRaw = pcall(noctalia.state.get, "feeds")
  if feedsOk and feedsRaw then
    local decodeOk, decoded = pcall(noctalia.json.decode, feedsRaw)
    if decodeOk and decoded then
      feeds = decoded
    end
  end

showAddForm = false
  feedDraft = ""
  feedDraftKey = feedDraftKey + 1
  feedError = ""
  render()
  -- opening the panel counts as "read the news": resets the badge on the service
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all mark-read")
end

function onRefreshClicked()
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all refresh")
end

function onSettingsClicked()
  noctalia.runAsync("noctalia msg settings-open-plugin nilsonlinux/rss-notifier")
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
