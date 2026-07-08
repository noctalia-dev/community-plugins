--!nonstrict
-- Daily Wallpaper service for Noctalia 5.
-- Fetches one Bing or NASA image per day, caches it locally, and applies it via
-- the native Noctalia wallpaper API.

local CHECK_INTERVAL_MS = 10 * 60 * 1000
local RETENTION_SECONDS = 5 * 24 * 60 * 60
local PLUGIN_CACHE_DIR = "daily-wallpaper"

local checking = false
local lastAppliedPath = ""
local lastCheckedKey = ""

noctalia.setUpdateInterval(CHECK_INTERVAL_MS)

local function todayString()
  return os.date("%Y-%m-%d")
end

local function normalizeLocale(value)
  if type(value) ~= "string" then
    return "en-us"
  end

  local locale = noctalia.string.trim(value):lower():gsub("_", "-")
  if locale == "" then
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
  local wallpaperDir = noctalia.wallpaperDirectory()
  if type(wallpaperDir) == "string" and wallpaperDir ~= "" then
    return noctalia.expandPath(wallpaperDir)
  end

  local stateHome = noctalia.getenv("XDG_STATE_HOME")
  if type(stateHome) ~= "string" or stateHome == "" then
    stateHome = (noctalia.getenv("HOME") or "") .. "/.local/state"
  end
  return noctalia.expandPath(`{stateHome}/noctalia/{PLUGIN_CACHE_DIR}`)
end

local function cachePath(prefix, date)
  return `{downloadDir()}/{prefix}-{date}.jpg`
end

local function decodeHtml(value)
  local decoded = value:gsub("&amp;", "&")
  decoded = decoded:gsub("&quot;", '"')
  decoded = decoded:gsub("&#39;", "'")
  return decoded
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
    if name:match("^bing%-%d%d%d%d%-%d%d%-%d%d%.jpg$") or name:match("^nasa%-%d%d%d%d%-%d%d%-%d%d%.jpg$") then
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
  noctalia.notifyError(noctalia.tr("notify.failed"), message)
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

    done("bing", `https://www.bing.com{urlBase}_UHD.jpg`, `https://www.bing.com{urlBase}_1920x1080.jpg`)
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

    done("nasa", primary, fallback)
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
  local key = `{selectedSource}:{date}`
  if not force and key == lastCheckedKey then
    return
  end

  local dest = cachePath(selectedSource, date)
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

  if noctalia.fileExists(dest) then
    checking = false
    cleanupOldWallpapers(dir)
    applyWallpaper(dest, false)
    return
  end

  local function onResolved(prefix, primaryUrl, fallbackUrl)
    local resolvedDest = cachePath(prefix, date)
    downloadAndApply(primaryUrl, fallbackUrl, resolvedDest)
  end

  if selectedSource == "nasa" then
    resolveNasa(onResolved)
  else
    resolveBing(normalizeLocale(noctalia.getConfig("locale")), onResolved)
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
