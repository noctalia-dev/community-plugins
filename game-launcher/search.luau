local games = {}
local lastQuery = ""
local cmdById = {}

local recent = require("./recent.luau")

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

local runnerMeta = {
  steam = { glyph = "brand-steam", color = "steam" },
  lutris = { glyph = "device-gamepad", color = "warning" },
  heroic = { glyph = "app-window", color = "heroic" },
}

local function makeRow(g, score)
  local m = runnerMeta[g.runner] or { glyph = "app-window", color = "on_surface" }
  if g.run_command and #g.run_command > 0 then
    cmdById[g.id] = g.run_command
  end
  local row = {
    id = g.id,
    title = g.name,
    subtitle = "Launch via " .. g.runner,
    glyph = m.glyph,
  }
  if score ~= nil then
    row.score = score
  end
  return row
end

-- Browse mode (empty query, like web-launcher): list every enabled game.
local function allRows()
  local results = {}
  for _, g in ipairs(games) do
    if g.name and g.runner and isRunnerEnabled(g.runner) then
      table.insert(results, makeRow(g))
    end
  end
  table.sort(results, function(a, b)
    return a.title:lower() < b.title:lower()
  end)
  recent.sortByRecent(results)
  return results
end

local function filterRows(text)
  local query = noctalia.string.trim(text)
  if query == "" then
    return allRows()
  end
  local results = {}
  for _, g in ipairs(games) do
    if g.name and g.runner and isRunnerEnabled(g.runner) then
      local score
      if noctalia.fuzzyScore then
        score = noctalia.fuzzyScore(query, g.name)
      elseif g.name:lower():find(query:lower(), 1, true) then
        score = 1
      end
      if score then
        table.insert(results, makeRow(g, score))
      end
    end
  end
  table.sort(results, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  return results
end

pcall(function()
  noctalia.state.watch("games", function(v)
    if type(v) == "table" then
      games = v
      launcher.setResults(lastQuery, filterRows(lastQuery))
    end
  end)
end)

function onQuery(text)
  lastQuery = text
  if not loadGames() then
    launcher.setResults(text, {})
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
  -- Prefer the command captured when the row was built: the games table
  -- may be stale or unloaded in this VM by activation time.
  local cmd = cmdById[id]
  if not cmd then
    for _, g in ipairs(games) do
      if g.id == id and g.run_command and #g.run_command > 0 then
        cmd = g.run_command
        break
      end
    end
  end
  if not cmd and loadGames() then
    for _, g in ipairs(games) do
      if g.id == id and g.run_command and #g.run_command > 0 then
        cmd = g.run_command
        break
      end
    end
  end
  if cmd and isValidProtocol(cmd) then
    recent.record(id)
    noctalia.runAsync('xdg-open "' .. cmd .. '"')
  else
    noctalia.log("game-launcher: cannot launch id " .. tostring(id))
  end
end
