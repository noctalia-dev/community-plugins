local Feed = require("./lib/feed.luau")

local isOpen = false

local function copyLink(url)
  noctalia.copyToClipboard(url, "text/plain")
  noctalia.notify("Vidi", "link copied")
end

local function openVidi(arg)
  local bin = Feed.vidiCommand()
  if bin == nil then
    noctalia.notifyError("Vidi", "vidi binary not found on PATH or ~/.local/bin")
    return
  end
  noctalia.runInTerminal(Feed.shellQuote(bin) .. (arg and " " .. Feed.shellQuote(arg) or ""))
end

local function openVideo(video)
  local action = tostring(noctalia.getConfig("open_action") or "vidi")
  if action == "mpv" then
    if not noctalia.commandExists("mpv") then
      noctalia.notifyError("Vidi", "mpv is not installed")
      return
    end
    noctalia.runAsync({ "mpv", "--force-media-title=" .. video.title, video.url })
  elseif action == "browser" then
    if not noctalia.commandExists("xdg-open") then
      noctalia.notifyError("Vidi", "xdg-open is not available")
      return
    end
    noctalia.runAsync({ "xdg-open", video.url })
  elseif action == "copy" then
    copyLink(video.url)
  else
    openVidi(video.url)
  end
end

local function metaLine(video, now)
  local parts = {}
  if video.channel ~= "" then
    table.insert(parts, video.channel)
  end
  if video.duration ~= "" then
    table.insert(parts, video.duration)
  end
  if video.views ~= nil and video.views > 0 then
    table.insert(parts, Feed.compactCount(video.views) .. " views")
  end
  if video.timestamp ~= nil then
    table.insert(parts, Feed.relAge(now - video.timestamp))
  end
  return table.concat(parts, " · ")
end

local function videoRow(video, now, showThumbs)
  local children = {}
  if showThumbs and video.id ~= "" then
    local path = Feed.thumbPath(video.id)
    if noctalia.fileExists(path) then
      table.insert(children, ui.image({ path = path, width = 104, height = 58, radius = 6, fit = "cover" }))
    end
  end
  table.insert(children, ui.column({ flexGrow = 1, gap = 3 }, {
    ui.label({ text = Feed.shortTitle(video.title, 90), fontSize = 13, maxLines = 2 }),
    ui.label({
      text = metaLine(video, now),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    }),
  }))
  table.insert(children, ui.button({
    glyph = "copy",
    variant = "ghost",
    onClick = function()
      copyLink(video.url)
    end,
  }))
  return ui.row({
    gap = 10,
    align = "center",
    paddingV = 4,
    onClick = function()
      openVideo(video)
    end,
  }, children)
end

local function render()
  local children = {}
  local feed = Feed.load()

  local subtitle = ""
  if feed == nil then
    subtitle = "no feed cache"
  else
    local includeShorts = noctalia.getConfig("include_shorts") == true
    local newCount = Feed.unseenCount(feed, includeShorts, Feed.loadSeen())
    subtitle = tostring(newCount)
      .. " new · "
      .. tostring(#feed.videos)
      .. " videos"
      .. (feed.ageSeconds ~= nil and " · cache " .. Feed.relAge(feed.ageSeconds) .. " old" or "")
  end

  table.insert(children, ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = "brand-youtube", size = 26 }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = "Vidi", fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant" }),
    }),
    ui.button({
      glyph = "external-link",
      variant = "ghost",
      tooltip = "open vidi in a terminal",
      onClick = function()
        isOpen = false
        openVidi()
      end,
    }),
  }))
  table.insert(children, ui.separator({ spacing = 8 }))

  if feed == nil then
    table.insert(children, ui.label({
      text = "No Vidi feed cache found.\nOpen Subscriptions in vidi once to build\n~/.cache/vidi/feed_cache.json",
      fontSize = 12,
      color = "on_surface_variant",
    }))
  else
    local includeShorts = noctalia.getConfig("include_shorts") == true
    local maxItems = tonumber(noctalia.getConfig("max_items")) or 10
    local now = math.floor(noctalia.nowMs() / 1000)
    local showThumbs = noctalia.getConfig("show_thumbnails") ~= false
    local videos = Feed.filter(feed, includeShorts, maxItems)

    if #videos == 0 then
      table.insert(children, ui.label({
        text = "No videos in the feed.",
        fontSize = 12,
        color = "on_surface_variant",
      }))
    else
      local rows = {}
      for _, video in ipairs(videos) do
        table.insert(rows, videoRow(video, now, showThumbs))
      end
      table.insert(children, ui.scroll({ flexGrow = 1, gap = 2 }, rows))
    end
  end

  panel.render(ui.column({
    gap = 8,
    padding = 14,
    fill = "surface",
    radius = 16,
    border = "outline",
    borderWidth = 1,
  }, children))
end

function onOpen()
  isOpen = true
  render()
  local feed = Feed.load()
  if feed ~= nil then
    local includeShorts = noctalia.getConfig("include_shorts") == true
    Feed.markSeen(Feed.newestTimestamp(feed, includeShorts, Feed.loadSeen()))
  end
end

function onClose()
  isOpen = false
end

Feed.load()
