--!nonstrict

local statusNumber = 0
local statusMessage = noctalia.tr("default.status.message")
local statusNames = {
  noctalia.tr("panel.status.join_me"),
  noctalia.tr("panel.status.online"),
  noctalia.tr("panel.status.ask_me"),
  noctalia.tr("panel.status.do_not_disturb"),
}
local isOpen = false
local inputRevision = 0
local messageDirty = false
local sendInFlight = false
local pendingPayload = nil
local MAX_STATUS_MESSAGE_LENGTH = 32

local function truncateStatusMessage(message)
  local endByte = utf8.offset(message, MAX_STATUS_MESSAGE_LENGTH + 1)
  if endByte == nil then return message end
  return string.sub(message, 1, endByte - 1)
end

-- Serialize helper processes and retain only the newest request while one is running.
local function sendPayload(payload)
  if sendInFlight then
    pendingPayload = payload
    return true
  end

  local helper = noctalia.getConfig("helper_path")
  if type(helper) ~= "string" or helper == "" then
    noctalia.notifyError("VRChat Status", noctalia.tr("error.message.helper_path_not_configured"))
    return false
  end

  sendInFlight = true
  local started = noctalia.runAsync({ helper, "msg", "push-status", payload }, function(result)
    sendInFlight = false
    if result.exitCode ~= 0 then
      noctalia.notifyError(
        "VRChat Status",
        result.stderr ~= "" and result.stderr or noctalia.tr("error.message.helper_contact_failed")
      )
    end

    if pendingPayload ~= nil then
      local nextPayload = pendingPayload
      pendingPayload = nil
      if nextPayload ~= payload then sendPayload(nextPayload) end
    end
  end)
  if not started then
    sendInFlight = false
    noctalia.notifyError("VRChat Status", noctalia.tr("error.message.helper_start_failed"))
    return false
  end
  return true
end

local function sendStatus()
  return sendPayload(tostring(statusNumber) .. ":" .. statusMessage)
end

local function sendDirtyMessage()
  if not messageDirty then return end
  if sendStatus() then messageDirty = false end
end

local function render()
  -- ui.input has no blur callback; a background click represents focus leaving it.
  panel.render(ui.column({ gap = 12, padding = 16, onClick = "onPanelClicked" }, {
    ui.label({ text = noctalia.tr("panel.status.label"), fontWeight = "bold" }),
    ui.select({
      options = statusNames,
      selectedIndex = statusNumber > 0 and 4 - statusNumber or -1,
      placeholder = noctalia.tr("panel.status.offline"),
      width = 180,
      onChange = "onStatusChanged",
    }),
    ui.label({ text = noctalia.tr("panel.message.label"), fontWeight = "bold" }),
    ui.input({
      key = "status-message-" .. tostring(inputRevision),
      value = statusMessage,
      multiline = true,
      height = 72,
      placeholder = noctalia.tr("panel.message.placeholder"),
      onChange = "onMessageChanged",
    }),
  }))
end

function onOpen(_context)
  isOpen = true
  inputRevision = inputRevision + 1
  local number = noctalia.state.get("status_number")
  local message = noctalia.state.get("status_message")
  if type(number) == "number" then statusNumber = number end
  if type(message) == "string" then statusMessage = message end
  messageDirty = false
  render()
end


function onClose()
  isOpen = false
  sendDirtyMessage()
end

function onPanelClicked()
  sendDirtyMessage()
end

function onStatusChanged(index)
  local selected = tonumber(index)
  if selected == nil then return end
  if selected < 0 or selected > 3 then return end
  statusNumber = 4 - selected
  noctalia.state.set("status_number", statusNumber)
  if sendStatus() then messageDirty = false end
  render()
end

function onMessageChanged(value)
  local message = value or ""
  statusMessage = truncateStatusMessage(message)
  messageDirty = true
  noctalia.state.set("status_message", statusMessage)
  if statusMessage ~= message then
    inputRevision = inputRevision + 1
    render()
  end
end

noctalia.state.watch("status_number", function(value)
  if type(value) == "number" and value ~= statusNumber then
    statusNumber = value
    if isOpen then render() end
  end
end)
noctalia.state.watch("status_message", function(value)
  if type(value) == "string" and value ~= statusMessage then
    statusMessage = value
    if isOpen then
      inputRevision = inputRevision + 1
      render()
    end
  end
end)
