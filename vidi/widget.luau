local Feed = require("./lib/feed.luau")

local PANEL_ID = "fel/vidi:feed"
local lastSeen = Feed.loadSeen()

local function freshVideos(feed, includeShorts, limit)
  local out = {}
  for _, video in ipairs(feed.videos) do
    if (not video.isShort or includeShorts) and video.timestamp ~= nil and video.timestamp > lastSeen then
      table.insert(out, video)
      if #out >= limit then
        break
      end
    end
  end
  return out
end

local function render()
  local feed = Feed.load()
  if feed == nil then
    barWidget.setGlyph("rss")
    barWidget.setText("")
    barWidget.setTooltip({
      { "Vidi", "no feed cache yet" },
      { "", "open Subscriptions in vidi once to build it" },
    })
    return
  end

  local includeShorts = noctalia.getConfig("include_shorts") == true
  local newCount = Feed.unseenCount(feed, includeShorts, lastSeen)

  barWidget.setGlyph("brand-youtube")
  barWidget.setText(newCount > 0 and tostring(newCount) or "")

  local rows = {}
  for _, video in ipairs(freshVideos(feed, includeShorts, 3)) do
    table.insert(rows, {
      Feed.shortTitle(video.title, 46),
      (video.channel ~= "" and video.channel .. " · " or "")
        .. Feed.relAge(feed.ageSeconds ~= nil and (math.floor(noctalia.nowMs() / 1000) - video.timestamp) or nil),
    })
  end
  table.insert(rows, { "Feed", feed.ageSeconds ~= nil and Feed.relAge(feed.ageSeconds) .. " old" or "unknown age" })
  table.insert(rows, { "Total", tostring(#feed.videos) })
  barWidget.setTooltip(rows)
end

noctalia.state.watch("seen_ts", function(value)
  if value ~= nil then
    lastSeen = value
    render()
  end
end)

noctalia.setUpdateInterval(30000)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  local bin = Feed.vidiCommand()
  if bin == nil then
    noctalia.notifyError("Vidi", "vidi binary not found on PATH or ~/.local/bin")
    return
  end
  noctalia.runInTerminal(Feed.shellQuote(bin))
end

function onMiddleClick()
  local feed = Feed.load()
  if feed == nil then
    return
  end
  local includeShorts = noctalia.getConfig("include_shorts") == true
  lastSeen = Feed.newestTimestamp(feed, includeShorts, lastSeen)
  Feed.markSeen(lastSeen)
  render()
end

render()

