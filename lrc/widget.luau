noctalia.setUpdateInterval(300)

local fetching = false
local mpdPlayer = "mpd"
local showSeparator = noctalia.getConfig("show_separator") ~= false
local separator = noctalia.getConfig("separator") or "| "

noctalia.runAsync("playerctl -l 2>/dev/null", function(r)
  if r.exitCode == 0 then
    for name in r.stdout:gmatch("[^\n]+") do
      if name:match("^mpd%.") then
        mpdPlayer = name
        break
      end
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
        local prefix = ""
        if showSeparator then
          prefix = separator
        end
        barWidget.setText(prefix .. text)
        return
      end
    end
    barWidget.setText("")
  end,30000)
end
