--!nonstrict
-- Explicit user actions only. Busy flags and generations prevent overlapping
-- attempts; a timeout does not prove the phone did not execute an action.
local M = {}
function M.new(snapshot, requests, clock, visibility, dependencies)
  local request = dependencies.request
  local publish = dependencies.publish
  local onlineDevice = dependencies.onlineDevice
  local invalidateKind = dependencies.invalidateKind
  local readPage = dependencies.readPage
  local poll = dependencies.poll
  local pollSessions = dependencies.pollSessions
  local sessionKinds = dependencies.sessionKinds

  local function validRequestId(id)
    return type(id) == "string" and #id == 32 and id:match("^%x+$") ~= nil
  end

  local function handlePageAction(command)
    local action = command.value
    if action.confirm ~= true or type(action.request_id) ~= "string" then
      return
    end
    local known = {
      sms = true,
      reply = true,
      dial = true,
      photo = true,
      app = true,
      deck = true,
      answer = true,
      decline = true,
      silence = true,
    }
    if not known[action.action] then return end
    -- Acknowledge receipt, not success. Keep the opaque ID after completion so
    -- the panel also unlocks if it misses the intermediate busy snapshot.
    local receipt = validRequestId(action.request_id) and action.request_id
    if receipt and snapshot.pageActionRequestId == receipt then return end
    if receipt then snapshot.pageActionRequestId = receipt end
    local busy = snapshot.pageActionBusy
    if busy or not visibility.open or (action.action ~= "deck" and not onlineDevice(command.device)) then
      if receipt then
        noctalia.notifyError("NectarLink", noctalia.tr(busy and "notifications.action_busy" or "notifications.action_failed"))
        publish()
      end
      return
    end
    requests.actions.generation = requests.actions.generation + 1
    local requestGeneration = requests.actions.generation
    requests.actions.started = clock.ticks
    snapshot.pageActionBusy = true
    snapshot.pageActionResult = nil
    publish()
    request("/v1/page-action", {
      device = command.device,
      action = action.action,
      request_id = action.request_id,
      confirm = true,
      id = action.id,
      text = action.text,
      recipients = action.recipients,
    }, function(ok, status, data)
      if requestGeneration ~= requests.actions.generation then
        return
      end
      snapshot.pageActionBusy = false
      snapshot.pageActionResult = nil
      -- Unconfirmed does not mean unexecuted. Never retry automatically.
      if not ok then
        local code = type(data) == "table" and data.error
        local notice = code == "request_limit_restart_required" and "action_limit"
          or code == "busy" and "action_busy"
          or (code == "uncertain_check_phone" or status == 0 or status == 504) and "action_timeout"
          or "action_failed"
        noctalia.notifyError("NectarLink", noctalia.tr("notifications." .. notice))
      end
      local kind = ({
        sms = "messages",
        reply = "messages",
        dial = "calls",
        answer = "calls",
        decline = "calls",
        silence = "calls",
      })[action.action]
      if kind then
        invalidateKind(command.device, kind)
      end
      publish()
      if
        kind
        and visibility.activePage
        and visibility.open
        and visibility.activePage.device == command.device
        and visibility.activePage.value.page == kind
      then
        readPage(visibility.activePage, true, true)
        local threads = kind == "messages" and visibility.threads
        if threads and threads.device == command.device then readPage(threads, true, true, "threads") end
      end
    end)
  end

  local function handleSessionCommand(command)
    -- Session commands and background reads have separate generations: an old
    -- poll completing cannot acknowledge a newly requested session transition.
    local value = command.value
    local session = snapshot.sessions and snapshot.sessions[command.device]
    if not session or snapshot.sessionBusy or type(value.on) ~= "boolean" then
      return
    end
    local known = false
    for _, kind in ipairs(sessionKinds) do
      if value.kind == kind then
        known = true
      end
    end
    if
      not known
      or (value.on and (not onlineDevice(command.device) or not session.allowed[value.kind]))
    then
      return
    end
    requests.sessions.commandGeneration = requests.sessions.commandGeneration + 1
    local requestGeneration = requests.sessions.commandGeneration
    requests.sessions.commandStarted = clock.ticks
    snapshot.sessionBusy = true
    publish()
    request(
      "/v1/session",
      { device = command.device, kind = value.kind, on = value.on },
      function(ok, status, data)
        if requestGeneration ~= requests.sessions.commandGeneration then
          return
        end
        requests.sessions.generation = requests.sessions.generation + 1
        requests.sessions.pending = false
        requests.sessions.refreshing = ok
        if not ok then
          snapshot.sessionBusy = false
          local messages = {
            another_device = noctalia.tr("notifications.another_device"),
            nothing_playing = noctalia.tr("notifications.nothing_playing"),
            unavailable = noctalia.tr("notifications.unavailable"),
            invalid_json = noctalia.tr("notifications.invalid_json"),
            invalid_session = noctalia.tr("notifications.invalid_session"),
            no_device = noctalia.tr("notifications.no_device"),
            session_failed = noctalia.tr("notifications.session_failed"),
          }
          noctalia.notifyError(
            "NectarLink",
            messages[type(data) == "table" and data.error or ""]
              or (
                status == 0 and noctalia.tr("notifications.api_unavailable")
                or noctalia.tr("notifications.session_http", { status = status })
              )
          )
        end
        publish()
        pollSessions()
      end
    )
  end

  local function handleTextInput(command)
    local session = snapshot.sessions and snapshot.sessions[command.device]
    if
      snapshot.typeBusy
      or not onlineDevice(command.device)
      or not session
      or session.keyboard ~= "enabled"
      or #command.value == 0
      or #command.value > 16384
    then
      return
    end
    requests.typing.generation = requests.typing.generation + 1
    local requestGeneration = requests.typing.generation
    requests.typing.started = clock.ticks
    snapshot.typeBusy = true
    snapshot.typeDeliveryDevice = nil
    publish()
    request("/v1/type", { device = command.device, text = command.value }, function(ok, _, data)
      if requestGeneration ~= requests.typing.generation then
        return
      end
      snapshot.typeBusy = false
      -- sent confirms transport only. Clear the draft only on acknowledged;
      -- the current desktop API reports transport_only.
      if ok and type(data) == "table" and data.acknowledged == true then
        snapshot.typeSent = (snapshot.typeSent or 0) + 1
        snapshot.typeSentDevice = command.device
      elseif ok and type(data) == "table" and data.sent == true then
        snapshot.typeDeliveryDevice = command.device
      else
        noctalia.notifyError("NectarLink", noctalia.tr("notifications.type_failed"))
      end
      publish()
    end)
  end

  local function handlePhoneToggle(command)
    -- Busy/generation belong to the command; rereading the device confirms
    -- actual state rather than assuming the click succeeded.
    local value = command.value
    if type(value.id) ~= "string" then
      return
    end
    if value.id == "ringer" then
      if value.mode ~= "ring" and value.mode ~= "vibrate" and value.mode ~= "silent" then
        return
      end
      if value.on ~= nil then
        return
      end
    elseif type(value.on) ~= "boolean" or value.mode ~= nil then
      return
    end
    local receipt = validRequestId(value.request_id) and value.request_id
    if receipt and snapshot.controlRequestId == receipt then return end
    if receipt then snapshot.controlRequestId = receipt end
    local allowed = false
    if onlineDevice(command.device) then
      for _, device in ipairs(snapshot.devices) do
        if device.id == command.device and device.controls and device.controls.allowed then
          allowed = device.controls.allowed[value.id] == true
        end
      end
    end
    local busy = snapshot.controlBusy
    if busy or not allowed or (value.id == "wifi" and value.on == false and value.confirm_disconnect ~= true) then
      if receipt then
        noctalia.notifyError("NectarLink", noctalia.tr(busy and "notifications.action_busy" or "notifications.toggle_failed"))
        publish()
      end
      return
    end
    requests.controls.generation = requests.controls.generation + 1
    requests.controls.refreshing = false
    local requestGeneration = requests.controls.generation
    requests.controls.started = clock.ticks
    snapshot.controlBusy = true
    publish()
    request("/v1/phone-toggle", {
      device = command.device,
      id = value.id,
      on = value.on,
      mode = value.mode,
      confirm_disconnect = value.confirm_disconnect == true,
    }, function(ok)
      if requestGeneration ~= requests.controls.generation then
        return
      end
      -- After acceptance, keep the switches disabled until the fresh read.
      requests.controls.refreshing = ok == true
      if not ok then snapshot.controlBusy = false end
      requests.devices.generation = requests.devices.generation + 1
      requests.devices.pending = false
      if not ok then
        noctalia.notifyError("NectarLink", noctalia.tr("notifications.toggle_failed"))
      end
      publish()
      poll()
    end)
  end

  local function handleCameraCommand(command)
    if snapshot.cameraBusy then
      return
    end
    requests.camera.generation = requests.camera.generation + 1
    local requestGeneration = requests.camera.generation
    requests.camera.started = clock.ticks
    snapshot.cameraBusy = true
    publish()
    request("/v1/camera", { device = command.device, mode = "photo" }, function(ok)
      if requestGeneration ~= requests.camera.generation then
        return
      end
      snapshot.cameraBusy = false
      publish()
      if not ok then
        noctalia.notifyError("NectarLink", noctalia.tr("notifications.camera_failed"))
      end
    end)
  end

  local function handleRingCommand(command)
    if snapshot.ringBusy then
      return
    end
    requests.ring.generation = requests.ring.generation + 1
    local requestGeneration = requests.ring.generation
    requests.ring.started = clock.ticks
    snapshot.ringBusy = true
    publish()
    request("/v1/ring", { device = command.device, on = command.value == true }, function(ok)
      if requestGeneration ~= requests.ring.generation then
        return
      end
      -- Discard reads started before the action, then reread the actual state.
      requests.devices.generation = requests.devices.generation + 1
      requests.devices.pending = false
      requests.ring.refreshing = ok
      if not ok then
        snapshot.ringBusy = false
        noctalia.notifyError("NectarLink", noctalia.tr("notifications.ring_failed"))
      end
      publish()
      poll()
    end)
  end
  return {
    handlePageAction = handlePageAction,
    handleSessionCommand = handleSessionCommand,
    handleTextInput = handleTextInput,
    handlePhoneToggle = handlePhoneToggle,
    handleCameraCommand = handleCameraCommand,
    handleRingCommand = handleRingCommand,
  }
end
return M
