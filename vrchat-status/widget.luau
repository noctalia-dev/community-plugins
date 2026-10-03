--!nonstrict

local statusNumber = 0
local statusMessage = noctalia.tr("default.status.message")
-- Shared plugin state survives entry reloads, so it cannot tell us whether this
-- widget runtime has received the helper's current value yet.
local hasHelperData = false
local requestInFlight = false
local REQUEST_INTERVAL_MS = 5000
local DOT_WIDTH = 12
local CONTENT_GAP = 6
local PIXELS_PER_TEXT_UNIT = 8

local function statusColor(number)
  if number == 4 then return noctalia.getConfig("join_me_color") end
  if number == 3 then return noctalia.getConfig("online_color") end
  if number == 2 then return noctalia.getConfig("ask_me_color") end
  if number == 1 then return noctalia.getConfig("do_not_disturb_color") end
  return noctalia.getConfig("offline_color")
end

local function characterBytes(firstByte)
  if firstByte < 0x80 then return 1 end
  if firstByte < 0xE0 then return 2 end
  if firstByte < 0xF0 then return 3 end
  return 4
end

local function truncateMessage(message, availablePixels)
  local capacity = math.max(0, math.floor(availablePixels / PIXELS_PER_TEXT_UNIT))
  local characters = {}
  local totalUnits = 0
  local index = 1

  while index <= #message do
    local firstByte = string.byte(message, index)
    local byteCount = characterBytes(firstByte)
    local lastByte = math.min(#message, index + byteCount - 1)
    local units = firstByte < 0x80 and 1 or 2
    table.insert(characters, { text = string.sub(message, index, lastByte), units = units })
    totalUnits = totalUnits + units
    index = lastByte + 1
  end

  if totalUnits <= capacity then return message end

  local contentCapacity = math.max(0, capacity - 3)
  local result = ""
  local usedUnits = 0
  for _, character in ipairs(characters) do
    if usedUnits + character.units > contentCapacity then break end
    result = result .. character.text
    usedUnits = usedUnits + character.units
  end
  return result .. "..."
end

local function render()
  local color = statusColor(statusNumber)
  local messageColor = color
  if noctalia.getConfig("message_color_mode") == "fixed" then
    messageColor = noctalia.getConfig("message_color")
  end
  local minLength = math.max(0, tonumber(noctalia.getConfig("min_length")) or 100)
  local maxLength = math.max(60, tonumber(noctalia.getConfig("max_length")) or 300)
  minLength = math.min(minLength, maxLength)
  local messageMaxWidth = math.max(0, maxLength - DOT_WIDTH - CONTENT_GAP)
  local displayMessage = truncateMessage(statusMessage, messageMaxWidth)
  local vertical = barWidget.isVertical()
  local container = vertical and ui.column or ui.row
  local containerProps = { gap = CONTENT_GAP, align = "center" }
  if vertical then
    containerProps.minHeight = minLength
  else
    containerProps.minWidth = minLength
  end
  barWidget.render(container(containerProps, {
    ui.label({
      text = "●",
      color = color,
      baseline = "inkCentered",
      width = DOT_WIDTH,
      textAlign = "center",
    }),
    ui.label({
      text = displayMessage,
      color = messageColor,
      maxWidth = messageMaxWidth,
      maxLines = 1,
    }),
  }))
  barWidget.setTooltip(statusMessage)
end

local function publish()
  noctalia.state.set("status_number", statusNumber)
  noctalia.state.set("status_message", statusMessage)
end

local function requestStatus()
  if hasHelperData or requestInFlight then return end
  local helper = noctalia.getConfig("helper_path")
  if type(helper) ~= "string" or helper == "" then return end

  requestInFlight = true
  local started = noctalia.runAsync({ helper, "msg", "request-push" }, function(_result)
    requestInFlight = false
  end)
  if not started then requestInFlight = false end
end

local function parsePayload(payload)
  if type(payload) ~= "string" or #payload < 2 then return nil, nil end
  local number = tonumber(string.sub(payload, 1, 1))
  if number == nil or number < 0 or number > 4 then return nil, nil end
  local separator = string.sub(payload, 2, 2)
  if separator ~= ":" then return nil, nil end
  return number, string.sub(payload, 3)
end

function update()
  render()
  requestStatus()
end

function onClick()
  noctalia.togglePanel("surumeika1987/vrchat-status:status-panel")
end

function onIpc(event, payload)
  if event ~= "push-status" then return end
  local number, message = parsePayload(payload)
  if number == nil then
    noctalia.log("Ignoring invalid VRChat status payload")
    return
  end
  statusNumber = number
  statusMessage = message
  hasHelperData = true
  publish()
  render()
end

noctalia.state.watch("status_number", function(value)
  if type(value) == "number" and value ~= statusNumber then
    statusNumber = value
    render()
  end
end)
noctalia.state.watch("status_message", function(value)
  if type(value) == "string" and value ~= statusMessage then
    statusMessage = value
    render()
  end
end)
local savedNumber = noctalia.state.get("status_number")
local savedMessage = noctalia.state.get("status_message")
if type(savedNumber) == "number" and type(savedMessage) == "string" then
  statusNumber = savedNumber
  statusMessage = savedMessage
else
  publish()
end
noctalia.setUpdateInterval(REQUEST_INTERVAL_MS)
render()
requestStatus()
