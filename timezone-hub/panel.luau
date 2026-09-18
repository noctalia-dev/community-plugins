--!nonstrict
-- Timezone Hub panel — device timezone pinned first, then every comparison
-- city: label, live time, UTC offset, delta vs device, and a compact
-- (non-scrolling) hour-offset strip with the current hour highlighted and
-- work hours shaded. A second view is a shared searchable IANA-zone picker,
-- used both to add a comparison city and to change the device timezone.

local DRAG_TYPE = "timezone-hub-city"
local WEEKDAY_NAMES = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local rows = {}
local comparisons = {}
local deviceTz = ""
local changingDeviceTz = false
local DEVICE_BAR_KEY = "__device__"
local barTzs = { DEVICE_BAR_KEY }
local allZones = {}
local allZonesLoaded = false

local view = "list" -- "list" | "picker"
local pickerMode = "add" -- "add" | "device"
local query = ""
local queryKey = 0
local pendingDelete = nil -- tz pending trash confirmation
local hourOffset = 0 -- hours the strip window is shifted from "now" (paging, since ui.scroll has no horizontal mode)

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function rowFor(tz)
  for _, row in ipairs(rows) do
    if row.tz == tz then
      return row
    end
  end
  return nil
end

local function shortLabel(tz)
  local slash = tz:match(".*/(.*)$")
  if slash ~= nil then
    return (slash:gsub("_", " "))
  end
  return tz
end

local function roundHalf(x)
  if x < 0 then
    return -roundHalf(-x)
  end
  return math.floor(x * 2 + 0.5) / 2
end

local function diffLabel(offsetMinutes, deviceOffsetMinutes)
  if offsetMinutes == nil or deviceOffsetMinutes == nil then
    return ""
  end
  local diff = roundHalf((offsetMinutes - deviceOffsetMinutes) / 60)
  if diff == 0 then
    return noctalia.tr("row.same-time")
  end
  return (diff > 0 and "+" or "") .. tostring(diff) .. "h"
end

local function barZoneSelected(key)
  for _, selected in ipairs(barTzs) do
    if selected == key then return true end
  end
  return false
end

local function daysBeforeYear(year)
  local previous = year - 1
  return 365 * previous
    + math.floor(previous / 4)
    - math.floor(previous / 100)
    + math.floor(previous / 400)
end

local function localDateInfo(zone)
  local raw = noctalia.formatTime("%Y|%j|%H", nil, zone)
  local year, day, hour = raw:match("(%d+)|(%d+)|(%d+)")
  if year == nil then return nil end
  return {
    ordinal = daysBeforeYear(tonumber(year)) + tonumber(day),
    hour = tonumber(hour),
  }
end

local function offsetDescription(offsetMinutes, deviceOffsetMinutes)
  if offsetMinutes == nil or deviceOffsetMinutes == nil then return nil end
  local difference = offsetMinutes - deviceOffsetMinutes
  if difference == 0 then return noctalia.tr("relative.same-time") end
  local absolute = math.abs(difference)
  local hours = math.floor(absolute / 60)
  local minutes = absolute % 60
  local amount
  if hours == 0 then
    amount = tostring(minutes) .. "m"
  elseif minutes == 0 then
    amount = tostring(hours) .. "h"
  else
    amount = tostring(hours) .. "h " .. tostring(minutes) .. "m"
  end
  return noctalia.tr(difference > 0 and "relative.ahead" or "relative.behind", { offset = amount })
end

local function relativeDescriptions(row, deviceRow, workStart, workEnd)
  if noctalia.getConfig("show_relative_time") == false then
    local fallback = row.isDevice and "" or diffLabel(row.offsetMinutes, deviceRow and deviceRow.offsetMinutes or nil)
    return fallback ~= "" and { fallback } or {}
  end

  local parts = {}
  if not row.isDevice then
    local offset = offsetDescription(row.offsetMinutes, deviceRow and deviceRow.offsetMinutes or nil)
    if offset ~= nil then table.insert(parts, offset) end
  end

  local here = localDateInfo(row.tz)
  local device = deviceRow and localDateInfo(deviceRow.tz) or nil
  if here ~= nil and device ~= nil then
    local dayDifference = here.ordinal - device.ordinal
    if dayDifference ~= 0 then
      local day
      if dayDifference == -1 then
        day = noctalia.tr("relative.yesterday")
      elseif dayDifference == 1 then
        day = noctalia.tr("relative.tomorrow")
      else
        day = noctalia.tr("relative.day-offset", { days = (dayDifference > 0 and "+" or "") .. tostring(dayDifference) })
      end
      local period
      if here.hour < 5 then
        period = noctalia.tr("relative.night")
      elseif here.hour < 12 then
        period = noctalia.tr("relative.morning")
      elseif here.hour < 17 then
        period = noctalia.tr("relative.afternoon")
      elseif here.hour < 21 then
        period = noctalia.tr("relative.evening")
      else
        period = noctalia.tr("relative.night")
      end
      table.insert(parts, day .. " " .. period)
    end
    table.insert(parts, noctalia.tr(
      here.hour >= workStart and here.hour < workEnd
        and "relative.inside-work-hours"
        or "relative.outside-work-hours"
    ))
  end
  return parts
end

local function flooredHourEpoch()
  return math.floor(math.floor(noctalia.nowMs() / 1000) / 3600) * 3600 + hourOffset * 3600
end

local function cellInfo(zone, colEpoch)
  local raw = noctalia.formatTime("%w|%d|%H", colEpoch, zone)
  local w, d, h = raw:match("(%d+)|(%d+)|(%d+)")
  if w == nil then
    return nil
  end
  return { weekday = tonumber(w), day = tonumber(d), hour = tonumber(h) }
end

local function cellLabel(zone, colEpoch, use24h)
  local info = cellInfo(zone, colEpoch)
  if info == nil then
    return "…"
  end
  if info.hour == 0 then
    return WEEKDAY_NAMES[info.weekday + 1] .. " " .. info.day
  end
  if use24h then
    return tostring(info.hour)
  end
  local h12 = info.hour % 12
  if h12 == 0 then
    h12 = 12
  end
  return tostring(h12)
end

local function cellIsWork(zone, colEpoch, workStart, workEnd)
  local info = cellInfo(zone, colEpoch)
  return info ~= nil and info.hour >= workStart and info.hour < workEnd
end

-- ---------------------------------------------------------------------
-- Drag & drop (comparison rows only)
-- ---------------------------------------------------------------------
local function insertionZone(index)
  return ui.dropZone({
    key = "gap-" .. index,
    accepts = { DRAG_TYPE },
    value = tostring(index),
    onDrop = "onZoneDropped",
    height = 3,
    radius = 4,
    expandOnDrag = true,
    hitSlop = 20,
  })
end

function onZoneDropped(payload, value)
  local insertAt = tonumber(value)
  if type(payload) ~= "string" or payload == "" or insertAt == nil then
    return
  end
  noctalia.state.set("timezone_hub.cmd", { op = "reorder", tz = payload, index = insertAt })
end

-- ---------------------------------------------------------------------
-- Row rendering
-- ---------------------------------------------------------------------
-- The strip gets an explicit pixel budget rather than flexGrow: flexGrow
-- competing against fixed-width siblings (grip/info/actions) in the same
-- row was not reliably claiming its full share, leaving a dead gap before
-- the action buttons. An explicit width, divided evenly among however many
-- columns are configured, is deterministic instead.
local STRIP_WIDTH = 320
local CELL_GAP = 1

local function hourStrip(zone, hoursBefore, hoursAfter, use24h, highlightWork, workStart, workEnd)
  local floored = flooredHourEpoch()
  local columnCount = hoursBefore + hoursAfter + 1
  local cellWidth = (STRIP_WIDTH - (columnCount - 1) * CELL_GAP) / columnCount
  local cells = {}
  for col = -hoursBefore, hoursAfter do
    local isNow = col == -hourOffset
    local cellProps = {
      key = "cell-" .. tostring(col),
      width = cellWidth,
      align = "center",
      justify = "center",
      radius = 3,
    }
    if isNow then
      cellProps.fill = "primary/0.18"
    elseif highlightWork and cellIsWork(zone, floored + col * 3600, workStart, workEnd) then
      cellProps.fill = "on_surface/0.05"
    end
    table.insert(
      cells,
      ui.column(cellProps, {
        ui.label({
          text = cellLabel(zone, floored + col * 3600, use24h),
          fontSize = isNow and 11 or 9,
          fontWeight = isNow and "bold" or "normal",
          color = isNow and "primary" or "on_surface_variant",
          textAlign = "center",
        }),
      })
    )
  end
  return ui.row({ width = STRIP_WIDTH, gap = CELL_GAP }, cells)
end

local ACTION_BUTTON_SIZE = 28

local function rowActions(row, isDeviceRow)
  if not isDeviceRow and pendingDelete == row.tz then
    return {
      ui.button({
        glyph = "check",
        glyphSize = 14,
        variant = "destructive",
        width = ACTION_BUTTON_SIZE,
        height = ACTION_BUTTON_SIZE,
        paddingH = 0,
        paddingV = 0,
        tooltip = noctalia.tr("row.confirm-remove"),
        onClick = function()
          noctalia.state.set("timezone_hub.cmd", { op = "remove", tz = row.tz })
          pendingDelete = nil
        end,
      }),
      ui.button({
        glyph = "close",
        glyphSize = 14,
        variant = "ghost",
        width = ACTION_BUTTON_SIZE,
        height = ACTION_BUTTON_SIZE,
        paddingH = 0,
        paddingV = 0,
        tooltip = noctalia.tr("row.cancel-remove"),
        onClick = function()
          pendingDelete = nil
          render()
        end,
      }),
    }
  end

  local barKey = isDeviceRow and DEVICE_BAR_KEY or row.tz
  local starSelected = barZoneSelected(barKey)
  local actions = {
    ui.button({
      glyph = starSelected and "eye" or "eye-off",
      glyphSize = 14,
      variant = "ghost",
      width = ACTION_BUTTON_SIZE,
      height = ACTION_BUTTON_SIZE,
      paddingH = 0,
      paddingV = 0,
      selected = starSelected,
      tooltip = noctalia.tr(starSelected and "row.hide-from-bar" or "row.show-in-bar"),
      onClick = function()
        noctalia.state.set("timezone_hub.cmd", { op = "toggle_bar_zone", tz = isDeviceRow and "" or row.tz })
      end,
    }),
  }

  if not isDeviceRow then
    table.insert(
      actions,
      ui.button({
        glyph = "pin-filled",
        glyphSize = 14,
        variant = "ghost",
        width = ACTION_BUTTON_SIZE,
        height = ACTION_BUTTON_SIZE,
        paddingH = 0,
        paddingV = 0,
        tooltip = noctalia.tr("row.set-device"),
        enabled = not changingDeviceTz,
        onClick = function()
          noctalia.state.set("timezone_hub.cmd", { op = "set_device", tz = row.tz })
        end,
      })
    )

    table.insert(
      actions,
      ui.button({
        glyph = "trash",
        glyphSize = 14,
        variant = "ghost",
        width = ACTION_BUTTON_SIZE,
        height = ACTION_BUTTON_SIZE,
        paddingH = 0,
        paddingV = 0,
        tooltip = noctalia.tr("row.remove"),
        onClick = function()
          pendingDelete = row.tz
          render()
        end,
      })
    )
  end

  return actions
end

-- Every row shares the same fixed-width leading (grip) and trailing
-- (actions) slots regardless of how many action buttons or whether a grip
-- is shown, so the strip's flexGrow space is identical across rows and the
-- hour columns line up between the device row and every comparison row.
local GRIP_SLOT_WIDTH = 20
-- Three explicit 28px controls plus 8px inset on either side. Keeping the
-- hitboxes fixed prevents the final action from painting beyond the card.
local ACTIONS_SLOT_WIDTH = 100
local SCROLLBAR_GUTTER = 16

local function cityRow(row, isDeviceRow, hoursBefore, hoursAfter, use24h, highlightWork, workStart, workEnd)
  local gripSlot
  if isDeviceRow then
    gripSlot = ui.column({ width = GRIP_SLOT_WIDTH }, {})
  else
    gripSlot = ui.dragSource({
      key = "grip-" .. row.tz,
      dragType = DRAG_TYPE,
      payload = row.tz,
      previewAncestor = 1,
      liftFromLayout = true,
      width = GRIP_SLOT_WIDTH,
      height = 20,
      align = "center",
      justify = "center",
      tooltip = noctalia.tr("row.drag-tooltip"),
    }, {
      ui.glyph({ name = "menu-2", size = 12, color = "on_surface_variant" }),
    })
  end

  local infoItems = {
    ui.label({ text = row.label, fontWeight = "bold", fontSize = 12, maxLines = 1 }),
    ui.label({ text = row.tz, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
    ui.row({ gap = 4, align = "center", justify = "start" }, {
      ui.label({ text = row.timeText or "--:--", fontWeight = "bold", fontSize = 14, color = isDeviceRow and "primary" or "on_surface" }),
      ui.label({ text = row.abbrev or "", fontSize = 9, color = "on_surface_variant" }),
    }),
  }
  if noctalia.getConfig("show_date_in_panel") ~= false
    and row.dateText and row.dateText ~= ""
  then
    table.insert(infoItems, ui.label({
      text = row.dateText,
      fontSize = 9,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  if row.sunriseText and row.sunsetText then
    table.insert(infoItems, ui.row({ gap = 3, align = "center", justify = "start" }, {
      ui.glyph({ name = "sunrise", size = 10, color = "on_surface_variant" }),
      ui.label({ text = row.sunriseText, fontSize = 9, color = "on_surface_variant" }),
      ui.glyph({ name = "sunset", size = 10, color = "on_surface_variant" }),
      ui.label({ text = row.sunsetText, fontSize = 9, color = "on_surface_variant" }),
    }))
  end
  local relativeLines = relativeDescriptions(row, rows[1], workStart, workEnd)
  for _, relative in ipairs(relativeLines) do
    table.insert(infoItems, ui.label({
      text = relative,
      fontSize = 9,
      color = "primary",
      maxLines = 1,
    }))
  end
  local info = ui.column({ width = 132, gap = 1, justify = "start" }, infoItems)

  local strip = hourStrip(row.tz, hoursBefore, hoursAfter, use24h, highlightWork, workStart, workEnd)

  local actionsSlot = ui.row(
    {
      width = ACTIONS_SLOT_WIDTH,
      gap = 0,
      paddingH = 8,
      align = "center",
      justify = "end",
    },
    rowActions(row, isDeviceRow)
  )

  return ui.row({
    key = "row-" .. row.key,
    gap = 6,
    align = "center",
    justify = "start",
    paddingV = 4,
    paddingH = 6,
    fill = "surface_variant/0.25",
    radius = 6,
  }, { gripSlot, info, strip, actionsSlot })
end

-- ---------------------------------------------------------------------
-- List view
-- ---------------------------------------------------------------------
local function listView()
  local hoursBefore = noctalia.getConfig("hours_before") or 1
  local hoursAfter = noctalia.getConfig("hours_after") or 5
  local use24h = (noctalia.getConfig("time_format") or "24h") == "24h"
  local highlightWork = noctalia.getConfig("highlight_work_hours")
  if highlightWork == nil then
    highlightWork = true
  end
  local workStart = noctalia.getConfig("work_hour_start") or 9
  local workEnd = noctalia.getConfig("work_hour_end") or 17

  local body = {}

  table.insert(
    body,
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 8, align = "center", justify = "start", flexGrow = 1 }, {
        ui.glyph({ name = "world", size = 20, color = "primary" }),
        ui.column({ gap = 0, justify = "start" }, {
          ui.label({ text = noctalia.tr("panel.title"), fontSize = 14, fontWeight = "bold" }),
          ui.label({
            text = deviceTz ~= "" and (noctalia.tr("panel.subtitle") .. " " .. deviceTz) or noctalia.tr("panel.detecting"),
            fontSize = 10,
            color = "on_surface_variant",
          }),
        }),
      }),
      ui.row({ gap = 2, justify = "start" }, {
        ui.button({
          glyph = "pencil",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("row.change-device"),
          enabled = not changingDeviceTz,
          onClick = function()
            openPicker("device")
          end,
        }),
        ui.button({
          glyph = "plus",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.add"),
          enabled = #comparisons < 6,
          onClick = function()
            openPicker("add")
          end,
        }),
        ui.button({
          glyph = "settings",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.open-settings"),
          onClick = function()
            noctalia.openSettings()
          end,
        }),
        ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = function()
          panel.close()
        end }),
      }),
    })
  )

  table.insert(body, ui.separator({}))

  local windowSpan = hoursBefore + hoursAfter + 1
  table.insert(
    body,
    ui.row({ gap = 4, align = "center", justify = "center" }, {
      ui.button({
        glyph = "chevron-left",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.earlier"),
        onClick = function()
          hourOffset -= windowSpan
          render()
        end,
      }),
      ui.button({
        text = hourOffset == 0 and noctalia.tr("panel.now") or ((hourOffset > 0 and "+" or "") .. tostring(hourOffset) .. "h"),
        variant = hourOffset == 0 and "ghost" or "outline",
        controlSize = "sm",
        enabled = hourOffset ~= 0,
        tooltip = noctalia.tr("panel.jump-to-now"),
        onClick = function()
          hourOffset = 0
          render()
        end,
      }),
      ui.button({
        glyph = "chevron-right",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.later"),
        onClick = function()
          hourOffset += windowSpan
          render()
        end,
      }),
    })
  )

  if rows[1] ~= nil then
    -- Comparison rows live in a scroll viewport, which reserves space for its
    -- scrollbar. Give the fixed device row the same right gutter so both card
    -- widths and every fixed-width child column line up exactly.
    table.insert(body, ui.column({
      paddingRight = SCROLLBAR_GUTTER,
      align = "stretch",
    }, {
      cityRow(rows[1], true, hoursBefore, hoursAfter, use24h, highlightWork, workStart, workEnd),
    }))
  end

  local list = {}
  for i, entry in ipairs(comparisons) do
    local row = rowFor(entry.tz)
    if row ~= nil then
      table.insert(list, insertionZone(i))
      table.insert(list, cityRow(row, false, hoursBefore, hoursAfter, use24h, highlightWork, workStart, workEnd))
    end
  end
  if #comparisons > 0 then
    table.insert(list, insertionZone(#comparisons + 1))
  end

  if #list == 0 then
    table.insert(body, ui.label({
      text = noctalia.tr("settings.no-comparisons"),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  else
    table.insert(body, ui.scroll({
      flexGrow = 1,
      gap = 4,
      padding = 0,
      align = "stretch",
      justify = "start",
    }, list))
  end

  return ui.column({ flexGrow = 1, gap = 6, padding = 8, justify = "start" }, body)
end

-- ---------------------------------------------------------------------
-- Picker view
-- ---------------------------------------------------------------------
local function filteredZones()
  local q = noctalia.string.trim(query):lower()
  local out = {}
  for _, z in ipairs(allZones) do
    if q == "" or z:lower():find(q, 1, true) ~= nil then
      table.insert(out, z)
      if #out >= 100 then
        break
      end
    end
  end
  return out
end

local function pick(tz)
  if pickerMode == "device" then
    noctalia.state.set("timezone_hub.cmd", { op = "set_device", tz = tz })
  else
    noctalia.state.set("timezone_hub.cmd", { op = "add", tz = tz, label = shortLabel(tz) })
  end
  view = "list"
  render()
end

function onPickerSubmit(_value)
  local matches = filteredZones()
  if #matches == 1 then
    pick(matches[1])
  end
end

local function pickerView()
  local body = {
    ui.row({ gap = 6, align = "center", justify = "start" }, {
      ui.button({
        glyph = "arrow-left",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("picker.back"),
        onClick = function()
          view = "list"
          render()
        end,
      }),
      ui.label({
        text = pickerMode == "device" and noctalia.tr("picker.title-device") or noctalia.tr("picker.title-add"),
        fontSize = 13,
        fontWeight = "bold",
        flexGrow = 1,
      }),
    }),
    ui.input({
      key = "search-" .. tostring(queryKey),
      value = query,
      placeholder = noctalia.tr("picker.search-placeholder"),
      submitOnEnter = true,
      onChange = function(value)
        query = value
        render()
      end,
      onSubmit = "onPickerSubmit",
    }),
  }

  if not allZonesLoaded then
    table.insert(body, ui.label({ text = noctalia.tr("picker.loading"), fontSize = 10, color = "on_surface_variant" }))
  end

  local matches = filteredZones()
  if allZonesLoaded and #matches == 0 then
    table.insert(body, ui.label({ text = noctalia.tr("picker.empty"), fontSize = 11, color = "on_surface_variant" }))
  else
    local buttons = {}
    for _, z in ipairs(matches) do
      table.insert(
        buttons,
        ui.button({
          key = "zone-" .. z,
          text = (z:gsub("_", " ")),
          glyph = "pin-filled",
          variant = "ghost",
          contentAlign = "start",
          onClick = function()
            pick(z)
          end,
        })
      )
    end
    table.insert(body, ui.scroll({ flexGrow = 1, gap = 2, align = "stretch", justify = "start" }, buttons))
  end

  return ui.column({ flexGrow = 1, gap = 6, padding = 8, justify = "start" }, body)
end

-- ---------------------------------------------------------------------
-- Render dispatch
-- ---------------------------------------------------------------------
function render()
  if view == "picker" then
    panel.render(pickerView())
  else
    panel.render(listView())
  end
end

function openPicker(mode)
  pickerMode = mode
  view = "picker"
  query = ""
  queryKey += 1
  pendingDelete = nil
  if not allZonesLoaded then
    noctalia.state.set("timezone_hub.cmd", { op = "load_zones" })
  end
  render()
end

-- ---------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------
function onOpen(_context)
  view = "list"
  pendingDelete = nil
  hourOffset = 0
  panel.setWantsSecondTicks(true)
  render()
end

noctalia.state.watch("timezone_hub.rows", function(value)
  rows = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("timezone_hub.comparisons", function(value)
  comparisons = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("timezone_hub.device_tz", function(value)
  deviceTz = type(value) == "string" and value or ""
  render()
end)

noctalia.state.watch("timezone_hub.changing_device_tz", function(value)
  changingDeviceTz = value == true
  render()
end)

noctalia.state.watch("timezone_hub.bar_tzs", function(value)
  barTzs = type(value) == "table" and value or { DEVICE_BAR_KEY }
  render()
end)

noctalia.state.watch("timezone_hub.all_zones", function(value)
  allZones = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("timezone_hub.all_zones_loaded", function(value)
  allZonesLoaded = value == true
  render()
end)
