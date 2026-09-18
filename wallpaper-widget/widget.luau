local function tr(key, args)
  return noctalia.tr(key, args)
end

local function getCurrentWallpaper()
  if noctalia.wallpaperPath then
    local out = noctalia.focusedOutputName and noctalia.focusedOutputName()
    if out then
      local path = noctalia.wallpaperPath(out)
      if path and path ~= "" then return path end
    end
    if noctalia.outputs then
      for _, o in ipairs(noctalia.outputs()) do
        if o.name then
          local path = noctalia.wallpaperPath(o.name)
          if path and path ~= "" then return path end
        end
      end
    end
  end
  return nil
end

local function updateTooltip()
  local current = ""
  local active = getCurrentWallpaper()
  if active and active ~= "" then
    current = active:match("([^/]+)$") or active
  end
  barWidget.setTooltip({
    { key = tr("panel.title"), value = current ~= "" and current or tr("widget.open") },
    { key = tr("widget.click"), value = tr("widget.toggle_panel") },
    { key = tr("widget.scroll"), value = tr("widget.scroll_hint") },
    { key = tr("widget.right_click"), value = tr("widget.random_hint") },
  })
end

function update()
  barWidget.setGlyph("image")
  updateTooltip()
end

function onClick()
  noctalia.togglePanel("ashur-d/wallpaper-widget:hub")
end

function onRightClick()
  noctalia.runAsync("noctalia msg wallpaper-random", function()
    if noctalia.getConfig("notify_on_change") ~= false then
      local active = getCurrentWallpaper()
      local fname = active and (active:match("([^/]+)$") or active) or ""
      if fname ~= "" then
        noctalia.notify(tr("panel.title"), tr("notify.switched") .. ": " .. fname)
      else
        noctalia.notify(tr("panel.title"), tr("notify.switched"))
      end
    end
    updateTooltip()
  end)
end

local lastScrollTime = 0

function onScroll(axis, steps, _startsGesture)
  if axis ~= "vertical" then return end
  local now = os.clock()
  if now - lastScrollTime < 0.12 then
    return
  end
  lastScrollTime = now

  if (steps or 0) > 0 then
    noctalia.runAsync("noctalia msg wallpaper-next", function()
      updateTooltip()
    end)
  else
    noctalia.runAsync("noctalia msg wallpaper-previous", function()
      updateTooltip()
    end)
  end
end

barWidget.setGlyph("image")
updateTooltip()
