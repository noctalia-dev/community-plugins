local games = {}
local filtered = {}
local searchText = ""
local loading = false
local errorMsg = ""
local scanCounter = 0
local building = false
local initOk = true
local selectedIndex = 0
local WINDOW_SIZE = 4

local steamCoverDir = ""
local heroicCoverDir = ""
local ok1, err1 = pcall(function()
  local xdgCache = noctalia.getenv("XDG_CACHE_HOME")
  local home = noctalia.getenv("HOME")
  local cacheBase
  if xdgCache and #xdgCache > 0 then
    cacheBase = xdgCache .. "/gamelauncher"
  elseif home and #home > 0 then
    cacheBase = home .. "/.cache/gamelauncher"
  else
    cacheBase = "/tmp/gamelauncher"
  end
  steamCoverDir = cacheBase .. "/steam"
  heroicCoverDir = cacheBase .. "/heroic"
  local ok, err = noctalia.mkdirAll(steamCoverDir)
  if not ok then noctalia.log("failed to create steam cover dir: " .. (err or "unknown")) end
  ok, err = noctalia.mkdirAll(heroicCoverDir)
  if not ok then noctalia.log("failed to create heroic cover dir: " .. (err or "unknown")) end
end)
if not ok1 then
  initOk = false
  noctalia.log("init error: " .. tostring(err1))
end

local binary = noctalia.pluginDir() .. "/gamelauncher"
local cSource = noctalia.pluginDir() .. "/gamelauncher.c"

local function isValidProtocol(cmd)
  local protocols = { "steam://", "lutris:", "heroic://" }
  for _, p in ipairs(protocols) do
    if cmd:sub(1, #p) == p then
      local rest = cmd:sub(#p + 1)
      if rest:match("^[%w_%-%.%/]+$") then return true end
    end
  end
  return false
end

local function isRunnerEnabled(runner)
  local ok, val = pcall(noctalia.getConfig, runner .. "_enabled")
  if ok then return val == true or val == "true" end
  return true
end

local function filterByRunner(g)
  return isRunnerEnabled(g.runner)
end

local function launchGame(id)
  for _, g in ipairs(filtered) do
    if g.id == id and g.run_command and #g.run_command > 0 and isValidProtocol(g.run_command) then
      noctalia.runAsync('xdg-open "' .. g.run_command .. '"')
      return
    end
  end
end

local function filterGames(text)
  local pool = {}
  for _, g in ipairs(games) do
    if filterByRunner(g) then table.insert(pool, g) end
  end
  if text == "" then
    filtered = pool
    return
  end
  local lower = text:lower()
  local result = {}
  for _, g in ipairs(pool) do
    if g.name:lower():find(lower, 1, true) or g.runner:lower():find(lower, 1, true) then
      table.insert(result, g)
    end
  end
  filtered = result
end

local function isImageFile(path)
  return noctalia.fileExists(path)
end

local function fetchSteamStoreCover(g, dest, cb)
  noctalia.http({ url = "https://store.steampowered.com/api/appdetails?appids=" .. g.id }, function(res2)
    pcall(function()
      if res2.ok and res2.status == 200 then
        local ok2, data2 = pcall(noctalia.json.decode, res2.body)
        if ok2 and data2 then
          local appData = data2[g.id]
          if appData and appData.data and appData.data.header_image then
            noctalia.download(appData.data.header_image, dest, function(ok3)
              pcall(function() if ok3 then g.cover = dest; render() end end)
            end)
            return
        end
      end
      end
    end)
  end)
end

local function fetchSteampoacherCover(g, dest, fallback)
  noctalia.http({ url = "https://steam-asset-proxy.steampoacher.workers.dev?appid=" .. g.id }, function(res)
    pcall(function()
      if res.ok and res.status == 200 then
        local ok, data = pcall(noctalia.json.decode, res.body)
        if ok and data and data.response and data.response.store_items then
          local item = data.response.store_items[1]
          if item and item.assets then
            local assets = item.assets
            local filename = assets.library_capsule_2x or assets.library_capsule or assets.header
            local fmt = assets.asset_url_format
            if filename and fmt then
              local placeholder = "${FILENAME}"
              local pos = fmt:find(placeholder, 1, true)
              local cdnUrl
              if pos then
                local prefix = fmt:sub(1, pos - 1)
                local suffix = fmt:sub(pos + #placeholder)
                cdnUrl = "https://shared.steamstatic.com/store_item_assets/" .. prefix .. filename .. suffix
              else
                cdnUrl = "https://shared.steamstatic.com/store_item_assets/" .. fmt .. "/" .. filename
              end
              noctalia.download(cdnUrl, dest, function(ok2)
                pcall(function()
                  if ok2 then g.cover = dest; render() return end
                  fallback()
                end)
              end)
              return
            end
          end
        end
      end
      pcall(function() fallback() end)
    end)
  end)
end

local function downloadSteamCover(g)
  local ok, err = pcall(function()
    if g.cover and #g.cover > 0 then return end
    local dest = steamCoverDir .. "/" .. g.id .. ".jpg"
    if isImageFile(dest) then
      g.cover = dest
      return
    end
    local steampoacherEnabled = false
    local okc, val = pcall(noctalia.getConfig, "steampoacher_enabled")
    if okc then
      steampoacherEnabled = val == true or val == "true"
    end
    if steampoacherEnabled then
      fetchSteampoacherCover(g, dest, function()
        fetchSteamStoreCover(g, dest)
      end)
    else
      fetchSteamStoreCover(g, dest)
    end
  end)
  if not ok then
    noctalia.log("downloadSteamCover error: " .. tostring(err))
  end
end

local function downloadHeroicCover(g)
  local ok, err = pcall(function()
    if g.cover and #g.cover > 0 then return end
    if not g.cover_url or #g.cover_url == 0 then return end
    local dest = heroicCoverDir .. "/" .. g.id .. ".jpg"
    if isImageFile(dest) then
      g.cover = dest
      return
    end
    noctalia.download(g.cover_url, dest, function(ok2)
      pcall(function()
        if ok2 then g.cover = dest; render() end
      end)
    end)
  end)
  if not ok then
    noctalia.log("downloadHeroicCover error: " .. tostring(err))
  end
end

local function fetchMissingCovers()
  for _, g in ipairs(games) do
    if g.runner == "steam" then
      downloadSteamCover(g)
    elseif g.runner == "heroic" then
      downloadHeroicCover(g)
    end
  end
end

local runnerMeta = {
  steam = { glyph = "brand-steam", color = "#66c0f4" },
  lutris = { glyph = "device-gamepad", color = "#ff6600" },
  heroic = { glyph = "app-window", color = "#a78bfa" },
}

local function renderHeader()
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "device-gamepad-2", size = 20, color = "primary" }),
    ui.label({ text = "Game Launcher", fontSize = 18, fontWeight = "bold", color = "primary", flexGrow = 1 }),
    ui.label({ text = "(" .. #games .. " games)", color = "on_surface_variant", fontSize = 12 }),
    ui.button({ glyph = "reload", variant = "ghost", onClick = "onRescan" }),
    ui.button({ glyph = "close", variant = "ghost", onClick = "onClose" }),
  })
end

local function renderSearchBar()
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "search", size = 14, color = "on_surface_variant" }),
    ui.input({ key = "search_" .. scanCounter, placeholder = "Search games…", onChange = "onSearch", value = searchText, flexGrow = 1, focus = true }),
    ui.button({ glyph = "filter", variant = "ghost", visible = false }),
  })
end

local function renderStatus()
  if loading then
    return ui.row({ align = "center", justify = "center", flexGrow = 1 }, {
      ui.label({ text = "Scanning for games…", color = "on_surface_variant" }),
    })
  end
  if errorMsg ~= "" then
    return ui.column({ align = "center", justify = "center", flexGrow = 1, gap = 12 }, {
      ui.glyph({ name = "alert-circle", size = 40, color = "error" }),
      ui.label({ text = errorMsg, color = "error", maxWidth = 400, textAlign = "center" }),
      ui.button({ text = "Retry", variant = "primary", onClick = "onRescan" }),
    })
  end
  if #filtered == 0 then
    return ui.row({ align = "center", justify = "center", flexGrow = 1 }, {
      ui.label({
        text = #games == 0 and "No games found. Click the reload button to scan." or "No games match your search.",
        color = "on_surface_variant",
      }),
    })
  end
  return nil
end

local function renderGameRow(g, index)
  local meta = runnerMeta[g.runner] or { glyph = "app-window", color = "on_surface_variant" }
  local isSelected = (index - 1) == selectedIndex
  local cp = (g.cover and #g.cover > 0) and g.cover or nil
  if not cp then
    if g.runner == "steam" then
      cp = steamCoverDir .. "/" .. g.id .. ".jpg"
    elseif g.runner == "heroic" then
      cp = heroicCoverDir .. "/" .. g.id .. ".jpg"
    end
  end
  local coverWidget
  if cp and noctalia.fileExists(cp) then
    coverWidget = ui.image({ path = cp, width = 56, height = 80, radius = 6, fit = "cover" })
  else
    coverWidget = ui.box({ width = 56, height = 80, radius = 6, fill = "surface_variant" })
  end
  local children = {
    coverWidget,
    ui.column({ flexGrow = 1, gap = 4 }, {
      ui.label({ text = g.name, fontWeight = "bold", fontSize = 14, maxLines = 1 }),
      ui.row({ align = "center", gap = 6 }, {
        ui.glyph({ name = meta.glyph, size = 12, color = meta.color }),
        ui.label({ text = g.runner, fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.button({
      text = "Launch",
      glyph = "player-play",
      variant = "primary",
      onClick = function() launchGame(g.id) end,
    }),
  }
  if isSelected then
    table.insert(children, 1, ui.box({ width = 2, height = 60, radius = 1, fill = "primary" }))
    return ui.row({
      key = g.id .. "_sel_" .. index,
      align = "center",
      gap = 14,
      paddingH = 12,
      paddingV = 8,
      radius = 8,
    }, children)
  end
  return ui.row({
    key = g.id .. "_" .. index,
    align = "center",
    gap = 14,
    paddingH = 12,
    paddingV = 8,
    radius = 8,
  }, children)
end

local function renderGameList()
  local rows = {}
  local total = #filtered
  if total == 0 then return rows end
  local half = math.floor(WINDOW_SIZE / 2)
  local start = math.max(1, selectedIndex + 1 - half)
  if start + WINDOW_SIZE > total then
    start = math.max(1, total - WINDOW_SIZE + 1)
  end
  local endIdx = math.min(total, start + WINDOW_SIZE - 1)
  for i = start, endIdx do
    table.insert(rows, renderGameRow(filtered[i], i))
  end
  return rows
end

local function renderBody(content)
  if loading then
    return ui.label({ text = "Scanning for games…", color = "on_surface_variant" })
  end
  if errorMsg ~= "" then
    return ui.column({ align = "center", justify = "center", gap = 12 }, {
      ui.glyph({ name = "alert-circle", size = 40, color = "error" }),
      ui.label({ text = errorMsg, color = "error", maxWidth = 400, textAlign = "center" }),
      ui.button({ text = "Retry", variant = "primary", onClick = "onRescan" }),
    })
  end
  if #filtered == 0 then
    return ui.label({
      text = #games == 0 and "No games found. Click the reload button to scan." or "No games match your search.",
      color = "on_surface_variant",
    })
  end
  return content
end

local function render()
  local ok, err = pcall(function()
    panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 12 }, {
      ui.column({ gap = 8 }, {
        renderHeader(),
        renderSearchBar(),
      }),
      ui.column({ flexGrow = 1, gap = 6 }, renderBody(renderGameList())),
    }))
  end)
  if not ok then
    noctalia.log("render error: " .. tostring(err))
  end
end

local function buildBinary()
  if building then return end
  building = true
  loading = true
  errorMsg = ""
  render()
  local ok = noctalia.runAsync("/usr/bin/cc -o " .. binary .. " " .. cSource .. " -lsqlite3", function(res)
    building = false
    if res.exitCode == 0 then
      loading = false
      scanGames()
    else
      loading = false
      errorMsg = "Failed to build gamelauncher. Install gcc and libsqlite3-dev. (exit " .. (res.exitCode or "?") .. ")"
      noctalia.log("build failed: " .. (res.stderr or "no stderr"))
      render()
    end
  end)
  if not ok then
    building = false
    loading = false
    errorMsg = "Failed to start build process"
    render()
  end
end

local function scanGames()
  if loading or building then return end
  if not noctalia.fileExists(binary) then
    buildBinary()
    return
  end
  loading = true
  errorMsg = ""
  scanCounter = scanCounter + 1
  searchText = ""
  render()
  local flags = ""
  if isRunnerEnabled("steam") then flags = flags .. " --steam" end
  if isRunnerEnabled("lutris") then flags = flags .. " --lutris" end
  if isRunnerEnabled("heroic") then flags = flags .. " --heroic" end
  local ok = noctalia.runAsync(binary .. flags .. " --force", function(res)
    local ok3, err3 = pcall(function()
      loading = false
      if res.exitCode == 0 and res.stdout and #res.stdout > 0 then
        local parsed, err2 = noctalia.json.decode(res.stdout)
        if parsed then
          games = parsed
          fetchMissingCovers()
        else
          errorMsg = "Failed to parse game list: " .. (err2 or "unknown error")
          noctalia.log("parse error on stdout: " .. res.stdout:sub(1, 200))
          games = {}
        end
      else
        errorMsg = "Game scan failed (exit " .. (res.exitCode or "?") .. ")"
        if res.stderr and #res.stderr > 0 then
          errorMsg = errorMsg .. ": " .. res.stderr:sub(1, 200)
        end
        games = {}
      end
      selectedIndex = 0
      filterGames(searchText)
    end)
    if not ok3 then
      loading = false
      errorMsg = "Scan error: " .. tostring(err3)
      games = {}
      filtered = games
      selectedIndex = 0
      noctalia.log("scan callback error: " .. tostring(err3))
    end
    render()
  end)
  if not ok then
    loading = false
    errorMsg = "Failed to start game scan"
    render()
  end
end


function onOpen(context)
  selectedIndex = 0
  filterGames(searchText)
  render()
  scanGames()
end

function onClose()
  panel.close()
end

function onRescan()
  scanGames()
end

function onSearch(value)
  searchText = value or ""
  selectedIndex = 0
  filterGames(searchText)
  render()
end

function onKey(chord, pressed)
  if not pressed then return end
  if chord == "Up" then
    if #filtered > 0 then
      selectedIndex = selectedIndex - 1
      if selectedIndex < 0 then selectedIndex = #filtered - 1 end
      render()
    end
  elseif chord == "Down" then
    if #filtered > 0 then
      selectedIndex = selectedIndex + 1
      if selectedIndex >= #filtered then selectedIndex = 0 end
      render()
    end
  elseif chord == "Return" then
    if #filtered > 0 and selectedIndex >= 0 and selectedIndex < #filtered then
      launchGame(filtered[selectedIndex + 1].id)
    end
  end
end
