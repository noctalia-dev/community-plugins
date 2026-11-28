--!nonstrict
-- EncoBuds bar widget.
--
-- Renders the snapshot published by the service: a mode-dependent glyph plus
-- the listening mode and the lowest earbud battery. Left click opens the
-- panel, right click cycles the listening mode, and the wheel cycles once per
-- gesture when `scroll_cycle` is enabled. No Bluetooth work happens here.

local MODE_SHORT_KEY = {
  [0] = "mode.short.off",
  [1] = "mode.short.anc",
  [2] = "mode.short.trans",
  [3] = "mode.short.off",
  [4] = "mode.short.deep",
  [5] = "mode.short.mid",
  [6] = "mode.short.light",
  [7] = "mode.short.smart",
  [8] = "mode.short.trans",
  [9] = "mode.short.trans",
}

local MODE_FULL_KEY = {
  [0] = "mode.off",
  [1] = "mode.anc",
  [2] = "mode.trans",
  [3] = "mode.off",
  [4] = "mode.deep",
  [5] = "mode.mid",
  [6] = "mode.light",
  [7] = "mode.smart",
  [8] = "mode.trans",
  [9] = "mode.trans",
}

local snapshot = nil

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function decode(encoded)
  if encoded == nil then
    return nil
  end
  local value = noctalia.json.decode(encoded)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local function modeFamily(mode)
  if mode == 0 or mode == 3 then
    return "off"
  end
  if mode == 2 or mode == 8 or mode == 9 then
    return "trans"
  end
  return "anc"
end

-- Lowest of left/right (what a single battery number should mean); falls back
-- to the case, then to either bud.
local function batteryLevel(st)
  local batt = st.battery or {}
  local left, right, case = batt.left, batt.right, batt.case
  local level
  if left and right then
    level = math.min(left.level or 100, right.level or 100)
  elseif left then
    level = left.level
  elseif right then
    level = right.level
  elseif case then
    level = case.level
  end
  return level
end

local function batteryTooltip(st)
  local rows = {}
  local batt = st.battery or {}
  for _, item in ipairs({
    { key = "left", label = "battery.left" },
    { key = "right", label = "battery.right" },
    { key = "case", label = "battery.case" },
  }) do
    local value = batt[item.key]
    if value ~= nil and value.level ~= nil then
      rows[#rows + 1] = {
        key = tr(item.label),
        value = tostring(value.level) .. "%" .. (value.charging and " ⚡" or ""),
      }
    end
  end
  return rows
end

local function render()
  local st = snapshot
  local phase = st and st.phase or "loading"
  local online = phase == "online"

  if not online and noctalia.getConfig("hide_when_offline") == true then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local family = online and modeFamily(st.mode) or phase
  local glyph = ({
    anc = "headphones",
    trans = "ear",
    off = "headphones-off",
    loading = "headphones",
    offline = "bluetooth-off",
    error = "bluetooth-x",
  })[family] or "headphones"
  local color = ({
    anc = "primary",
    trans = "tertiary",
    off = "on_surface/0.6",
    loading = "on_surface/0.5",
    offline = "on_surface/0.45",
    error = "error",
  })[family] or "on_surface"

  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(color)

  local parts = {}
  if online then
    if noctalia.getConfig("show_mode") ~= false and st.mode ~= nil then
      local key = MODE_SHORT_KEY[st.mode]
      if key ~= nil then
        parts[#parts + 1] = tr(key)
      end
    end
    if noctalia.getConfig("show_battery") ~= false then
      local level = batteryLevel(st)
      if level ~= nil then
        parts[#parts + 1] = tostring(level) .. "%"
      end
    end
  else
    parts[#parts + 1] = phase == "loading" and tr("bar.loading") or tr("bar.offline")
  end
  barWidget.setText(table.concat(parts, " "))

  if online then
    local modeKey = st.mode ~= nil and MODE_FULL_KEY[st.mode] or nil
    local rows = {
      { key = tr("tooltip.mode"), value = modeKey and tr(modeKey) or "?" },
    }
    for _, row in ipairs(batteryTooltip(st)) do
      rows[#rows + 1] = row
    end
    rows[#rows + 1] = {
      key = tr("tooltip.game"),
      value = st.game == true and tr("on") or st.game == false and tr("off") or "?",
    }
    if st.product ~= nil then
      rows[#rows + 1] = { key = tr("tooltip.model"), value = tostring(st.product) }
    end
    if noctalia.getConfig("scroll_cycle") ~= false then
      rows[#rows + 1] = { key = tr("tooltip.hint"), value = tr("tooltip.scroll") }
    end
    barWidget.setTooltip(rows)
  else
    local message = st and st.error or tr("status.loading")
    barWidget.setTooltip({ { key = tr("title"), value = tostring(message) } })
  end
end

noctalia.state.watch("encobuds.state", function(encoded)
  snapshot = decode(encoded)
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  if snapshot == nil then
    snapshot = decode(noctalia.state.get("encobuds.state"))
  end
  render()
end

-- Fallback for instances whose left action was cleared. A declared [widget.actions]
-- binding takes precedence, so this normally does not run.
function onClick()
  noctalia.togglePanel("fish/encobuds:panel")
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or steps == 0 then
    return
  end
  -- One action per wheel/touchpad gesture; touchpads otherwise emit a burst
  -- of steps that would cycle through every mode at once.
  if not startsGesture then
    return
  end
  if snapshot == nil or snapshot.phase ~= "online" then
    return
  end
  if noctalia.getConfig("scroll_cycle") == false then
    return
  end
  noctalia.state.set("encobuds.cmd", noctalia.json.encode({
    n = noctalia.nowMs(),
    action = "cycle",
  }))
end
