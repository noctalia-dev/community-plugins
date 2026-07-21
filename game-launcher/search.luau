local games = {}
local ready = false
local binary = noctalia.pluginDir() .. "/gamelauncher"
local cSource = noctalia.pluginDir() .. "/gamelauncher.c"

local function ensureGames(cb)
  local function runScan()
    local ok = noctalia.runAsync(binary .. " --steam --lutris --heroic --force", function(res)
      if res.exitCode == 0 and res.stdout and #res.stdout > 0 then
        local parsed, err = noctalia.json.decode(res.stdout)
        if parsed then
          games = parsed
          ready = true
        end
      end
      cb()
    end)
    if not ok then cb() end
  end
  if ready then
    cb()
    return
  end
  if not noctalia.fileExists(binary) then
    local ok = noctalia.runAsync("/usr/bin/cc -o " .. binary .. " " .. cSource .. " -lsqlite3", function(res)
      if res.exitCode == 0 then
        runScan()
      else
        cb()
      end
    end)
    if not ok then cb() end
    return
  end
  runScan()
end

function onQuery(text)
  if text == "" then
    launcher.setResults(text, {
      { id = "hint", title = "Type a game name to search", glyph = "device-gamepad-2" },
    })
    return
  end
  ensureGames(function()
    local lower = text:lower()
    local results = {}
    for _, g in ipairs(games) do
      if g.name:lower():find(lower, 1, true) then
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
    launcher.setResults(text, results)
  end)
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
  for _, g in ipairs(games) do
    if g.id == id and g.run_command and #g.run_command > 0 and isValidProtocol(g.run_command) then
      noctalia.runAsync('xdg-open "' .. g.run_command .. '"')
      return
    end
  end
end
