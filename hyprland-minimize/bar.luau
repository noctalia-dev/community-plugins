--!nonstrict
-- Bar widget: minimized windows.
--   * Long bar: a row with one button per window (icon + title); a click restores it.
--   * Short or vertical bar: a single button with the count; it opens the panel with the list.
-- The data comes from the service (service.luau) through the shared state "windows".

local windows = {}
local render  -- declared further down

local function decode(value)
  if type(value) ~= "string" or value == "" then return {} end
  local data = noctalia.json.decode(value)
  if type(data) == "table" then return data end
  return {}
end

-- Asks the service to run an action. The number makes the state always change so the watcher fires.
local function send(action, address)
  local text = noctalia.json.encode({ action = action, address = address, n = noctalia.nowMs() })
  if text then noctalia.state.set("cmd", text) end
end

local function openPanel()
  noctalia.togglePanel("fr4j4/hyprland-minimize:list")
end

-- Shortens by characters (not bytes), so accented letters are not split.
local function shorten(text, max)
  if type(text) ~= "string" then return "" end
  local ok, len = pcall(utf8.len, text)
  if ok and len and len > max then
    local cut = utf8.offset(text, max)
    if cut then return string.sub(text, 1, cut - 1) .. "…" end
  end
  return text
end

-- Logical width of each monitor (Noctalia reports the unrotated mode size; a monitor rotated 90° is narrower).
local monitorWidth = {}

local function fetchMonitors()
  noctalia.runAsync({ "hyprctl", "monitors", "-j" }, function(res)
    if res.exitCode ~= 0 then return end
    local list = noctalia.json.decode(res.stdout)
    if type(list) ~= "table" then return end
    local changed = false
    for _, m in ipairs(list) do
      local w, h = m.width or 0, m.height or 0
      local rotated = ((m.transform or 0) % 2) == 1
      local logical = (rotated and h or w) / (m.scale or 1)
      if monitorWidth[m.name] ~= logical then
        monitorWidth[m.name] = logical
        changed = true
      end
    end
    if changed then render() end
  end, 3000)
end

local function isCompact()
  local mode = noctalia.getConfig("mode") or "auto"
  if mode == "button" then return true end
  if mode == "list" then return false end
  if barWidget.isVertical() then return true end
  local name = barWidget.outputName()
  local w = name and monitorWidth[name]
  if w then return w < 1500 end
  for _, o in ipairs(noctalia.outputs()) do
    if o.name == name then return o.width < 1500 end
  end
  return false
end

local function iconFor(cls)
  local path = cls ~= "" and noctalia.appIconPath(cls, 20) or nil
  if path then
    return ui.image({ path = path, width = 18, height = 18, fit = "contain" })
  end
  return ui.glyph({ name = "app-window", size = 15, color = "on_surface_variant" })
end

render = function()
  local count = #windows
  local hideEmpty = noctalia.getConfig("hide_when_empty") ~= false

  if count == 0 and hideEmpty then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local container = barWidget.isVertical() and ui.column or ui.row

  if count == 0 or isCompact() then
    barWidget.render(container({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "arrows-diagonal-minimize-2",
        glyphSize = 14,
        text = count > 0 and tostring(count) or nil,
        variant = "ghost",
        tooltip = noctalia.trp("widget.tooltip", count),
        onClick = openPanel,
      }),
    }))
    return
  end

  local maxItems = tonumber(noctalia.getConfig("max_items")) or 5
  local showTitles = noctalia.getConfig("show_titles") ~= false
  local children = {}

  for i, w in ipairs(windows) do
    if i > maxItems then break end
    local addr = w.address
    local label = w.title ~= "" and w.title or w.class
    local content = { iconFor(w.class) }
    if showTitles then
      table.insert(content, ui.label({
        text = shorten(label, 18),
        color = "on_surface",
        fontSize = 12,
      }))
    end
    table.insert(children, ui.row({
      key = addr,
      gap = 6,
      align = "center",
      paddingH = 8,
      paddingV = 3,
      radius = 10,
      fill = "on_surface/0.09",
      tooltip = label,
      onClick = function() send("restore", addr) end,
    }, content))
  end

  if count > maxItems then
    table.insert(children, ui.button({
      key = "more",
      text = "+" .. tostring(count - maxItems),
      variant = "ghost",
      tooltip = noctalia.tr("widget.more"),
      onClick = openPanel,
    }))
  end

  barWidget.render(container({ gap = 6, align = "center" }, children))
end

noctalia.state.watch("windows", function(value)
  windows = decode(value)
  render()
end)

function update()
  noctalia.setUpdateInterval(5000)
  windows = decode(noctalia.state.get("windows"))
  fetchMonitors()
  render()
end
