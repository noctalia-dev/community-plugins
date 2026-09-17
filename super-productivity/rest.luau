--!nonstrict
-- authenticated loopback client for super productivity's local REST API.

local rest_state = require("./rest_state.luau")

local M = {
  FLATPAK_ID = "com.super_productivity.SuperProductivity",
}

local BASE_URL = "http://127.0.0.1:3876"
local TOKEN_NAME = "local-rest-api-token"
local REQUEST_TIMEOUT_MS = 12000

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end
local function finite_number(value)
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
  return number
end

local function append_token_path(base)
  return tostring(base or ""):gsub("/+$", "") .. "/superProductivity/" .. TOKEN_NAME
end

local function safe_path(path)
  return type(path) == "string"
    and path:match("^/[A-Za-z0-9%-%._~/%?=&]+$") ~= nil
    and not path:find("//", 1, true)
    and not path:find("..", 1, true)
end

local function task_path(task_id, suffix)
  if type(task_id) ~= "string" or #task_id == 0 or #task_id > 200
    or task_id:match("^[A-Za-z0-9_-]+$") == nil then return nil end
  return "/tasks/" .. task_id .. (suffix or "")
end

local function is_array(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count += 1
  end
  return count > 0
end
local function valid_array(value, item_validator)
  if type(value) ~= "table" then return false end
  local count, maximum = 0, 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or item_validator(item) ~= true then return false end
    count += 1
    maximum = math.max(maximum, key)
  end
  return count == maximum
end

local function valid_task(value)
  return type(value) == "table" and not is_array(value)
    and type(value.id) == "string" and value.id ~= ""
    and type(value.title) == "string" and type(value.isDone) == "boolean"
end

local function valid_label(value)
  return type(value) == "table" and not is_array(value)
    and type(value.id) == "string" and value.id ~= ""
    and type(value.title) == "string"
end

local function valid_status(value)
  if type(value) ~= "table" or is_array(value) then return false end
  local task_count = value.taskCount
  if type(task_count) ~= "number" or task_count < 0 or task_count % 1 ~= 0 then return false end
  if value.currentTaskId ~= nil and (type(value.currentTaskId) ~= "string" or value.currentTaskId == "") then
    return false
  end
  return value.currentTask == nil or valid_task(value.currentTask)
end

local function valid_started(value, task_id)
  if type(value) ~= "table" or is_array(value) or value.currentTaskId ~= task_id then return false end
  local count = 0
  for key in pairs(value) do
    if key ~= "currentTaskId" then return false end
    count += 1
  end
  return count == 1
end

local function valid_stopped(value)
  return type(value) == "table" and not is_array(value) and next(value) == nil
end

local function error_message(envelope)
  local api_error = type(envelope) == "table" and envelope.error or nil
  if type(api_error) ~= "table" then return nil end
  local message = trim(api_error.message)
  if message == "" then return nil end
  return #message <= 300 and message or message:sub(1, 300)
end

function M.valid_token(value)
  value = trim(value)
  return #value == 32 and value:match("^[A-Za-z0-9]+$") ~= nil
end

function M.token_candidates(options)
  options = options or {}
  local expand = options.expand or function(path) return path end
  local override = trim(options.rest_token_file)
  if override ~= "" then return { tostring(expand(override) or "") } end

  local candidates, seen = {}, {}
  local function add(path)
    path = tostring(expand(path) or ""):gsub("/+$", "")
    if path ~= "" and not seen[path] then
      seen[path] = true
      table.insert(candidates, path)
    end
  end

  local flatpak = "~/.var/app/" .. M.FLATPAK_ID .. "/config/superProductivity/" .. TOKEN_NAME
  if options.prefer_flatpak == true then add(flatpak) end
  local xdg_config_home = trim(options.xdg_config_home)
  if xdg_config_home ~= "" then add(append_token_path(xdg_config_home)) end
  add("~/.config/superProductivity/" .. TOKEN_NAME)
  if options.prefer_flatpak ~= true then add(flatpak) end
  return candidates
end

function M.reschedule_body(json, mode, now_ms)
  now_ms = finite_number(now_ms)
  if now_ms == nil or now_ms <= 0 then return nil end
  -- assemble the payload text so the opposite date field is encoded as JSON null instead of being omitted.
  -- TODO: revisit reminder clearing after this PR is merged and released:
  -- https://github.com/super-productivity/super-productivity/pull/9716
  if mode == "hour" then
    local due_time = math.floor(now_ms + 60 * 60 * 1000)
    return '{"dueWithTime":' .. tostring(due_time) .. ',"dueDay":null}', "dueWithTime", due_time
  end
  if mode ~= "tomorrow" and mode ~= "week" then return nil end
  local due_day = rest_state.date_after_days(now_ms, mode == "tomorrow" and 1 or 7)
  if due_day == nil then return nil end
  local encoded_ok, encoded = pcall(json.encode, due_day)
  if not encoded_ok or type(encoded) ~= "string" then return nil end
  return '{"dueDay":' .. encoded .. ',"dueWithTime":null}', "dueDay", due_day
end

function M.new(runtime)
  local client = {
    runtime = runtime,
    token = nil,
    token_source = nil,
    token_sources = {},
    discovery_signature = "",
    sequence = 0,
    pending = {},
  }

  function client:discovery_options()
    local launch_method = trim(self.runtime.getConfig("launch_method"))
    local prefer_flatpak = launch_method == "flatpak"
      or (launch_method == "" or launch_method == "auto")
        and self.runtime.flatpakAppInstalled(M.FLATPAK_ID) == true
    return {
      rest_token_file = self.runtime.getConfig("rest_token_file"),
      xdg_config_home = self.runtime.getenv("XDG_CONFIG_HOME"),
      prefer_flatpak = prefer_flatpak,
      expand = function(path) return self.runtime.expandPath(path) end,
    }
  end

  function client:invalidate_for_config()
    local options = self:discovery_options()
    local signature = table.concat({
      trim(options.rest_token_file),
      trim(options.xdg_config_home),
      options.prefer_flatpak and "flatpak" or "native",
    }, "\0")
    if signature ~= self.discovery_signature then
      self.discovery_signature = signature
      self.token = nil
      self.token_source = nil
      self.token_sources = {}
    end
  end

  function client:load_token()
    self:invalidate_for_config()
    if self.token ~= nil then return self.token end
    local options = self:discovery_options()
    local override = trim(options.rest_token_file) ~= ""
    for _, path in ipairs(M.token_candidates(options)) do
      local raw = self.runtime.readFile(path)
      local source = self.token_sources[path]
      if source == nil or source.raw ~= raw then
        source = { raw = raw, rejected = false }
        self.token_sources[path] = source
      end
      if not source.rejected and type(raw) == "string" and M.valid_token(raw) then
        self.token = trim(raw)
        self.token_source = source
        return self.token
      end
      if override then break end
    end
    return nil
  end

  function client:invalidate_token(source)
    -- each request retains its file version so late 401 responses cannot reject a newer version.
    source.rejected = true
    if source == self.token_source then
      self.token = nil
      self.token_source = nil
    end
  end

  local function finish(id, result)
    local request = client.pending[id]
    if request == nil then return end
    client.pending[id] = nil
    result.dispatched = request.dispatched == true
    request.callback(result)
  end

  local function decode_response(id, response)
    local request = client.pending[id]
    if request == nil then return end
    if type(response) ~= "table" or response.ok ~= true or tonumber(response.status) == nil
      or tonumber(response.status) == 0 then
      finish(id, { ok = false, kind = "transport_error" })
      return
    end

    local status = tonumber(response.status)
    if status == 401 then
      client:invalidate_token(request.token_source)
      finish(id, { ok = false, kind = "auth_required", status = status })
      return
    end
    local decoded_ok, envelope, decode_error = pcall(client.runtime.json.decode, response.body)
    if not decoded_ok or (envelope == nil and decode_error ~= nil) or type(envelope) ~= "table"
      or is_array(envelope) or type(envelope.ok) ~= "boolean" then
      finish(id, { ok = false, kind = "invalid_response", status = status })
      return
    end
    if status < 200 or status >= 300 or envelope.ok ~= true then
      finish(id, {
        ok = false,
        kind = status >= 500 and "server_error" or "http_error",
        status = status,
        message = error_message(envelope),
      })
      return
    end
    if envelope.data == nil then
      finish(id, { ok = false, kind = "invalid_response", status = status })
      return
    end
    if request.expected_status ~= nil and status ~= request.expected_status then
      finish(id, { ok = false, kind = "invalid_response", status = status })
      return
    end
    if type(request.validate) == "function" and request.validate(envelope.data) ~= true then
      finish(id, { ok = false, kind = "invalid_response", status = status })
      return
    end
    finish(id, { ok = true, status = status, data = envelope.data })
  end

  local function request(method, path, body, callback, contract)
    if type(callback) ~= "function" then return false end
    if not safe_path(path) then
      callback({ ok = false, kind = "request_error", dispatched = false })
      return false
    end
    local token = client:load_token()
    if token == nil then
      callback({ ok = false, kind = "auth_required", dispatched = false })
      return false
    end

    contract = contract or {}
    local body_text = contract.raw_body
    if body ~= nil then
      local encoded_ok, encoded = pcall(client.runtime.json.encode, body)
      if not encoded_ok or type(encoded) ~= "string" then
        callback({ ok = false, kind = "request_error", dispatched = false })
        return false
      end
      body_text = encoded
    end

    client.sequence += 1
    local id = client.sequence
    local now_ms = client.runtime.nowMs()
    client.pending[id] = {
      callback = callback,
      deadline = now_ms + REQUEST_TIMEOUT_MS,
      dispatched = false,
      token_source = client.token_source,
      expected_status = contract.status,
      validate = contract.validate,
    }
    local headers = {
      "Accept: application/json",
      "Authorization: Bearer " .. token,
    }
    if body_text ~= nil then table.insert(headers, "Content-Type: application/json") end

    local accepted = nil
    local pending_response = nil
    local received_response = false
    local function on_response(response)
      if accepted == nil then
        received_response = true
        pending_response = response
      elseif accepted == true then
        decode_response(id, response)
      end
    end

    local called, started = pcall(client.runtime.http, {
      url = BASE_URL .. path,
      method = method,
      headers = headers,
      body = body_text,
      follow_redirects = false,
    }, on_response)
    if not called then
      accepted = false
      client.pending[id].dispatched = true
      finish(id, { ok = false, kind = "transport_error" })
      return false
    end
    accepted = started == true
    local pending = client.pending[id]
    if pending ~= nil then pending.dispatched = accepted end
    if not accepted then
      finish(id, { ok = false, kind = "transport_error" })
      return false
    end
    if received_response then decode_response(id, pending_response) end
    return true
  end

  function client:update(now_ms)
    now_ms = tonumber(now_ms) or self.runtime.nowMs()
    local expired = {}
    for id, pending in pairs(self.pending) do
      if now_ms >= pending.deadline then table.insert(expired, id) end
    end
    for _, id in ipairs(expired) do finish(id, { ok = false, kind = "timeout" }) end
  end

  function client:tasks(callback)
    return request("GET", "/tasks?source=active&includeDone=true", nil, callback, {
      status = 200,
      validate = function(value) return valid_array(value, valid_task) end,
    })
  end

  function client:projects(callback)
    return request("GET", "/projects", nil, callback, {
      status = 200,
      validate = function(value) return valid_array(value, valid_label) end,
    })
  end

  function client:tags(callback)
    return request("GET", "/tags", nil, callback, {
      status = 200,
      validate = function(value) return valid_array(value, valid_label) end,
    })
  end

  function client:status(callback)
    return request("GET", "/status", nil, callback, { status = 200, validate = valid_status })
  end

  function client:add_task(input, callback)
    if type(input) ~= "string" or trim(input) == "" then
      callback({ ok = false, kind = "request_error", dispatched = false })
      return false
    end
    return request("POST", "/tasks", { title = input }, callback, { status = 201, validate = valid_task })
  end

  function client:set_done(task_id, is_done, callback)
    local path = task_path(task_id)
    if path == nil or type(is_done) ~= "boolean" then
      callback({ ok = false, kind = "request_error", dispatched = false })
      return false
    end
    return request("PATCH", path, { isDone = is_done }, callback, {
      status = 200,
      validate = function(value)
        return valid_task(value) and value.id == task_id and value.isDone == is_done
      end,
    })
  end

  function client:start_task(task_id, callback)
    local path = task_path(task_id, "/start")
    if path == nil then
      callback({ ok = false, kind = "request_error", dispatched = false })
      return false
    end
    return request("POST", path, nil, callback, {
      status = 200,
      validate = function(value) return valid_started(value, task_id) end,
    })
  end

  function client:stop_task(callback)
    return request("POST", "/task-control/stop", nil, callback, { status = 200, validate = valid_stopped })
  end

  function client:reschedule_task(task_id, mode, now_ms, callback)
    local path = task_path(task_id)
    local body, due_field, due_value = M.reschedule_body(self.runtime.json, mode, now_ms)
    if path == nil or body == nil then
      callback({ ok = false, kind = "request_error", dispatched = false })
      return false
    end
    return request("PATCH", path, nil, callback, {
      raw_body = body,
      status = 200,
      validate = function(value)
        local cleared_field = due_field == "dueDay" and "dueWithTime" or "dueDay"
        return valid_task(value) and value.id == task_id and value[due_field] == due_value
          and value[cleared_field] == nil
      end,
    })
  end

  return client
end

M.BASE_URL = BASE_URL
M.REQUEST_TIMEOUT_MS = REQUEST_TIMEOUT_MS

return M
