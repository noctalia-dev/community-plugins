local games = {}
local filtered = {}
local searchText = ""
local loading = false
local errorMsg = ""
local scanCounter = 0
local building = false
local MAX_VISIBLE = 200
local initOk = true

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

local function launchGame(id)
  for _, g in ipairs(filtered) do
    if g.id == id and g.run_command and #g.run_command > 0 and isValidProtocol(g.run_command) then
      noctalia.runAsync('xdg-open "' .. g.run_command .. '"')
      return
    end
  end
end

local function filterGames(text)
  if text == "" then
    filtered = games
    return
  end
  local lower = text:lower()
  local result = {}
  for _, g in ipairs(games) do
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
  return ui.row({
    key = g.id .. "_" .. index,
    align = "center",
    gap = 14,
    paddingH = 12,
    paddingV = 8,
    radius = 8,
    border = 0,
  }, {
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
      onClick = "onLaunch_" .. index,
    }),
  })
end

local function renderGameList()
  if #filtered > MAX_VISIBLE then
    local rows = {}
    for i = 1, MAX_VISIBLE do
      table.insert(rows, renderGameRow(filtered[i], i))
    end
    return rows
  end
  local rows = {}
  for i, g in ipairs(filtered) do
    table.insert(rows, renderGameRow(g, i))
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
    panel.render(ui.column({ flexGrow = 1, gap = 8 }, {
      ui.column({ padding = 12, gap = 8 }, {
        renderHeader(),
        renderSearchBar(),
      }),
      ui.scroll({ flexGrow = 1, gap = 6, paddingH = 12 }, renderBody(renderGameList())),
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
  local ok = noctalia.runAsync(binary .. " --steam --lutris --heroic --force", function(res)
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
      filtered = games
    end)
    if not ok3 then
      loading = false
      errorMsg = "Scan error: " .. tostring(err3)
      games = {}
      filtered = games
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

function onLaunch_1() if filtered[1] then launchGame(filtered[1].id) end end
function onLaunch_2() if filtered[2] then launchGame(filtered[2].id) end end
function onLaunch_3() if filtered[3] then launchGame(filtered[3].id) end end
function onLaunch_4() if filtered[4] then launchGame(filtered[4].id) end end
function onLaunch_5() if filtered[5] then launchGame(filtered[5].id) end end
function onLaunch_6() if filtered[6] then launchGame(filtered[6].id) end end
function onLaunch_7() if filtered[7] then launchGame(filtered[7].id) end end
function onLaunch_8() if filtered[8] then launchGame(filtered[8].id) end end
function onLaunch_9() if filtered[9] then launchGame(filtered[9].id) end end
function onLaunch_10() if filtered[10] then launchGame(filtered[10].id) end end
function onLaunch_11() if filtered[11] then launchGame(filtered[11].id) end end
function onLaunch_12() if filtered[12] then launchGame(filtered[12].id) end end
function onLaunch_13() if filtered[13] then launchGame(filtered[13].id) end end
function onLaunch_14() if filtered[14] then launchGame(filtered[14].id) end end
function onLaunch_15() if filtered[15] then launchGame(filtered[15].id) end end
function onLaunch_16() if filtered[16] then launchGame(filtered[16].id) end end
function onLaunch_17() if filtered[17] then launchGame(filtered[17].id) end end
function onLaunch_18() if filtered[18] then launchGame(filtered[18].id) end end
function onLaunch_19() if filtered[19] then launchGame(filtered[19].id) end end
function onLaunch_20() if filtered[20] then launchGame(filtered[20].id) end end
function onLaunch_21() if filtered[21] then launchGame(filtered[21].id) end end
function onLaunch_22() if filtered[22] then launchGame(filtered[22].id) end end
function onLaunch_23() if filtered[23] then launchGame(filtered[23].id) end end
function onLaunch_24() if filtered[24] then launchGame(filtered[24].id) end end
function onLaunch_25() if filtered[25] then launchGame(filtered[25].id) end end
function onLaunch_26() if filtered[26] then launchGame(filtered[26].id) end end
function onLaunch_27() if filtered[27] then launchGame(filtered[27].id) end end
function onLaunch_28() if filtered[28] then launchGame(filtered[28].id) end end
function onLaunch_29() if filtered[29] then launchGame(filtered[29].id) end end
function onLaunch_30() if filtered[30] then launchGame(filtered[30].id) end end
function onLaunch_31() if filtered[31] then launchGame(filtered[31].id) end end
function onLaunch_32() if filtered[32] then launchGame(filtered[32].id) end end
function onLaunch_33() if filtered[33] then launchGame(filtered[33].id) end end
function onLaunch_34() if filtered[34] then launchGame(filtered[34].id) end end
function onLaunch_35() if filtered[35] then launchGame(filtered[35].id) end end
function onLaunch_36() if filtered[36] then launchGame(filtered[36].id) end end
function onLaunch_37() if filtered[37] then launchGame(filtered[37].id) end end
function onLaunch_38() if filtered[38] then launchGame(filtered[38].id) end end
function onLaunch_39() if filtered[39] then launchGame(filtered[39].id) end end
function onLaunch_40() if filtered[40] then launchGame(filtered[40].id) end end
function onLaunch_41() if filtered[41] then launchGame(filtered[41].id) end end
function onLaunch_42() if filtered[42] then launchGame(filtered[42].id) end end
function onLaunch_43() if filtered[43] then launchGame(filtered[43].id) end end
function onLaunch_44() if filtered[44] then launchGame(filtered[44].id) end end
function onLaunch_45() if filtered[45] then launchGame(filtered[45].id) end end
function onLaunch_46() if filtered[46] then launchGame(filtered[46].id) end end
function onLaunch_47() if filtered[47] then launchGame(filtered[47].id) end end
function onLaunch_48() if filtered[48] then launchGame(filtered[48].id) end end
function onLaunch_49() if filtered[49] then launchGame(filtered[49].id) end end
function onLaunch_50() if filtered[50] then launchGame(filtered[50].id) end end
function onLaunch_51() if filtered[51] then launchGame(filtered[51].id) end end
function onLaunch_52() if filtered[52] then launchGame(filtered[52].id) end end
function onLaunch_53() if filtered[53] then launchGame(filtered[53].id) end end
function onLaunch_54() if filtered[54] then launchGame(filtered[54].id) end end
function onLaunch_55() if filtered[55] then launchGame(filtered[55].id) end end
function onLaunch_56() if filtered[56] then launchGame(filtered[56].id) end end
function onLaunch_57() if filtered[57] then launchGame(filtered[57].id) end end
function onLaunch_58() if filtered[58] then launchGame(filtered[58].id) end end
function onLaunch_59() if filtered[59] then launchGame(filtered[59].id) end end
function onLaunch_60() if filtered[60] then launchGame(filtered[60].id) end end
function onLaunch_61() if filtered[61] then launchGame(filtered[61].id) end end
function onLaunch_62() if filtered[62] then launchGame(filtered[62].id) end end
function onLaunch_63() if filtered[63] then launchGame(filtered[63].id) end end
function onLaunch_64() if filtered[64] then launchGame(filtered[64].id) end end
function onLaunch_65() if filtered[65] then launchGame(filtered[65].id) end end
function onLaunch_66() if filtered[66] then launchGame(filtered[66].id) end end
function onLaunch_67() if filtered[67] then launchGame(filtered[67].id) end end
function onLaunch_68() if filtered[68] then launchGame(filtered[68].id) end end
function onLaunch_69() if filtered[69] then launchGame(filtered[69].id) end end
function onLaunch_70() if filtered[70] then launchGame(filtered[70].id) end end
function onLaunch_71() if filtered[71] then launchGame(filtered[71].id) end end
function onLaunch_72() if filtered[72] then launchGame(filtered[72].id) end end
function onLaunch_73() if filtered[73] then launchGame(filtered[73].id) end end
function onLaunch_74() if filtered[74] then launchGame(filtered[74].id) end end
function onLaunch_75() if filtered[75] then launchGame(filtered[75].id) end end
function onLaunch_76() if filtered[76] then launchGame(filtered[76].id) end end
function onLaunch_77() if filtered[77] then launchGame(filtered[77].id) end end
function onLaunch_78() if filtered[78] then launchGame(filtered[78].id) end end
function onLaunch_79() if filtered[79] then launchGame(filtered[79].id) end end
function onLaunch_80() if filtered[80] then launchGame(filtered[80].id) end end
function onLaunch_81() if filtered[81] then launchGame(filtered[81].id) end end
function onLaunch_82() if filtered[82] then launchGame(filtered[82].id) end end
function onLaunch_83() if filtered[83] then launchGame(filtered[83].id) end end
function onLaunch_84() if filtered[84] then launchGame(filtered[84].id) end end
function onLaunch_85() if filtered[85] then launchGame(filtered[85].id) end end
function onLaunch_86() if filtered[86] then launchGame(filtered[86].id) end end
function onLaunch_87() if filtered[87] then launchGame(filtered[87].id) end end
function onLaunch_88() if filtered[88] then launchGame(filtered[88].id) end end
function onLaunch_89() if filtered[89] then launchGame(filtered[89].id) end end
function onLaunch_90() if filtered[90] then launchGame(filtered[90].id) end end
function onLaunch_91() if filtered[91] then launchGame(filtered[91].id) end end
function onLaunch_92() if filtered[92] then launchGame(filtered[92].id) end end
function onLaunch_93() if filtered[93] then launchGame(filtered[93].id) end end
function onLaunch_94() if filtered[94] then launchGame(filtered[94].id) end end
function onLaunch_95() if filtered[95] then launchGame(filtered[95].id) end end
function onLaunch_96() if filtered[96] then launchGame(filtered[96].id) end end
function onLaunch_97() if filtered[97] then launchGame(filtered[97].id) end end
function onLaunch_98() if filtered[98] then launchGame(filtered[98].id) end end
function onLaunch_99() if filtered[99] then launchGame(filtered[99].id) end end
function onLaunch_100() if filtered[100] then launchGame(filtered[100].id) end end
function onLaunch_101() if filtered[101] then launchGame(filtered[101].id) end end
function onLaunch_102() if filtered[102] then launchGame(filtered[102].id) end end
function onLaunch_103() if filtered[103] then launchGame(filtered[103].id) end end
function onLaunch_104() if filtered[104] then launchGame(filtered[104].id) end end
function onLaunch_105() if filtered[105] then launchGame(filtered[105].id) end end
function onLaunch_106() if filtered[106] then launchGame(filtered[106].id) end end
function onLaunch_107() if filtered[107] then launchGame(filtered[107].id) end end
function onLaunch_108() if filtered[108] then launchGame(filtered[108].id) end end
function onLaunch_109() if filtered[109] then launchGame(filtered[109].id) end end
function onLaunch_110() if filtered[110] then launchGame(filtered[110].id) end end
function onLaunch_111() if filtered[111] then launchGame(filtered[111].id) end end
function onLaunch_112() if filtered[112] then launchGame(filtered[112].id) end end
function onLaunch_113() if filtered[113] then launchGame(filtered[113].id) end end
function onLaunch_114() if filtered[114] then launchGame(filtered[114].id) end end
function onLaunch_115() if filtered[115] then launchGame(filtered[115].id) end end
function onLaunch_116() if filtered[116] then launchGame(filtered[116].id) end end
function onLaunch_117() if filtered[117] then launchGame(filtered[117].id) end end
function onLaunch_118() if filtered[118] then launchGame(filtered[118].id) end end
function onLaunch_119() if filtered[119] then launchGame(filtered[119].id) end end
function onLaunch_120() if filtered[120] then launchGame(filtered[120].id) end end
function onLaunch_121() if filtered[121] then launchGame(filtered[121].id) end end
function onLaunch_122() if filtered[122] then launchGame(filtered[122].id) end end
function onLaunch_123() if filtered[123] then launchGame(filtered[123].id) end end
function onLaunch_124() if filtered[124] then launchGame(filtered[124].id) end end
function onLaunch_125() if filtered[125] then launchGame(filtered[125].id) end end
function onLaunch_126() if filtered[126] then launchGame(filtered[126].id) end end
function onLaunch_127() if filtered[127] then launchGame(filtered[127].id) end end
function onLaunch_128() if filtered[128] then launchGame(filtered[128].id) end end
function onLaunch_129() if filtered[129] then launchGame(filtered[129].id) end end
function onLaunch_130() if filtered[130] then launchGame(filtered[130].id) end end
function onLaunch_131() if filtered[131] then launchGame(filtered[131].id) end end
function onLaunch_132() if filtered[132] then launchGame(filtered[132].id) end end
function onLaunch_133() if filtered[133] then launchGame(filtered[133].id) end end
function onLaunch_134() if filtered[134] then launchGame(filtered[134].id) end end
function onLaunch_135() if filtered[135] then launchGame(filtered[135].id) end end
function onLaunch_136() if filtered[136] then launchGame(filtered[136].id) end end
function onLaunch_137() if filtered[137] then launchGame(filtered[137].id) end end
function onLaunch_138() if filtered[138] then launchGame(filtered[138].id) end end
function onLaunch_139() if filtered[139] then launchGame(filtered[139].id) end end
function onLaunch_140() if filtered[140] then launchGame(filtered[140].id) end end
function onLaunch_141() if filtered[141] then launchGame(filtered[141].id) end end
function onLaunch_142() if filtered[142] then launchGame(filtered[142].id) end end
function onLaunch_143() if filtered[143] then launchGame(filtered[143].id) end end
function onLaunch_144() if filtered[144] then launchGame(filtered[144].id) end end
function onLaunch_145() if filtered[145] then launchGame(filtered[145].id) end end
function onLaunch_146() if filtered[146] then launchGame(filtered[146].id) end end
function onLaunch_147() if filtered[147] then launchGame(filtered[147].id) end end
function onLaunch_148() if filtered[148] then launchGame(filtered[148].id) end end
function onLaunch_149() if filtered[149] then launchGame(filtered[149].id) end end
function onLaunch_150() if filtered[150] then launchGame(filtered[150].id) end end
function onLaunch_151() if filtered[151] then launchGame(filtered[151].id) end end
function onLaunch_152() if filtered[152] then launchGame(filtered[152].id) end end
function onLaunch_153() if filtered[153] then launchGame(filtered[153].id) end end
function onLaunch_154() if filtered[154] then launchGame(filtered[154].id) end end
function onLaunch_155() if filtered[155] then launchGame(filtered[155].id) end end
function onLaunch_156() if filtered[156] then launchGame(filtered[156].id) end end
function onLaunch_157() if filtered[157] then launchGame(filtered[157].id) end end
function onLaunch_158() if filtered[158] then launchGame(filtered[158].id) end end
function onLaunch_159() if filtered[159] then launchGame(filtered[159].id) end end
function onLaunch_160() if filtered[160] then launchGame(filtered[160].id) end end
function onLaunch_161() if filtered[161] then launchGame(filtered[161].id) end end
function onLaunch_162() if filtered[162] then launchGame(filtered[162].id) end end
function onLaunch_163() if filtered[163] then launchGame(filtered[163].id) end end
function onLaunch_164() if filtered[164] then launchGame(filtered[164].id) end end
function onLaunch_165() if filtered[165] then launchGame(filtered[165].id) end end
function onLaunch_166() if filtered[166] then launchGame(filtered[166].id) end end
function onLaunch_167() if filtered[167] then launchGame(filtered[167].id) end end
function onLaunch_168() if filtered[168] then launchGame(filtered[168].id) end end
function onLaunch_169() if filtered[169] then launchGame(filtered[169].id) end end
function onLaunch_170() if filtered[170] then launchGame(filtered[170].id) end end
function onLaunch_171() if filtered[171] then launchGame(filtered[171].id) end end
function onLaunch_172() if filtered[172] then launchGame(filtered[172].id) end end
function onLaunch_173() if filtered[173] then launchGame(filtered[173].id) end end
function onLaunch_174() if filtered[174] then launchGame(filtered[174].id) end end
function onLaunch_175() if filtered[175] then launchGame(filtered[175].id) end end
function onLaunch_176() if filtered[176] then launchGame(filtered[176].id) end end
function onLaunch_177() if filtered[177] then launchGame(filtered[177].id) end end
function onLaunch_178() if filtered[178] then launchGame(filtered[178].id) end end
function onLaunch_179() if filtered[179] then launchGame(filtered[179].id) end end
function onLaunch_180() if filtered[180] then launchGame(filtered[180].id) end end
function onLaunch_181() if filtered[181] then launchGame(filtered[181].id) end end
function onLaunch_182() if filtered[182] then launchGame(filtered[182].id) end end
function onLaunch_183() if filtered[183] then launchGame(filtered[183].id) end end
function onLaunch_184() if filtered[184] then launchGame(filtered[184].id) end end
function onLaunch_185() if filtered[185] then launchGame(filtered[185].id) end end
function onLaunch_186() if filtered[186] then launchGame(filtered[186].id) end end
function onLaunch_187() if filtered[187] then launchGame(filtered[187].id) end end
function onLaunch_188() if filtered[188] then launchGame(filtered[188].id) end end
function onLaunch_189() if filtered[189] then launchGame(filtered[189].id) end end
function onLaunch_190() if filtered[190] then launchGame(filtered[190].id) end end
function onLaunch_191() if filtered[191] then launchGame(filtered[191].id) end end
function onLaunch_192() if filtered[192] then launchGame(filtered[192].id) end end
function onLaunch_193() if filtered[193] then launchGame(filtered[193].id) end end
function onLaunch_194() if filtered[194] then launchGame(filtered[194].id) end end
function onLaunch_195() if filtered[195] then launchGame(filtered[195].id) end end
function onLaunch_196() if filtered[196] then launchGame(filtered[196].id) end end
function onLaunch_197() if filtered[197] then launchGame(filtered[197].id) end end
function onLaunch_198() if filtered[198] then launchGame(filtered[198].id) end end
function onLaunch_199() if filtered[199] then launchGame(filtered[199].id) end end
function onLaunch_200() if filtered[200] then launchGame(filtered[200].id) end end

function onOpen(context)
  if #games == 0 then
    scanGames()
    return
  end
  for _, g in ipairs(games) do
    if (g.runner == "steam" or g.runner == "heroic") and (not g.cover or #g.cover == 0) then
      scanGames()
      return
    end
  end
  filtered = games
  render()
end

function onClose()
  panel.close()
end

function onRescan()
  scanGames()
end

function onSearch(value)
  searchText = value or ""
  filterGames(searchText)
  render()
end
