local games = {}
local lastQuery = ""

local function statusRow(title, subtitle, glyph)
  return { id = "", title = title, subtitle = subtitle, glyph = glyph }
end

local function isRunnerEnabled(runner)
  local ok, val = pcall(noctalia.getConfig, runner .. "_enabled")
  if ok and val ~= nil then return val == true or val == "true" end
  return true
end

local function loadGames()
  local ok, v = pcall(noctalia.state.get, "games")
  if ok and type(v) == "table" and #v > 0 then
    games = v
    return true
  end
  local base = noctalia.getenv("XDG_CACHE_HOME")
  if not base or #base == 0 then
    local home = noctalia.getenv("HOME") or ""
    base = home .. "/.cache"
  end
  local raw = noctalia.readFile(base .. "/gamelauncher/games.json")
  if raw then
    local parsed = noctalia.json.decode(raw)
    if type(parsed) == "table" and #parsed > 0 then
      games = parsed
      return true
    end
  end
  return false
end

local function filterRows(text)
  local lower = noctalia.string.trim(text):lower()
  local results = {}
  for _, g in ipairs(games) do
    if g.name and g.runner and g.name:lower():find(lower, 1, true) and isRunnerEnabled(g.runner) then
      local meta = { steam = { glyph = "brand-steam", color = "steam" }, lutris = { glyph = "device-gamepad", color = "warning" }, heroic = { glyph = "app-window", color = "heroic" } }
      local m = meta[g.runner] or { glyph = "app-window", color = "on_surface" }
      table.insert(results, {
        id = g.id,
        title = g.name,
        subtitle = "Launch via " .. g.runner,
        glyph = m.glyph,
      })
    end
  end
  if #results == 0 then
    if #games == 0 then
      return {
        statusRow("No games found", "Open the Game Launcher panel to scan your games first.", "app-window"),
      }
    end
    return {
      statusRow("No games found", "Nothing matches \"" .. text .. "\". Try a different name.", "app-window"),
    }
  end
  return results
end

pcall(function()
  noctalia.state.watch("games", function(v)
    if type(v) == "table" then
      games = v
      if lastQuery ~= "" then
        launcher.setResults(lastQuery, filterRows(lastQuery))
      end
    end
  end)
end)

function onQuery(text)
  lastQuery = text
  if text == "" then
    launcher.setResults(text, {
      statusRow("Type a game name to search", "Searches Steam, Lutris, and Heroic.", "device-gamepad-2"),
    })
    return
  end
  if not loadGames() then
    launcher.setResults(text, {
      statusRow("No games loaded", "Open the Game Launcher panel first so it can scan your games.", "device-gamepad-2"),
    })
    return
  end
  launcher.setResults(text, filterRows(text))
end

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

function onActivate(id)
  if id == "" then return end
  for _, g in ipairs(games) do
    if g.id == id and g.run_command and #g.run_command > 0 and isValidProtocol(g.run_command) then
      noctalia.runAsync('xdg-open "' .. g.run_command .. '"')
      return
    end
  end
end
