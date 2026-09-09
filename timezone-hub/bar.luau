--!nonstrict
-- Timezone Hub bar widget — shows the device's local time (or, if chosen
-- in the panel, a comparison city's time instead) with its zone
-- abbreviation. Click opens the panel.

local rows = {}
local DEVICE_BAR_KEY = "__device__"
local barTzs = { DEVICE_BAR_KEY }

local function findRow(tz)
  if tz == DEVICE_BAR_KEY then return rows[1] end
  for _, row in ipairs(rows) do
    if row.tz == tz then
      return row
    end
  end
  return nil
end

local function render()
  local selectedRows = {}
  for _, zone in ipairs(barTzs) do
    local row = findRow(zone)
    if row ~= nil then table.insert(selectedRows, row) end
  end
  if #selectedRows == 0 and rows[1] ~= nil then
    table.insert(selectedRows, rows[1])
  end
  if #selectedRows == 0 then
    barWidget.setGlyph("world")
    barWidget.setText("--:--")
    return
  end

  barWidget.setGlyph("world")
  local segments = {}
  for _, row in ipairs(selectedRows) do
    local label = row.tz and row.tz:match(".*/(.*)$") or nil
    label = (label or row.label or "Time"):gsub("_", " ")
    local segment = label
    if noctalia.getConfig("show_date_in_bar") ~= false
      and row.dateText and row.dateText ~= ""
    then
      segment = segment .. " " .. row.dateText
    end
    segment = segment .. " " .. (row.timeText or "--:--")
    table.insert(segments, segment)
  end
  barWidget.setText(table.concat(segments, " · "))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("ahmedhossamdev/timezone-hub:panel")
end

noctalia.state.watch("timezone_hub.rows", function(value)
  rows = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("timezone_hub.bar_tzs", function(value)
  barTzs = type(value) == "table" and value or { DEVICE_BAR_KEY }
  render()
end)

render()
