--!nonstrict
-- Taildrop service.
--
-- Accepts a "send this file" request from an external caller (a file manager),
-- records a transfer job in shared state, opens the send dialog, and runs
-- `tailscale file cp` once the user confirms a destination.
--
-- No shell is ever built from untrusted data: paths travel as argv elements
-- and every command is assembled through shellQuote/shellCommand.

local STATE_KEY = "taildrop_snapshot"
local COMMAND_KEY = "taildrop_command"
local RESULT_KEY = "taildrop_result"
local TRANSFER_KEY = "taildrop_transfer"

local MAX_PATHS = 32
local MAX_PATH_BYTES = 4096

local transfer = {
  requestId = "",
  paths = {},
  target = "",
  phase = "choosing", -- choosing | confirming | sending | succeeded | failed | cancelled
  status = "",
  error = "",
  eligible = {},
  createdAt = 0,
  updatedAt = 0,
  revision = 0,
}

local busy = false
local lastAvailable = nil
local lastBusy = nil

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function nowSec()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return math.floor(ms / 1000)
    end
  end
  return os.time()
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function shellCommand(args)
  local quoted = {}
  for _, value in ipairs(args) do
    table.insert(quoted, shellQuote(value))
  end
  return table.concat(quoted, " ")
end

local function tsBin()
  local bin = trim(noctalia.getConfig("tailscale_bin"))
  if bin == "" then
    return "tailscale"
  end
  return bin
end

-- Run `tailscale <args>` as an argv vector (no raw concatenation).
local function runTs(args, callback, timeoutMs)
  return noctalia.runAsync(shellCommand(args), callback, timeoutMs or 60000)
end

local function publishTransfer()
  noctalia.state.set(TRANSFER_KEY, transfer)
end

-- Merge extra paths into an active (not-yet-sent) job, deduplicating.
local function addPaths(job, paths)
  local seen = {}
  for _, p in ipairs(job.paths or {}) do
    seen[p] = true
  end
  for _, p in ipairs(paths) do
    if not seen[p] then
      seen[p] = true
      table.insert(job.paths, p)
    end
  end
end

local function publishSnapshot()
  local available = noctalia.commandExists(tsBin())
  -- Only push state when something actually changed, so the panel isn't
  -- re-rendered on every service tick.
  if available == lastAvailable and busy == lastBusy then
    return
  end
  lastAvailable = available
  lastBusy = busy
  noctalia.state.set(STATE_KEY, {
    available = available,
    busy = busy,
    updatedAt = nowSec(),
  })
end

-- Decode a msg `payload` that may arrive already as a table or as a JSON string.
local function decodePayload(payload)
  if type(payload) == "table" then
    return payload
  end
  if type(payload) == "string" then
    local ok, decoded = pcall(noctalia.json.decode, payload)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return nil
end

-- Parse `tailscale file cp --targets` (tab-separated IP / name / optional status).
local function parseTargets(stdout)
  local list = {}
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" then
      local ip, name, rest = line:match("^(%S+)%s+(%S+)%s*(.*)$")
      if ip and name then
        local offline = rest ~= "" and rest:lower():find("offline", 1, true) ~= nil
        table.insert(list, { name = name, ip = ip, online = not offline })
      end
    end
  end
  table.sort(list, function(a, b)
    if a.online ~= b.online then
      return a.online
    end
    return a.name < b.name
  end)
  return list
end

-- Structural + filesystem validation of an incoming send request.
-- Returns (jobFields, nil) or (nil, errorMessage).
local function validateSendRequest(payload)
  if type(payload) ~= "table" then
    return nil, "request must be an object"
  end
  if payload.v ~= 1 then
    return nil, "unsupported contract version"
  end
  local rid = tostring(payload.requestId or "")
  if #rid < 1 or #rid > 64 or not rid:match("^[A-Za-z0-9._%-]+$") then
    return nil, "invalid requestId"
  end
  local paths = payload.paths
  if type(paths) ~= "table" or #paths < 1 or #paths > MAX_PATHS then
    return nil, `expected 1..{MAX_PATHS} file paths`
  end
  local validated = {}
  for _, p in ipairs(paths) do
    local s = tostring(p)
    if s == "" or #s > MAX_PATH_BYTES then
      return nil, "invalid path"
    end
    if not s:match("^/") then
      return nil, "path must be absolute: " .. s
    end
    local info = noctalia.fileInfo(s)
    if info == nil then
      return nil, "path not found: " .. s
    end
    -- Directories are allowed; they are archived to a .tar.gz at send time.
    table.insert(validated, s)
  end
  return { requestId = rid, paths = validated, origin = tostring(payload.origin or "") }, nil
end

local function setResult(command, ok, message, extra)
  local result = {
    requestId = command and command.requestId or "",
    action = command and command.action or "",
    ok = ok,
    message = message or "",
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      result[k] = v
    end
  end
  noctalia.state.set(RESULT_KEY, result)
end

-- Archive directories into a private temp dir, then report the final send
-- list (files + archives) plus the temp dir to clean up afterwards.
-- callback(files, tmpdir|nil, err|nil)
local function buildSendList(files, dirs, callback)
  if #dirs == 0 then
    callback(files, nil, nil)
    return
  end
  noctalia.runAsync("mktemp -d", function(res)
    if not res or res.exitCode ~= 0 or trim(res.stdout or "") == "" then
      callback(nil, nil, "could not create a temporary directory")
      return
    end
    local tmpdir = trim(res.stdout or "")
    local archives = {}
    local remaining = #dirs
    local doneErr = nil
    for _, d in ipairs(dirs) do
      local name = d:match("([^/]+)$") or "folder"
      local parent = d:match("^(.*)/[^/]+$")
      if parent == nil or parent == "" then
        parent = "/"
      end
      local archive = tmpdir .. "/" .. name .. ".tar.gz"
      noctalia.runAsync(shellCommand({ "tar", "czf", archive, "-C", parent, name }), function(r)
        if r and r.exitCode == 0 and noctalia.fileInfo(archive) ~= nil then
          table.insert(archives, archive)
        else
          local err = trim(r and (r.stderr ~= "" and r.stderr or r.stdout) or "archive failed")
          doneErr = err ~= "" and err or "archive failed"
        end
        remaining -= 1
        if remaining == 0 then
          if doneErr ~= nil then
            noctalia.runAsync(shellCommand({ "rm", "-rf", tmpdir }))
            callback(nil, nil, doneErr)
          else
            local all = {}
            for _, f in ipairs(files) do
              table.insert(all, f)
            end
            for _, a in ipairs(archives) do
              table.insert(all, a)
            end
            callback(all, tmpdir, nil)
          end
        end
      end, 600000)
    end
  end, 10000)
end

-- Run `tailscale file cp` for the current transfer job, archiving any
-- directories first. `command` is the originating panel command (for panel
-- feedback); `rid` is the job id it must still match.
local function performSend(command, rid)
  if busy then
    setResult(command, false, noctalia.tr("result.busy"))
    return
  end

  -- Re-validate that each path still exists before sending; split files/dirs.
  local files, dirs = {}, {}
  for _, p in ipairs(transfer.paths or {}) do
    local info = noctalia.fileInfo(p)
    if info == nil then
      transfer.phase = "failed"
      transfer.error = "path no longer exists: " .. p
      transfer.updatedAt = nowSec()
      transfer.revision += 1
      publishTransfer()
      setResult(command, false, transfer.error)
      return
    end
    if info.isDir then
      table.insert(dirs, p)
    else
      table.insert(files, p)
    end
  end

  busy = true
  transfer.phase = "sending"
  transfer.status = ""
  transfer.updatedAt = nowSec()
  transfer.revision += 1
  publishTransfer()
  publishSnapshot()

  local target = transfer.target

  buildSendList(files, dirs, function(sendList, tmpdir, err)
    if sendList == nil then
      busy = false
      transfer.phase = "failed"
      transfer.error = err or "send failed"
      transfer.updatedAt = nowSec()
      transfer.revision += 1
      publishTransfer()
      publishSnapshot()
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("result.failed", { error = transfer.error }))
      setResult(command, false, transfer.error)
      return
    end

    local bin = tsBin()
    local full = { bin, "file", "cp" }
    for _, p in ipairs(sendList) do
      table.insert(full, p)
    end
    table.insert(full, target .. ":")

    runTs(full, function(result)
      if type(transfer) ~= "table" or transfer.requestId ~= rid then
        if tmpdir ~= nil then
          noctalia.runAsync(shellCommand({ "rm", "-rf", tmpdir }))
        end
        return
      end
      busy = false
      transfer.updatedAt = nowSec()
      transfer.revision += 1
      if result and result.exitCode == 0 then
        transfer.phase = "succeeded"
        transfer.status = noctalia.tr("result.sent")
        transfer.error = ""
        noctalia.notify(
          noctalia.tr("title"),
          noctalia.tr("result.sent_to", { n = #transfer.paths, target = target })
        )
      else
        local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "send failed")
        if err == "" then
          err = "send failed"
        end
        transfer.phase = "failed"
        transfer.error = err
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("result.failed", { error = err }))
      end
      publishTransfer()
      publishSnapshot()
      if tmpdir ~= nil then
        noctalia.runAsync(shellCommand({ "rm", "-rf", tmpdir }))
      end
    end, 1200000)
  end)
end

local function executeTaildropConfirm(command)
  local rid = tostring(command.jobId or command.requestId or "")
  if type(transfer) ~= "table" or transfer.requestId ~= rid then
    setResult(command, false, noctalia.tr("result.no_job"))
    return
  end
  local target = trim(command.target or "")
  if target == "" then
    setResult(command, false, noctalia.tr("result.no_target"))
    return
  end
  transfer.target = target
  transfer.updatedAt = nowSec()
  transfer.revision += 1
  publishTransfer()
  performSend(command, rid)
end

local function executeTaildropRetry(command)
  local rid = tostring(command.jobId or command.requestId or "")
  if type(transfer) ~= "table" or transfer.requestId ~= rid then
    setResult(command, false, noctalia.tr("result.no_job"))
    return
  end
  if transfer.target == "" then
    setResult(command, false, noctalia.tr("result.no_target"))
    return
  end
  performSend(command, rid)
end

local function executeTaildropCancel(command)
  local rid = tostring(command.jobId or command.requestId or "")
  if type(transfer) == "table" and (rid == "" or transfer.requestId == rid) then
    transfer.phase = "cancelled"
    transfer.status = noctalia.tr("result.cancelled")
    transfer.updatedAt = nowSec()
    transfer.revision += 1
    publishTransfer()
  end
  setResult(command, true, noctalia.tr("result.cancelled"))
end

local function executeTaildropDismiss(command)
  local rid = tostring(command.jobId or command.requestId or "")
  if type(transfer) == "table" and (rid == "" or transfer.requestId == rid) then
    transfer = {
      requestId = "",
      paths = {},
      target = "",
      phase = "",
      status = "",
      error = "",
      eligible = {},
      createdAt = 0,
      updatedAt = 0,
      revision = 0,
    }
    publishTransfer()
  end
  setResult(command, true, noctalia.tr("result.dismissed"))
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  local action = command.action
  if action == "taildrop_confirm" then
    executeTaildropConfirm(command)
  elseif action == "taildrop_retry" then
    executeTaildropRetry(command)
  elseif action == "taildrop_cancel" then
    executeTaildropCancel(command)
  elseif action == "taildrop_dismiss" then
    executeTaildropDismiss(command)
  else
    setResult(command, false, "Unknown action: " .. action)
  end
end

noctalia.state.watch(COMMAND_KEY, executeAction)
setResult(nil, false, "") -- initialize result key

local function acceptSendRequest(req)
  transfer = {
    requestId = req.requestId,
    paths = req.paths or {},
    target = "",
    phase = "choosing",
    status = "",
    error = "",
    eligible = {},
    createdAt = nowSec(),
    updatedAt = nowSec(),
    revision = 0,
  }
  publishTransfer()
  publishSnapshot()

  -- The bridge helper opens the dialog via `noctalia msg panel-open` (a
  -- non-toggle open) so an already-open dialog is brought forward instead of
  -- toggled closed. The service deliberately does not touch the panel UI.

  -- Fetch eligible destinations (async) and backfill the job.
  local bin = tsBin()
  noctalia.runAsync(shellCommand({ bin, "file", "cp", "--targets" }), function(result)
    if type(transfer) ~= "table" or transfer.requestId ~= req.requestId then
      return
    end
    if result and result.exitCode == 0 then
      transfer.eligible = parseTargets(result.stdout or "")
      transfer.error = ""
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "could not list eligible targets")
      if err == "" then
        err = "could not list eligible targets"
      end
      transfer.error = err
    end
    transfer.updatedAt = nowSec()
    transfer.revision += 1
    publishTransfer()
  end, 15000)
end

function onIpc(event, payload)
  if event == "taildrop_send" then
    local req, err = validateSendRequest(decodePayload(payload))
    if req == nil then
      noctalia.log("taildrop: send rejected: " .. tostring(err))
      noctalia.notifyError(noctalia.tr("title"), err or "invalid request")
      return
    end
    noctalia.log("taildrop: send accepted requestId=" .. req.requestId .. " paths=" .. #req.paths)

    -- A file manager that runs the helper once per selected item will fire
    -- several requests in quick succession. Coalesce them into one dialog
    -- instead of opening (or re-toggling) the panel for each file.
    local active = type(transfer) == "table"
      and transfer.requestId ~= ""
      and (transfer.phase == "choosing" or transfer.phase == "confirming")
      and (nowSec() - (transfer.createdAt or 0)) <= 2
    if active then
      addPaths(transfer, req.paths or {})
      transfer.updatedAt = nowSec()
      transfer.revision += 1
      publishTransfer()
      return
    end

    acceptSendRequest(req)
    return
  end
  if type(payload) == "table" and type(payload.action) == "string" then
    executeAction(payload)
    return
  end
  noctalia.log("taildrop: unknown ipc event '" .. tostring(event) .. "'")
end

noctalia.setUpdateInterval(60000)

function update()
  -- Only refreshed availability once a minute, and only pushes on change.
  publishSnapshot()
end

function onConfigChanged()
  lastAvailable = nil
  lastBusy = nil
  publishSnapshot()
end

publishSnapshot()
