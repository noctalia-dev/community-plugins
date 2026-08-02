--!nonstrict
-- Serial async sysfs reader.
--
-- Keeps at most one `cat` subprocess in flight. Sysfs and pseudo-files are
-- polled every refresh, so a strict queue keeps the load flat and the
-- readings in order. Reads are tiny; the queue drains in milliseconds.
--
-- Uses noctalia.runAsync because noctalia.readFileAsync (plugin API 23) is
-- not present on the beta.7 host. Paths come from sysfs discovery and are
-- always plain absolute paths without spaces or shell metacharacters.

local queue = {}
local running = false
local READ_TIMEOUT_MS = 3000

local function pump()
  running = false
  local job = table.remove(queue, 1)
  if job == nil then return end
  running = true

  local launched = noctalia.runAsync("cat " .. job.path, function(result)
    local okResult = result ~= nil
    local contents = nil
    local err = nil
    if not okResult or result.timedOut then
      err = "timeout"
    elseif result.exitCode ~= 0 then
      err = "exit " .. tostring(result.exitCode)
    else
      contents = result.stdout or ""
    end
    job.cb(contents, err)
    pump()
  end, READ_TIMEOUT_MS)

  if not launched then
    job.cb(nil, "launch failed")
    pump()
  end
end

local M = {}

-- Queue a read. cb(contents, err); both may be nil on failure.
function M.read(path, cb)
  if path == nil or path == "" then
    cb(nil, "no path")
    return
  end
  table.insert(queue, { path = path, cb = cb })
  if not running then pump() end
end

-- Queue a read parsed as the first integer. cb(number or nil).
function M.readInt(path, cb)
  M.read(path, function(contents)
    if contents == nil then
      cb(nil)
      return
    end
    local n = tonumber(string.match(contents, "%d+"))
    if n == nil then
      cb(nil)
      return
    end
    cb(n)
  end)
end

return M
