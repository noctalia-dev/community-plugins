--!nonstrict
-- Wallpaper Switch: cycle, step, or randomize the wallpaper from a bar widget.
--
-- Gestures (all overridable by the user in the widget's settings):
--   left click / scroll down -> next wallpaper
--   right click / scroll up  -> previous wallpaper
--   middle click             -> random wallpaper
--
-- The widget lists the wallpaper folder for the current theme mode, locates
-- the wallpaper currently applied, and steps through the images using the
-- native Noctalia wallpaper API. The only subprocess is a periodic
-- `noctalia msg wallpaper-get` read that keeps the tooltip in sync with
-- wallpaper changes made outside this widget.

local IMAGE_EXTENSIONS = {
  jpg = true,
  jpeg = true,
  png = true,
  webp = true,
  bmp = true,
  gif = true,
  avif = true,
}

local currentPath = ""

noctalia.setUpdateInterval(30000)

local function fileName(path)
  return path:match("([^/]+)$") or path
end

local function imageFiles(dir)
  local entries = noctalia.listDir(dir)
  if type(entries) ~= "table" then
    return nil
  end

  local files = {}
  for _, name in ipairs(entries) do
    local ext = name:match("%.([%w]+)$")
    if ext ~= nil and IMAGE_EXTENSIONS[ext:lower()] then
      table.insert(files, dir .. "/" .. name)
    end
  end
  table.sort(files)
  return files
end

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph"))
  if noctalia.getConfig("show_name") then
    barWidget.setText(fileName(currentPath))
  else
    barWidget.setText("")
  end
  if currentPath ~= "" then
    barWidget.setTooltip(currentPath)
  end
end

-- Reads the wallpaper currently applied. There is no native read API below
-- plugin API 25, so this shells out to the CLI once per update interval.
local function refreshCurrent()
  noctalia.runAsync("noctalia msg wallpaper-get", function(result)
    if result.exitCode == 0 then
      local path = result.stdout:gsub("%s+$", "")
      if path ~= "" then
        currentPath = path
        render()
      end
    end
  end)
end

local function switchTo(path)
  noctalia.setWallpaper(path)
  currentPath = path
  render()
  if noctalia.getConfig("notify_on_switch") then
    noctalia.notify("Wallpaper Switch", fileName(path))
  end
end

local function pick(direction)
  local dir = noctalia.wallpaperDirectory()
  if dir == nil then
    noctalia.notifyError("Wallpaper Switch", "No wallpaper folder is configured.")
    return
  end

  local files = imageFiles(dir)
  if files == nil or #files == 0 then
    noctalia.notifyError("Wallpaper Switch", "No images found in " .. dir)
    return
  end

  local index = 1
  if currentPath ~= "" then
    for i, path in ipairs(files) do
      if path == currentPath then
        index = i
        break
      end
    end
  end

  local target
  if direction == "random" then
    target = files[math.random(#files)]
  else
    local n = #files
    if direction == "next" then
      target = files[(index % n) + 1]
    else
      target = files[((index - 2) % n) + 1]
    end
  end
  switchTo(target)
end

function update()
  render()
  refreshCurrent()
end

function onClick()
  pick("next")
end

function onRightClick()
  pick("previous")
end

function onMiddleClick()
  pick("random")
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then
    return
  end
  if steps > 0 then
    pick("next")
  else
    pick("previous")
  end
end

function onIpc(event)
  if event == "next" or event == "previous" or event == "random" then
    pick(event)
  end
end

-- Render immediately so the widget shows its glyph before the first update
-- tick, then start tracking the wallpaper that is currently applied.
render()
refreshCurrent()