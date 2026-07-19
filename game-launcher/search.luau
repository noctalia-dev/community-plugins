local games = {}
local ready = false
local binary = noctalia.pluginDir() .. "/gamelauncher"
local cSource = noctalia.pluginDir() .. "/gamelauncher.c"

local function ensureGames(cb)
  if ready then
    cb()
    return
  end
  if not noctalia.fileExists(binary) then
    noctalia.runAsync("cc -o " .. binary .. " " .. cSource .. " -lsqlite3 -lpthread", function(res)
      if res.exitCode == 0 then
        noctalia.runAsync(binary .. " --steam --lutris --heroic 2>/dev/null", function(res2)
          if res2.exitCode == 0 and res2.stdout and #res2.stdout > 0 then
            local parsed, err = noctalia.json.decode(res2.stdout)
            if parsed then
              games = parsed
              ready = true
            end
          end
          cb()
        end)
      else
        cb()
      end
    end)
    return
  end
  noctalia.runAsync(binary .. " --steam --lutris --heroic 2>/dev/null", function(res)
    if res.exitCode == 0 and res.stdout and #res.stdout > 0 then
      local parsed, err = noctalia.json.decode(res.stdout)
      if parsed then
        games = parsed
        ready = true
      end
    end
    cb()
  end)
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

function onActivate(id)
  for _, g in ipairs(games) do
    if g.id == id then
      noctalia.runAsync(g.run_command)
      return
    end
  end
end
