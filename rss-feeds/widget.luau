local MAX_FEEDS = 5
local LAYOUT_WIDTH = 360
local RETRY_MIN_MS = 15000
local RETRY_MAX_MS = 300000
local HANG_GUARD_MS = 60000      -- if a request never answers

noctalia.setUpdateInterval(15000) -- for retry timing only

local feeds = nil
local nextCycleAt = 0
local hoveredKey = nil

local function cfgInt(key, default, lo, hi)
  local v = tonumber(noctalia.getConfig(key)) or default
  return math.max(lo, math.min(hi, math.floor(v)))
end

local function cfgStr(key)
  return noctalia.string.trim(noctalia.getConfig(key) or "")
end

-- ---------- Text / XML helpers ----------

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", amp = "&" }

local function codepoint(cp)
  local ok, ch = pcall(utf8.char, cp)
  return ok and ch or ""
end

local function decodeText(s)
  if not s then return "" end
  if s:find("[<&]") then                      -- fast path for plain text
    s = s:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    s = s:gsub("<[^>]*>", "")
    if s:find("&#", 1, true) then
      s = s:gsub("&#[xX](%x+);", function(h) return codepoint(tonumber(h, 16)) end)
      s = s:gsub("&#(%d+);", function(d) return codepoint(tonumber(d)) end)
    end
    s = s:gsub("&(%a+);", ENTITIES)
  end
  s = s:gsub("%s+", " ")
  return (s:match("^ ?(.-) ?$"))
end

local function parseFeed(body, limit, out)
  local tag = "item"
  if not body:find("<item[%s>]") and body:find("<entry[%s>]") then tag = "entry" end -- Atom

  local openPat = "<" .. tag .. "[%s>]"
  local closeStr = "</" .. tag .. ">"

  local firstEntry = body:find(openPat)
  local head = firstEntry and body:sub(1, firstEntry - 1) or body
  local title = decodeText(head:match("<title[^>]*>(.-)</title>"))

  local items = out.items
  local pos = 1
  while #items < limit do
    local s = body:find(openPat, pos)
    if not s then break end
    local _, e = body:find(closeStr, s, true)
    if not e then break end
    local chunk = body:sub(s, e)
    pos = e + 1

    local t = decodeText(chunk:match("<title[^>]*>(.-)</title>"))

    local link = chunk:match("<link>(.-)</link>")            -- RSS
    if not link then                                          -- Atom
      local lp = 1
      while true do
        local ls, le, attrs = chunk:find("<link%s([^>]*)>", lp)
        if not ls then break end
        lp = le + 1
        local rel  = attrs:match("rel=[\"']([^\"']*)[\"']")
        local href = attrs:match("href=[\"']([^\"']*)[\"']")
        if href and (not rel or rel == "alternate") then
          link = href
          break
        end
      end
    end
    if not link then link = chunk:match("<guid[^>]*>(.-)</guid>") end
    link = decodeText(link)

    if t ~= "" and link:find("^https?://") then
      items[#items + 1] = { title = t, link = link }
    end
  end
  return title
end

local function openLink(url)
  noctalia.runAsync({ "xdg-open", url })
end

-- ---------- Feed state ----------

local function buildFeeds()
  feeds = {}
  for i = 1, MAX_FEEDS do
    local url = cfgStr("feed_" .. i)
    if url ~= "" then
      table.insert(feeds, {
        url = url,
        custom = cfgStr("title_" .. i),   -- user-chosen title
        title = url,                      -- title from the feed itself
        items = {},
        status = "loading",
        err = nil,
        retryMs = 0,                      -- current backoff; 0 = healthy
        retryAt = nil,
        token = 0,
      })
    end
  end
end

local function displayTitle(feed)
  if feed.custom ~= "" then return feed.custom end
  return feed.title
end

-- ---------- Rendering ----------

local function render()
  local width = LAYOUT_WIDTH
  local textWidth = width - 12              -- minus built-in row padding
  local sections = {}

  if feeds == nil or #feeds == 0 then
    table.insert(sections, ui.label({ text = "No feeds configured", fontWeight = "bold" }))
    table.insert(sections, ui.button({
      text = "Open settings", variant = "primary", controlSize = "sm",
      onClick = function() noctalia.openSettings() end,
    }))
  end

  for fi, feed in ipairs(feeds or {}) do
    local rows = {
      ui.row({ key = "hr" .. fi, paddingH = 6, paddingV = 4 }, {
        ui.label({
          text = displayTitle(feed), fontSize = 15, fontWeight = "bold",
          color = "primary", maxWidth = textWidth, maxLines = 1,
        }),
      }),
    }

    if feed.status == "error" and #feed.items == 0 then
      table.insert(rows, ui.row({ key = "er" .. fi, paddingH = 6 }, {
        ui.label({
          text = "Couldn't load feed (" .. (feed.err or "error") .. ") — retrying",
          color = "error", fontSize = 12, maxWidth = textWidth, maxLines = 5,
        }),
      }))
    elseif feed.status == "loading" and #feed.items == 0 then
      table.insert(rows, ui.row({ key = "lr" .. fi, paddingH = 6 }, {
        ui.label({ text = "Loading…", color = "on_surface_variant", fontSize = 12 }),
      }))
    end

    for ii, item in ipairs(feed.items) do
      local key = "i" .. fi .. "-" .. ii
      local hovered = (hoveredKey == key)

      if ii > 1 then
        table.insert(rows, ui.separator({
          key = "sep" .. key, thickness = 1, spacing = 0, color = "on_surface/0.12",
        }))
      end

      table.insert(rows, ui.row({
        key = key, paddingH = 6, paddingV = 5, radius = 6,
        fill = hovered and "primary/0.18" or "#00000000",
        onClick = function() openLink(item.link) end,
        onHover = function(state)
          local newKey = hoveredKey
          if state == "true" then
            newKey = key
          elseif hoveredKey == key then
            newKey = nil
          end
          if newKey ~= hoveredKey then
            hoveredKey = newKey
            render()
          end
        end,
      }, {
        ui.label({
          text = item.title, fontSize = 13, maxWidth = textWidth, maxLines = 2,
          color = hovered and "primary" or "on_surface",
        }),
      }))
    end

    table.insert(sections, ui.column({ key = "f" .. fi, gap = 0 }, rows))
    if fi < #feeds then
      table.insert(sections, ui.separator({ key = "fs" .. fi, spacing = 4, color = "on_surface/0.2" }))
    end
  end

  desktopWidget.render(ui.column({ gap = 10, width = width }, sections))
end

-- ---------- Feed fetching ----------

local function fetchFeed(feed)
  feed.token = feed.token + 1
  local myToken = feed.token
  local limit = cfgInt("items_per_feed", 5, 1, 15)

  feed.status = "loading"
  feed.err = nil
  feed.retryAt = noctalia.nowMs() + HANG_GUARD_MS

  noctalia.http({
    url = feed.url,
    follow_redirects = true,
    headers = {
      "User-Agent: noctalia-rss-feeds/1.0",
      "Accept: application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
    },
  }, function(res)
    if myToken ~= feed.token then return end

    local failed = true
    if res and res.ok and res.status >= 200 and res.status < 300 then
      local out = { items = {} }
      local ok, title = pcall(parseFeed, res.body or "", limit, out)
      if #out.items > 0 then
        -- Keep whatever was parsed, even if parsing errored out
        if ok and title ~= "" then feed.title = title end
        feed.items = out.items
        feed.status = "ok"
        failed = false
      elseif not ok then
        feed.status = "error"
        feed.err = "parse error: " .. tostring(title)
      else
        feed.status = "error"
        feed.err = "no entries found, limit " .. limit .. ", body " .. #(res.body or "") .. " bytes"
      end
    else
      feed.status = "error"
      feed.err = (res and res.status and res.status > 0) and ("HTTP " .. res.status) or "network error"
    end

    if failed then
      feed.retryMs = math.min(math.max(feed.retryMs * 2, RETRY_MIN_MS), RETRY_MAX_MS)
      feed.retryAt = noctalia.nowMs() + feed.retryMs
    else
      feed.retryMs = 0
      feed.retryAt = nil
    end
    render()
  end)
end

local function refreshAll()
  local interval = cfgInt("refresh_minutes", 30, 5, 1440) * 60 * 1000
  nextCycleAt = noctalia.nowMs() + interval
  for _, feed in ipairs(feeds) do fetchFeed(feed) end
end

function update()
  if feeds == nil then
    buildFeeds()
    render()
  end
  local now = noctalia.nowMs()
  if now >= nextCycleAt then
    refreshAll()
  else
    for _, feed in ipairs(feeds) do
      if feed.retryAt and now >= feed.retryAt then fetchFeed(feed) end
    end
  end
end

function onIpc(event, payload)
  if event == "refresh" then
    if feeds == nil then buildFeeds() end
    refreshAll()
    render()
  end
end
