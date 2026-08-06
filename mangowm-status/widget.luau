--!nonstrict
-- Mangowm Status — shows tiling layout icon + letter + keymode when not default

local showText = noctalia.getConfig("show_text")
local notifyChange = noctalia.getConfig("notify_change")
local hideOnDefault = noctalia.getConfig("hide_on_default")

local currentKeymode = "default"
local currentLayoutCode = "T"  -- default tile code

-- Layout display config: glyph + letter + name
local layoutConfig = {
  T  = { glyph = "columns",   letter = "T", name = "tile" },
  S  = { glyph = "menu",      letter = "S", name = "scroller" },
  G  = { glyph = "dashboard", letter = "G", name = "grid" },
  M  = { glyph = "window",    letter = "M", name = "monocle" },
  K  = { glyph = "cards",     letter = "K", name = "deck" },
  CT = { glyph = "layout",    letter = "C", name = "center_tile" },
  RT = { glyph = "columns",   letter = "R", name = "right_tile" },
  VS = { glyph = "menu",      letter = "V", name = "vertical_scroller" },
  VT = { glyph = "columns",   letter = "V", name = "vertical_tile" },
  VG = { glyph = "dashboard", letter = "G", name = "vertical_grid" },
  VK = { glyph = "cards",     letter = "K", name = "vertical_deck" },
  DW = { glyph = "columns",   letter = "D", name = "dwindle" },
  F  = { glyph = "layout",    letter = "F", name = "fair" },
  VF = { glyph = "layout",    letter = "F", name = "vertical_fair" },
}

-- Layout order for cycling (horizontal scroll)
local layoutOrder = { "T", "S", "G", "M", "K", "CT", "RT", "DW", "F" }

local function getLayoutConfig(code)
  local cfg = layoutConfig[code]
  if cfg then return cfg end
  return layoutConfig["T"]  -- fallback to tile
end

-- Extract layout code from mmsg JSON
local function extractLayoutCode(data)
  if type(data) ~= "table" then return nil end

  local allTags = data.all_tags
  if not allTags or type(allTags) ~= "table" then return nil end

  for _, monitorEntry in ipairs(allTags) do
    if type(monitorEntry) == "table" and monitorEntry.tags then
      for _, tag in ipairs(monitorEntry.tags) do
        if type(tag) == "table" and tag.is_active and tag.layout then
          return tag.layout
        end
      end
    end
  end
  return nil
end

-- Re-render the bar widget
local function refreshDisplay()
  local isDefault = currentKeymode == "default"

  if hideOnDefault and isDefault then
    barWidget.setVisible(false)
    return
  else
    barWidget.setVisible(true)
  end

  local cfg = getLayoutConfig(currentLayoutCode)

  local keymodeStr = ""
  if showText and not isDefault then
    keymodeStr = " [" .. currentKeymode .. "]"
  end

  barWidget.setGlyph(cfg.glyph)
  barWidget.setText(cfg.letter .. keymodeStr)
  barWidget.setTooltip("Layout: " .. cfg.name .. " (" .. currentLayoutCode .. ") | Mode: " .. currentKeymode)
end

-- Watch keymode changes
noctalia.runStream("mmsg watch keymode", function(line)
  local ok, data = pcall(noctalia.json.decode, line)
  if ok and data then
    local km = data.keymode or data.mode or data.name
    if km and currentKeymode ~= km then
      currentKeymode = km
      if notifyChange then
        noctalia.notify("Keymode changed", currentKeymode)
      end
      refreshDisplay()
    end
  end
end)

-- Watch tag/layout changes — instant re-render
noctalia.runStream("mmsg watch all-tags", function(line)
  local ok, data = pcall(noctalia.json.decode, line)
  if ok and data then
    local code = extractLayoutCode(data)
    if code and code ~= currentLayoutCode then
      currentLayoutCode = code
      refreshDisplay()
    end
  end
end)

-- Polling fallback
local function pollLayout()
  noctalia.runAsync("mmsg get all-tags", function(result)
    if result.exitCode == 0 and result.stdout then
      local ok, data = pcall(noctalia.json.decode, result.stdout)
      if ok and data then
        local code = extractLayoutCode(data)
        if code then
          currentLayoutCode = code
          refreshDisplay()
        end
      end
    end
  end)
end

pollLayout()

function update()
  -- Watch streams deliver layout/keymode changes in real time; the poll is only
  -- a fallback for when a stream stalls, so keep the rate low (5 s) to avoid
  -- spawning an mmsg subprocess every second.
  noctalia.setUpdateInterval(5000)
  pollLayout()
  refreshDisplay()
end

function onClick()
  noctalia.togglePanel("x0d7x/mangowm-status:layout-picker")
end

-- Cleanup handler
function onExit(_signal)
  noctalia.log("mangowm-status: cleaning up streams")
end

-- Settings change handler
function onConfigChanged()
  showText = noctalia.getConfig("show_text")
  notifyChange = noctalia.getConfig("notify_change")
  hideOnDefault = noctalia.getConfig("hide_on_default")
  refreshDisplay()
  noctalia.log("mangowm-status: config reloaded")
end

-- IPC command handler
function onIpc(event, payload)
  if event == "refresh" then
    pollLayout()
    noctalia.log("mangowm-status: IPC refresh triggered")
  elseif event == "set-layout" and payload then
    local cfg = getLayoutConfig(payload)
    local name = cfg and cfg.name or payload
    noctalia.runAsync("mmsg dispatch setlayout," .. name, function(result)
      if result.exitCode == 0 then
        pollLayout()
        noctalia.log("mangowm-status: layout set to " .. name)
      else
        noctalia.notifyError("Mangowm Status", "Failed to set layout: " .. (result.stderr or "unknown error"))
      end
    end)
  elseif event == "get-status" then
    local cfg = getLayoutConfig(currentLayoutCode)
    local status = {
      layout = currentLayoutCode,
      layout_name = cfg.name,
      keymode = currentKeymode,
    }
    noctalia.log("mangowm-status: " .. noctalia.json.encode(status))
  else
    noctalia.log("mangowm-status: unknown IPC event: " .. event)
  end
end

-- Scroll handler for layout cycling
function onScroll(axis, steps)
  if axis ~= "horizontal" then return end

  -- Find current layout index
  local currentIndex = 1
  for i, code in ipairs(layoutOrder) do
    if code == currentLayoutCode then
      currentIndex = i
      break
    end
  end

  -- Calculate new index
  local newIndex = currentIndex + steps
  if newIndex < 1 then
    newIndex = #layoutOrder
  elseif newIndex > #layoutOrder then
    newIndex = 1
  end

  local newLayoutCode = layoutOrder[newIndex]
  local cfg = getLayoutConfig(newLayoutCode)
  noctalia.runAsync("mmsg dispatch setlayout," .. cfg.name, function(result)
    if result.exitCode == 0 then
      pollLayout()
    end
  end)
end
