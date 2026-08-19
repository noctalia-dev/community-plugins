--!nonstrict
-- Daily Wallpaper service for Noctalia 5.
-- Fetches one Bing or NASA image per day, caches it locally, and applies it via
-- the native Noctalia wallpaper API. Also captures each source's caption text
-- (Bing's `copyright` field; NASA's gallery-item caption) and publishes it as
-- "today" state for widget.luau/panel.luau/desktop_widget.luau to display —
-- neither source's raw API gives a wallpaper-application step any reason to
-- keep this text, so it has to be captured here, at the point each source is
-- resolved, or it is lost.

local CHECK_INTERVAL_MS = 10 * 60 * 1000
local RETENTION_SECONDS = 5 * 24 * 60 * 60
local PLUGIN_CACHE_DIR = "daily-wallpaper"

local checking = false
local lastAppliedPath = ""
local lastCheckedKey = ""
local lastErrorNotificationDate = ""

noctalia.setUpdateInterval(CHECK_INTERVAL_MS)

local function todayString()
  return os.date("%Y-%m-%d")
end

local function normalizeLocale(value)
  if type(value) ~= "string" then
    return "en-us"
  end

  local locale = noctalia.string.trim(value):lower():gsub("_", "-")
  if locale == "" or locale:find("[^%w%-]") then
    return "en-us"
  end
  return locale
end

local function source()
  local configured = noctalia.getConfig("source")
  if configured == "nasa" then
    return "nasa"
  end
  return "bing"
end

local function downloadDir()
  return noctalia.expandPath(`{noctalia.wallpaperDirectory()}/{PLUGIN_CACHE_DIR}`)
end

local function cachePath(prefix, date)
  return `{downloadDir()}/{prefix}-{date}.jpg`
end

local function decodeHtml(value)
  local decoded = value:gsub("&amp;", "&")
  decoded = decoded:gsub("&quot;", '"')
  -- Numeric entities generally (covers both &#39; and &#039;, which NASA's
  -- markup uses for apostrophes in captions).
  decoded = decoded:gsub("&#(%d+);", function(n)
    local code = tonumber(n)
    return (code and code < 256) and string.char(code) or ""
  end)
  return decoded
end

-- Bing's `copyright` field reads like "Caption text (© Photographer/Source)" —
-- split the trailing parenthesized attribution off into its own field so
-- title and credit can be shown separately.
local function splitCopyright(copyright)
  local body, credit = copyright:match("^(.-)%s*%(([^()]*)%)%s*$")
  if body and credit then
    return decodeHtml(body), decodeHtml(credit)
  end
  return decodeHtml(copyright), ""
end

-- Publishes today's caption/credit/"learn more" link for the bar widget,
-- panel, and desktop widget. Independent of whether the image itself still
-- needs downloading — metadata is available as soon as a source resolves.
local function publishToday(selectedSource, date, info)
  if type(info) ~= "table" then
    return
  end
  noctalia.state.set("today", {
    date = date,
    source = selectedSource,
    title = info.title or "",
    credit = info.credit or "",
    link = info.link or "",
  })
  noctalia.log(`Daily Wallpaper caption: {info.title or ""}`)
end

local function absoluteNasaUrl(url)
  if url == nil or url == "" then
    return ""
  end
  url = decodeHtml(url)
  if url:match("^https?://") then
    return url
  end
  if url:match("^//") then
    return `https:{url}`
  end
  if url:sub(1, 1) == "/" then
    return `https://www.nasa.gov{url}`
  end
  return `https://www.nasa.gov/{url}`
end

local function applyWallpaper(path, downloaded)
  noctalia.setWallpaper(path)
  lastAppliedPath = path
  lastCheckedKey = `{source()}:{todayString()}`
  noctalia.state.set("status", {
    state = "applied",
    path = path,
    downloaded = downloaded,
  })
  noctalia.log(`Daily Wallpaper applied: {path}`)
end

local function cleanupOldWallpapers(dir)
  local entries = noctalia.listDir(dir)
  if type(entries) ~= "table" then
    return
  end

  local cutoff = os.time() - RETENTION_SECONDS
  for _, name in ipairs(entries) do
    if name:match("^bing%-.+%-%d%d%d%d%-%d%d%-%d%d%.jpg$") or name:match("^nasa%-%d%d%d%d%-%d%d%-%d%d%.jpg$") then
      local path = `{dir}/{name}`
      local info = noctalia.fileInfo(path)
      if type(info) == "table" and type(info.mtime) == "number" and info.mtime < cutoff then
        noctalia.removeFile(path)
      end
    end
  end
end

local function fail(message)
  checking = false
  noctalia.state.set("status", {
    state = "error",
    message = message,
  })
  local date = todayString()
  if lastErrorNotificationDate ~= date then
    lastErrorNotificationDate = date
    noctalia.notifyError(noctalia.tr("notify.failed"), message)
  end
  noctalia.log(`Daily Wallpaper failed: {message}`)
end

local function downloadAndApply(primaryUrl, fallbackUrl, dest)
  local function tryDownload(url, fallback)
    if type(url) ~= "string" or url == "" then
      if fallback ~= "" then
        tryDownload(fallback, "")
      else
        fail("No wallpaper URL found")
      end
      return
    end

    local started = noctalia.download(url, dest, function(ok)
      if ok then
        checking = false
        cleanupOldWallpapers(downloadDir())
        applyWallpaper(dest, true)
        noctalia.notify(noctalia.tr("notify.applied"), dest)
        return
      end

      if fallback ~= "" then
        tryDownload(fallback, "")
      else
        fail("Download failed")
      end
    end)

    if not started then
      fail("Could not start wallpaper download")
    end
  end

  tryDownload(primaryUrl, fallbackUrl or "")
end

local function resolveBing(locale, done)
  local url = `https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt={noctalia.string.urlEncode(locale)}`
  local started = noctalia.http({ url = url }, function(res)
    if not res.ok or res.status < 200 or res.status >= 300 then
      fail(`Bing request failed: HTTP {res.status}`)
      return
    end

    local parsed, err = noctalia.json.decode(res.body)
    if parsed == nil then
      fail(`Bing response parse failed: {err or "invalid JSON"}`)
      return
    end

    local first = parsed.images and parsed.images[1]
    local urlBase = first and first.urlbase
    if type(urlBase) ~= "string" or urlBase == "" then
      fail("Bing response did not include an image URL")
      return
    end

    local title, credit = splitCopyright(first.copyright or "")
    local link = (type(first.copyrightlink) == "string" and first.copyrightlink ~= "")
        and first.copyrightlink or ""

    done(`bing-{locale}`, `https://www.bing.com{urlBase}_UHD.jpg`, `https://www.bing.com{urlBase}_1920x1080.jpg`,
      { title = title, credit = credit, link = link })
  end)

  if not started then
    fail("Could not start Bing request")
  end
end

local function resolveNasa(done)
  local started = noctalia.http({ url = "https://www.nasa.gov/image-of-the-day/" }, function(res)
    if not res.ok or res.status < 200 or res.status >= 300 then
      fail(`NASA request failed: HTTP {res.status}`)
      return
    end

    local page = res.body
    local primary = page:match('class="[^"]-hds%-gallery%-image[^"]-"[^>]->.-<img[^>]-src="([^"]+)"')
      or page:match('<img[^>]-class="[^"]-hds%-gallery%-image[^"]-"[^>]-src="([^"]+)"')
    local fallback = page:match('<meta%s+property="og:image"%s+content="([^"]+)"')
      or page:match('<meta%s+name="twitter:image"%s+content="([^"]+)"')

    primary = absoluteNasaUrl(primary or "")
    fallback = absoluteNasaUrl(fallback or "")

    if primary == "" and fallback == "" then
      fail("NASA page did not include an image URL")
      return
    end

    -- NASA gives one caption sentence per gallery item and no separate
    -- credit line (unlike Bing's "(© ...)" suffix), so title is the whole
    -- caption and credit stays empty. The gallery item's own link goes to
    -- NASA's full article about the image — a much richer "learn more"
    -- target than Bing's quiz page.
    local caption = page:match('class="hds%-gallery%-item%-caption[^"]*">([^<]*)</div>')
    local link = page:match('class="hds%-gallery%-item%-link[^"]*"%s+href="([^"]+)"')

    done("nasa", primary, fallback,
      { title = decodeHtml(caption or ""), credit = "", link = link or "" })
  end)

  if not started then
    fail("Could not start NASA request")
  end
end

local function fetchAndApply(force)
  if checking then
    return
  end

  local selectedSource = source()
  local date = todayString()
  local locale = normalizeLocale(noctalia.getConfig("locale"))
  local key = `{selectedSource}:{date}`
  if not force and key == lastCheckedKey then
    return
  end

  local cachePrefix = selectedSource == "bing" and `bing-{locale}` or selectedSource
  local dest = cachePath(cachePrefix, date)
  if not force and dest == lastAppliedPath then
    lastCheckedKey = key
    return
  end

  local dir = downloadDir()
  local ok, err = noctalia.mkdirAll(dir)
  if not ok then
    fail(`Could not create download directory: {err or dir}`)
    return
  end

  checking = true
  noctalia.state.set("status", {
    state = "checking",
    source = selectedSource,
  })

  if not force and noctalia.fileExists(dest) then
    checking = false
    cleanupOldWallpapers(dir)
    applyWallpaper(dest, false)
    -- The image was already cached (e.g. from before a restart), but this
    -- process may not have captured its caption yet — re-resolve for
    -- metadata only, without re-downloading the (already-cached) image.
    local function onInfoOnly(_prefix, _primaryUrl, _fallbackUrl, info)
      publishToday(selectedSource, date, info)
    end
    if selectedSource == "nasa" then
      resolveNasa(onInfoOnly)
    else
      resolveBing(locale, onInfoOnly)
    end
    return
  end

  local function onResolved(prefix, primaryUrl, fallbackUrl, info)
    publishToday(selectedSource, date, info)
    local resolvedDest = cachePath(prefix, date)
    downloadAndApply(primaryUrl, fallbackUrl, resolvedDest)
  end

  if selectedSource == "nasa" then
    resolveNasa(onResolved)
  else
    resolveBing(locale, onResolved)
  end
end

function update()
  fetchAndApply(false)
end

function onConfigChanged()
  lastCheckedKey = ""
  fetchAndApply(true)
end

function onIpc(event, _payload)
  if event == "refresh" then
    lastCheckedKey = ""
    fetchAndApply(true)
  end
end

fetchAndApply(false)
