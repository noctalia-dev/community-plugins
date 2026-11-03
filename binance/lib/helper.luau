--!nonstrict
-- Runs binance_helper.py one invocation at a time. User actions (connect
-- wizard, manual refresh) jump ahead of background syncs; a command already
-- queued is not queued twice. Every run has an explicit timeout, and a run
-- whose callback never arrives is abandoned after a grace period so the
-- queue cannot stall.

local M = {}

M.DATA_TIMEOUT_MS = 30000
M.KEYRING_TIMEOUT_MS = 60000 -- leaves time for a keyring unlock prompt
local GRACE_MS = 15000

local KEYRING_COMMANDS = { keygen = true, ["store-api-key"] = true, verify = true, recheck = true, disconnect = true }

-- Parses one helper result into (data, nil) or (nil, ErrorView fields).
function M.parse(result, decode, trim): (any, any)
  if result == nil then
    return nil, { code = "timeout" }
  end
  if result.timedOut then
    return nil, { code = "timeout" }
  end
  local data = decode(trim(result.stdout or ""))
  if type(data) ~= "table" then
    -- No JSON and a failed exit: Python died before answering (a missing or
    -- broken helper file), not a helper that answered something odd.
    if type(result.exitCode) == "number" and result.exitCode ~= 0 then
      return nil, { code = "helper_failed", status = result.exitCode }
    end
    return nil, { code = "bad_output" }
  end
  if type(data.error) == "string" then
    local err = table.clone(data)
    err.code = data.error
    err.error = nil
    return nil, err
  end
  return data, nil
end

export type Job = {
  command: string,
  user: boolean,
  callbacks: { (any, any) -> () },
}

-- host: { run(argv, cb, timeoutMs) -> boolean, decode, trim, now() -> ms }
-- argv(command) builds the full argument vector.
function M.new(host, argv)
  local self = {
    queue = {} :: { Job },
    running = nil :: Job?,
    startedAt = 0,
    timeoutMs = 0,
    generation = 0,
  }

  local pump

  local function finish(job: Job, data, err)
    for _, cb in job.callbacks do
      cb(data, err)
    end
  end

  pump = function()
    if self.running ~= nil or #self.queue == 0 then
      return
    end
    local job = table.remove(self.queue, 1) :: Job
    self.running = job
    self.generation += 1
    local generation = self.generation
    self.startedAt = host.now()
    self.timeoutMs = if KEYRING_COMMANDS[job.command] then M.KEYRING_TIMEOUT_MS else M.DATA_TIMEOUT_MS
    local started = host.run(argv(job.command), function(result)
      if generation ~= self.generation then
        return -- abandoned by tick(); its replacement already ran
      end
      self.running = nil
      local data, err = M.parse(result, host.decode, host.trim)
      finish(job, data, err)
      pump()
    end, self.timeoutMs)
    if not started then
      self.running = nil
      finish(job, nil, { code = "spawn_failed" })
      pump()
    end
  end

  -- Queues `command`; `cb(data, err)` runs when it finishes.
  function self.submit(command: string, user: boolean, cb: (any, any) -> ())
    for _, job in self.queue do
      if job.command == command then
        table.insert(job.callbacks, cb)
        if user and not job.user then
          job.user = true
          table.remove(self.queue, table.find(self.queue, job))
          local at = 1
          while at <= #self.queue and self.queue[at].user do
            at += 1
          end
          table.insert(self.queue, at, job)
        end
        return
      end
    end
    local job = { command = command, user = user, callbacks = { cb } }
    if user then
      local at = 1
      while at <= #self.queue and self.queue[at].user do
        at += 1
      end
      table.insert(self.queue, at, job)
    else
      table.insert(self.queue, job)
    end
    pump()
  end

  -- The command running now, if any.
  function self.current(): string?
    return if self.running ~= nil then self.running.command else nil
  end

  function self.pending(command: string): boolean
    if self.running ~= nil and self.running.command == command then
      return true
    end
    for _, job in self.queue do
      if job.command == command then
        return true
      end
    end
    return false
  end

  -- Abandons a run whose callback is overdue.
  function self.tick()
    local job = self.running
    if job ~= nil and host.now() - self.startedAt > self.timeoutMs + GRACE_MS then
      self.generation += 1
      self.running = nil
      finish(job, nil, { code = "timeout" })
      pump()
    end
  end

  return self
end

return M
