--!nonstrict
local operation = {}
local COMMAND_TIMEOUT_MS = 12000
local OPEN_TIMEOUT_MS = 30000
local active = { rest_pending = true, rest_confirming = true, refresh_pending = true, open_waiting = true, select_pending = true }

-- own foreground phases and project them into the public action payload.
function operation.new(d)
  local record = { phase = "idle" }
  local generation = 0
  local sequence = 0
  local api = {}

  local function matches(token, phase)
    return record.generation == token and record.phase == phase
  end

  local function publish(rejected)
    local r = record
    local value = { status = active[r.phase] and "working" or r.phase }
    if r.phase ~= "idle" then
      value.type = r.command.type == "open" and "select" or r.command.type
      value.requestId = r.command.requestId
      value.taskId = r.command.taskId
      value.commandId = r.commandId
      if not active[r.phase] then
        value.completedAt = r.completedAt
        value.data = r.data
        value.error = r.error
        value.canUndo = r.canUndo
      end
    end
    value.rejectedRequestId = rejected
    d.publish_action(value)
  end

  local function finish(r, phase, data, message, can_undo, effects)
    record = { phase = phase, generation = r.generation,
      command = { type = r.command.type, requestId = r.command.requestId, taskId = r.command.taskId },
      commandId = r.commandId, completedAt = d.now(), data = data, error = message, canUndo = can_undo }
    -- commit terminal ownership before cleanup or publication can reenter.
    if r.phase == "select_pending" then d.remove(r.commandPath) end
    if effects then effects() end
    publish()
  end

  local function rest_result(token, result)
    if not matches(token, "rest_pending") then return end
    local r = record
    local c = r.command
    if result.ok ~= true then
      local message = d.failure_message(result)
      local uncertain = (result.kind == "timeout" or result.kind == "transport_error") and result.dispatched == true
      finish(r, uncertain and "unknown" or "error", nil, message, nil, function()
        d.rest_failure(result, message)
      end)
      if not uncertain then d.notify_error(message) end
      d.publish()
      return
    end
    -- the refresh queue must start confirmation after this acknowledgement.
    record = { phase = "rest_confirming", generation = token, command = c, data = result.data }
    if c.type == "complete" then d.complete(c.task, d.now())
    elseif c.type == "restore" then d.restore()
    elseif c.type == "add" and c.source == "launcher" then d.notify_added(c.input) end
    d.refresh(function(refreshed, _, confirmation)
      if not matches(token, "rest_confirming") then return end
      local pending = record
      local phase, message = "success", nil
      if c.type == "timer_start" or c.type == "timer_stop" then
        if not refreshed then
          phase, message = "unknown", d.tr("error.timer_confirmation_unknown")
        else
          local evidence = type(confirmation) == "table" and confirmation or {}
          local current = evidence.currentTask
          -- an authoritative ID can still exist when task details are absent.
          local confirmed = if c.type == "timer_start" then current ~= nil and current.id == c.taskId
            else current == nil and evidence.currentTaskId == nil
          if not confirmed then
            phase, message = "error", d.tr("error.timer_confirmation_mismatch")
          end
        end
      end
      finish(pending, phase, pending.data, message, c.type == "complete" and type(c.task) == "table" or nil, function()
        if not refreshed then d.clear_tasks() end
        if message then d.set_error(message) end
      end)
      if message then d.notify_error(message) end
      d.publish()
    end)
  end

  local function record_command_sent(r)
    if r.publication == "sent" then return r end
    local sent = table.clone(r)
    sent.publication = "sent"
    record = sent
    d.command_sent(sent.issuedAt)
    return sent
  end

  local function publish_select(r, now_ms)
    local commands, responses = d.bridge_paths()
    sequence += 1
    local id = "noctalia-" .. tostring(math.floor(now_ms)) .. "-" .. tostring(sequence)
    local path = commands .. "/" .. id .. ".json"
    local pending = { phase = "select_pending", generation = r.generation, command = r.command,
      commandId = id, commandPath = path, responseDir = responses, deadline = now_ms + COMMAND_TIMEOUT_MS,
      publication = "publishing", issuedAt = now_ms }
    record = pending
    local ok, message = d.mkdir(commands)
    if ok then
      local encoded
      encoded, message = d.encode({ schemaVersion = d.schema, protocolVersion = d.protocol, id = id, action = "select",
        issuedAt = now_ms, expiresAt = pending.deadline, payload = { taskId = r.command.taskId } }, true)
      ok = type(encoded) == "string"
      if ok then ok, message = d.write(path .. ".tmp", encoded) end
      if ok then ok, message = d.rename(path .. ".tmp", path) end
    end
    if not matches(r.generation, "select_pending") or record.commandId ~= id then return end
    if not ok then
      record = { phase = "open_waiting", generation = r.generation, command = r.command,
        readyAfter = r.readyAfter, deadline = r.deadline }
      d.remove(path .. ".tmp")
      d.set_error(tostring(message or "Command publish failed"), true)
      return
    end
    record_command_sent(record)
    publish()
    d.publish()
  end

  local function advance_open(now_ms)
    if record.phase ~= "open_waiting" then return end
    local r = record
    if now_ms >= r.deadline then
      local message = d.tr("error.launch_failed")
      finish(r, "error", nil, message, nil, function() d.set_error(message, true) end)
      return
    end
    local ready, updated = d.connection()
    if matches(r.generation, "open_waiting") and ready and (r.readyAfter == 0 or updated >= r.readyAfter) then
      publish_select(r, now_ms)
    end
  end

  function api:bridge_pinned()
    return record.phase == "select_pending"
  end

  function api:submit(command)
    if active[record.phase] then
      local message = "Another Super Productivity action is already active."
      d.set_error(message)
      publish(command.requestId)
      d.notify_error(message)
      d.publish()
      return false
    end
    generation += 1
    local token = generation
    local c = table.clone(command)
    local now_ms = d.now()
    if c.type == "open" then
      record = { phase = "open_waiting", generation = token, command = c, readyAfter = now_ms, deadline = now_ms + OPEN_TIMEOUT_MS }
      local ready = d.connection()
      if ready then record = { phase = "open_waiting", generation = token, command = c, readyAfter = 0, deadline = now_ms + OPEN_TIMEOUT_MS } end
      publish()
      local started, message = d.launch()
      if not matches(token, "open_waiting") then return true end
      if not started then finish(record, "error", nil, message) else advance_open(now_ms) end
    elseif c.type == "refresh" then
      record = { phase = "refresh_pending", generation = token, command = c, startedAt = now_ms }
      publish()
      d.refresh(function(ok, failure)
        if not matches(token, "refresh_pending") then return end
        finish(record, ok and "success" or "error", nil, not ok and d.failure_message(failure) or nil)
      end)
    else
      record = { phase = "rest_pending", generation = token, command = c, startedAt = now_ms }
      publish()
      local callback = function(result) rest_result(token, result) end
      if c.type == "add" then d.rest:add_task(c.input, callback)
      elseif c.type == "complete" or c.type == "restore" then d.rest:set_done(c.taskId, c.type == "complete", callback)
      elseif c.type == "timer_start" then d.rest:start_task(c.taskId, callback)
      elseif c.type == "timer_stop" then d.rest:stop_task(callback)
      elseif c.type == "snooze" then d.rest:reschedule_task(c.taskId, c.mode, now_ms, callback)
      else error("Unsupported operation: " .. tostring(c.type)) end
    end
    return true
  end

  function api:update(now_ms)
    local r = record
    if r.phase == "select_pending" then
      local entries = d.list(r.responseDir)
      if type(entries) ~= "table" then entries = {} end
      for _, name in ipairs(entries) do
        local id = tostring(name):match("^(.-)%.json$")
        if id then
          local path = r.responseDir .. "/" .. tostring(name)
          local response = d.decode_file(path)
          if matches(r.generation, "select_pending") and record.commandId == id then
            local valid = type(response) == "table" and tonumber(response.schemaVersion) == d.schema
              and tonumber(response.protocolVersion) == d.protocol and response.id == id
              and response.action == "select" and type(response.ok) == "boolean"
            local message
            if not valid then message = d.tr("error.protocol_mismatch")
            elseif not response.ok then
              message = tostring(response.error or ""):match("^%s*(.-)%s*$")
              if message == "" then message = d.tr("error.command_failed") end
            end
            -- a response proves publication even if rename has not returned yet.
            r = record_command_sent(record)
            finish(r, message and "error" or "success", if valid and response.ok then response.data else nil, message, nil, function()
              d.remove(path)
              d.response_received(now_ms)
              if message then d.set_error(message, true) end
            end)
            if message then d.notify_error(message) end
          else
            d.remove(path)
          end
        end
      end
      -- a response present on this tick takes precedence over expiration.
      if matches(r.generation, "select_pending") and now_ms > r.deadline then
        local message = d.tr("error.command_timeout")
        finish(r, "error", nil, message, nil, function() d.set_error(message, true) end)
      end
    end
    advance_open(now_ms)
  end

  publish()
  return api
end
return operation
