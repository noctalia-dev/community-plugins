--!nonstrict

local helper = noctalia.pluginDir() .. "/spotify_backend.py"

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

local function failureResult(query, title, detail)
  launcher.setResults(query, {
    {
      id = "error",
      title = title,
      subtitle = detail,
      glyph = "alert-triangle",
    },
  })
end

function onQuery(text)
  local query = noctalia.string.trim(text)
  if query == "" then
    launcher.setResults(text, {
      {
        id = "hint",
        title = "Type a Spotify search",
        subtitle = "Enter a song, artist, or album after /sp",
        query = " ",
        glyph = "brand-spotify",
      },
    })
    return
  end

  launcher.setResults(text, {
    {
      id = "loading",
      title = "Searching Spotify…",
      subtitle = query,
      glyph = "loader",
    },
  })

  local command = "python3 " .. shellQuote(helper) .. " search " .. shellQuote(query)
  local accepted = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      local detail = noctalia.string.trim(result.stderr)
      if detail == "" then
        detail = "Spotify did not return search results."
      end
      failureResult(text, "Spotify search failed", detail)
      return
    end

    local payload, decodeError = noctalia.json.decode(result.stdout)
    if payload == nil then
      failureResult(text, "Spotify search failed", decodeError or "Invalid response")
      return
    end

    local results = {}
    for _, item in ipairs(payload) do
      table.insert(results, {
        id = item.id,
        title = item.title,
        subtitle = item.subtitle,
        icon = item.icon,
        glyph = "brand-spotify",
      })
    end

    if #results == 0 then
      table.insert(results, {
        id = "empty",
        title = "No Spotify tracks found",
        subtitle = query,
        glyph = "search-off",
      })
    end
    launcher.setResults(text, results)
  end)

  if not accepted then
    failureResult(text, "Spotify search unavailable", "Could not start the search helper.")
  end
end

function onActivate(id)
  if id == "hint" or id == "loading" or id == "empty" or id == "error" then
    return
  end
  if string.match(id, "^[%w]+$") == nil then
    noctalia.notifyError("Spotify playback failed", "Invalid track identifier.")
    return
  end

  local command = "python3 " .. shellQuote(helper) .. " play " .. shellQuote(id)
  local accepted = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      local detail = noctalia.string.trim(result.stderr)
      if detail == "" then
        detail = "Spotify could not start this track."
      end
      noctalia.notifyError("Spotify playback failed", detail)
    end
  end)
  if not accepted then
    noctalia.notifyError("Spotify playback failed", "Could not start the playback helper.")
  end
end
