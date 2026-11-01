-- Shows the current line written by `lyrics-term --export`.
-- Reads the file on every tick; lyrics-term replaces it atomically, so the read is never partial.

local LYRICS_FILE = "~/.cache/lyrics-term/current.txt"

local lastLine = nil
local lastPath = nil

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Replaces a leading "~/" with the home directory from the environment
local function expandHome(path)
  if path:sub(1, 2) == "~/" then
    local home = noctalia.getenv("HOME")
    if home and home ~= "" then
      return home .. path:sub(2)
    end
  end
  return path
end

-- Runs once when the widget loads
barWidget.setGlyph("music")

-- Runs on every tick
function update()
  local path = expandHome(LYRICS_FILE)

  -- Log the path once, so a wrong path is visible in the Noctalia log
  if path ~= lastPath then
    lastPath = path
    noctalia.log("lyrics-bar: reading " .. path)
  end

  local text, err = noctalia.readFile(path)
  if not text then
    if err then
      noctalia.log("lyrics-bar: read failed: " .. tostring(err))
    end
    text = ""
  end

  local line = trim(text)
  if line ~= lastLine then
    lastLine = line
    barWidget.setText(line)
  end
  barWidget.setVisible(line ~= "")
end
