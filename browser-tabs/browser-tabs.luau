--!strict
-- Browser Tabs launcher provider.
--
-- Usage from the launcher: `/bt <query>` - searches open tabs across all
-- browsers by title and URL. Press Enter on a result to focus that tab.
--
-- Uses tabctl (https://github.com/slastra/tabctl) via D-Bus to query
-- and activate tabs across Firefox, Chromium, Brave, Zen, and others.

-- Browser name → glyph mapping for result icons.
local BROWSER_GLYPHS = {
  firefox = "globe",
  zen = "globe",
  chrome = "globe",
  chromium = "globe",
  brave = "shield",
  edge = "globe",
  helium = "globe",
  vivaldi = "globe",
}

-- Favicon cache: download website icons for result rows.
-- Uses the same Google Favicon API as the web-search community plugin.
-- pluginDir() is the (read-only, Nix-store-symlinked on this machine) plugin
-- source directory -- pluginDataDir() is the writable, per-plugin state dir
-- meant for exactly this kind of durable cache.
local faviconCacheDir: string? = (function(): string?
  local dir = noctalia.pluginDataDir()
  if not dir then return nil end
  return dir .. "/favicons"
end)()
local faviconPendingRefresh = false

local function domainFromUrl(url)
  if not url then return nil end
  local domain = url:match("^https?://([^/:]+)")
  return domain and domain:gsub("^www%.", "") or nil
end

local function faviconPath(domain: string, cacheDir: string)
  local safe = domain:gsub("[^%w%.%-]", "_")
  return cacheDir .. "/" .. safe .. ".png"
end

-- Returns the local icon path if cached, or nil and starts an async download.
-- On download completion, calls refresh() to re-render results.
local function loadFavicon(domain, query, refresh)
  if not domain or not faviconCacheDir then return nil end
  local cacheDir = faviconCacheDir

  local path = faviconPath(domain, cacheDir)
  if noctalia.fileExists(path) then
    return path
  end

  -- Don't re-trigger refresh storms: one download per query batch is enough.
  noctalia.mkdirAll(cacheDir)
  local url = "https://www.google.com/s2/favicons?sz=64&domain=" .. noctalia.string.urlEncode(domain)
  noctalia.download(url, path, function(ok)
    if ok and not faviconPendingRefresh then
      faviconPendingRefresh = true
      -- Small delay to batch multiple favicon downloads into one refresh
      refresh(query)
      faviconPendingRefresh = false
    end
  end)
  return nil
end

-- Last query we received; used to discard stale responses.
local currentQuery = ""

local function hintRow(title, subtitle, glyph)
  return { id = title, title = title, subtitle = subtitle, glyph = glyph or "globe" }
end

local function tabRow(tab, query, refresh, score)
  -- tab.id is e.g. "firefox.1.2" — extract browser name from prefix
  local browser = "browser"
  if tab.id then
    browser = tab.id:match("^([^.]+)") or "browser"
  end

  local glyph = BROWSER_GLYPHS[browser:lower()] or "globe"
  local subtitle = tab.url or ""
  if browser ~= "" then
    -- Capitalize browser name for display
    local display = browser:sub(1, 1):upper() .. browser:sub(2):lower()
    subtitle = display .. " — " .. subtitle
  end

  -- Try to show the website's favicon; fall back to browser glyph.
  -- tabctl provides favIconUrl, but we prefer downloading by domain
  -- (cached locally) so we don't serve data: URIs or rely on
  -- the browser-internal URL being reachable from outside.
  local domain = domainFromUrl(tab.url)
  local icon = loadFavicon(domain, query, refresh)

  return {
    id = tab.id or "",
    title = tab.title or "(untitled)",
    subtitle = subtitle,
    glyph = icon and nil or glyph,
    icon = icon,
    score = score,
  }
end

-- Higher is a better match; nil means no match at all. Scores against both
-- title and URL since a query can match either (e.g. a domain name that
-- isn't in the page title).
local function matchScore(query, tab)
  local titleScore = noctalia.fuzzyScore(query, tab.title or "")
  local urlScore = noctalia.fuzzyScore(query, tab.url or "")
  if titleScore and urlScore then
    return math.max(titleScore, urlScore)
  end
  return titleScore or urlScore
end

-- Returns matching tabs sorted best-match-first, alongside a tab->score map
-- so buildResults can set LauncherResult.score (needed to rank decently in
-- the launcher's merged "All" view -- without it, results default to the
-- bottom regardless of match quality).
local function filterTabs(tabs, query)
  if query == "" then
    return tabs, nil
  end

  local scored = {}
  for _, tab in tabs do
    local score = matchScore(query, tab)
    if score then
      table.insert(scored, { tab = tab, score = score })
    end
  end
  table.sort(scored, function(a, b)
    return a.score > b.score
  end)

  local filtered = {}
  local scores = {}
  for _, entry in scored do
    table.insert(filtered, entry.tab)
    scores[entry.tab] = entry.score
  end
  return filtered, scores
end

-- In-flight guard: only one tabctl process at a time.
local pending = false

-- Cache the last successful tab list so favicon refreshes can re-render
-- without re-querying tabctl.
local lastTabs = nil

local function buildResults(tabs, text, query, refresh)
  local filtered, scores = filterTabs(tabs, text)

  if #filtered == 0 then
    return {
      hintRow("No matching tabs", "No open tab matches \"" .. text .. "\"", "search"),
    }
  end

  local results = {}
  for _, tab in filtered do
    local score = scores and scores[tab] or nil
    table.insert(results, tabRow(tab, query, refresh, score))
  end
  return results
end

function onQuery(query)
  currentQuery = query

  local text = noctalia.string.trim(query)
  if text == "" then
    launcher.setResults(query, {
      hintRow("Search browser tabs", "Type to search open tabs across all browsers", "globe"),
    })
    return
  end

  -- Refresh callback for async favicon downloads: re-renders results
  -- using the cached tab list without re-querying tabctl.
  local function refresh(activeQuery)
    if lastTabs and activeQuery == currentQuery then
      local freshText = noctalia.string.trim(activeQuery)
      launcher.setResults(activeQuery, buildResults(lastTabs, freshText, activeQuery, refresh))
    end
  end

  if pending then
    launcher.setResults(query, { hintRow("Searching…", text, "loader") })
    return
  end

  pending = true
  launcher.setResults(query, { hintRow("Searching…", text, "loader") })

  noctalia.runAsync({ "tabctl", "list", "--format", "json" }, function(res)
    pending = false

    -- Discard if a newer query has superseded this one.
    if query ~= currentQuery then
      return
    end

    if res.exitCode ~= 0 then
      local msg = "No browsers found"
      local stderr = res.stderr
      if stderr and stderr ~= "" then
        msg = stderr:match("Error: (.+)") or stderr:gsub("\n", " ")
        if #msg > 100 then
          msg = msg:sub(1, 97) .. "..."
        end
      end
      launcher.setResults(query, {
        hintRow("No browser tabs available", msg, "alert-triangle"),
      })
      return
    end

    local ok, tabs = pcall(noctalia.json.decode, res.stdout)
    if not ok or type(tabs) ~= "table" then
      launcher.setResults(query, {
        hintRow("Could not parse tab list", "tabctl returned unexpected output", "alert-triangle"),
      })
      return
    end

    lastTabs = tabs
    launcher.setResults(query, buildResults(tabs, text, query, refresh))
  end)
end

-- Map tabctl browser names to Wayland app_id patterns.
-- Used by compositor-aware focus to find the right window.
local BROWSER_APP_IDS = {
  firefox = "firefox",
  zen = "zen",
  chromium = "chromium-browser",
  chrome = "google-chrome",
  brave = "brave-browser",
  edge = "microsoft-edge",
  vivaldi = "vivaldi",
  helium = "helium",
}

-- Detect the running compositor once at load time via env vars.
-- Returns "niri", "hyprland", "sway", or nil (unknown/unsupported).
local function detectCompositor()
  -- niri sets NIRI_SOCKET
  if noctalia.getenv("NIRI_SOCKET") then
    return "niri"
  end
  -- Hyprland sets HYPRLAND_INSTANCE_SIGNATURE
  if noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") then
    return "hyprland"
  end
  -- sway sets SWAYSOCK
  if noctalia.getenv("SWAYSOCK") then
    return "sway"
  end
  return nil
end

local compositor = detectCompositor()

-- Focus the browser window in the compositor (switches workspace).
-- Supports niri, Hyprland, and sway. Falls back gracefully to no-op
-- on unsupported compositors (tabctl's own window focus still works).
local function focusBrowserWindow(browserName)
  local appId = BROWSER_APP_IDS[browserName:lower()]
  if not appId then
    return
  end

  if compositor == "niri" then
    -- niri: list windows as JSON, find by app_id, focus by id
    noctalia.runAsync({ "niri", "msg", "--json", "windows" }, function(res)
      if res.exitCode ~= 0 or not res.stdout or res.stdout == "" then
        return
      end
      local ok, windows = pcall(noctalia.json.decode, res.stdout)
      if not ok or type(windows) ~= "table" then
        return
      end
      for _, win in windows do
        if win.app_id and win.app_id:lower():find(appId, 1, true) then
          noctalia.runAsync({ "niri", "msg", "action", "focus-window", "--id", tostring(win.id) }, function() end)
          return
        end
      end
    end)

  elseif compositor == "hyprland" then
    -- Hyprland: hyprctl dispatch focuswindow address: by class
    noctalia.runAsync({ "hyprctl", "dispatch", "focuswindow", appId }, function() end)

  elseif compositor == "sway" then
    -- sway: swaymsg [app_id="..."] focus
    local criteria = '[app_id="' .. appId .. '"]'
    noctalia.runAsync({ "swaymsg", criteria, "focus" }, function() end)
  end

  -- Unknown compositor: no-op — tabctl's own chrome.windows.update({focused:true})
  -- is the best we can do, which works if the window is on the current workspace.
end

function onActivate(id)
  if id == "" then
    return
  end

  -- Check if this is a real tab ID (contains dots like "firefox.1.2")
  if not id:find(".", 1, true) then
    return
  end

  -- Extract browser name from tab ID (e.g. "firefox" from "firefox.1.2")
  local browserName = id:match("^([^.]+)") or ""

  -- Step 1: Tell tabctl to activate the tab (selects tab inside browser)
  noctalia.runAsync({ "tabctl", "activate", id }, function(res)
    if res.exitCode ~= 0 then
      local msg = "Could not activate tab"
      local stderr = res.stderr
      if stderr and stderr ~= "" then
        msg = stderr:match("Error: (.+)") or msg
      end
      noctalia.notify("Browser Tabs", msg)
      return
    end

    -- Step 2: Tell the compositor to focus the browser window (switches workspace)
    focusBrowserWindow(browserName)
  end)
end
