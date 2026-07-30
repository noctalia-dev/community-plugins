noctalia.setUpdateInterval(300)

local fetching = false
local mpdPlayer = "mpd"

noctalia.runAsync("playerctl -l 2>/dev/null | grep '^mpd\\.' | head -1", function(r)
  if r.exitCode == 0 then
    local name = r.stdout:gsub("%s+$", "")
    if #name > 0 then
      mpdPlayer = name
    end
  end
end)

function update()
  if fetching then
    return
  end

  if not noctalia.commandExists("lrc_tty") then
    return
  end

  noctalia.runAsync("playerctl status --player " .. mpdPlayer .. " 2>/dev/null", function(r)
    if r.exitCode == 0 and r.stdout:gsub("%s+$", "") == "Playing" then
      fetchLyrics(mpdPlayer)
      return
    end
    noctalia.runAsync("playerctl status --player spotify 2>/dev/null", function(r2)
      if r2.exitCode == 0 and r2.stdout:gsub("%s+$", "") == "Playing" then
        fetchLyrics("spotify")
        return
      end
      barWidget.setText("")
    end)
  end)
end

function fetchLyrics(player)
  fetching = true

  noctalia.runAsync("lrc_tty --raw --player " .. player, function(r)
    fetching = false

    if r.exitCode == 0 then
      local text = r.stdout:gsub("%s+$", "")
      if #text > 0 and text ~= "(no lyrics)" then
        barWidget.setText("| " .. text)
        return
      end
    end
    barWidget.setText("")
  end,30000)
end
