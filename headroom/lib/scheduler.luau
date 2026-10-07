--!nonstrict
-- Per-provider refresh bookkeeping: when to fetch next, backoff after failures,
-- and protection against overlapping or abandoned requests.
--
-- Pure data in, data out; the service owns the clock and the side effects.

local model = require("./model.luau")

local M = {}

local E = model.ErrorCode

-- A request with no answer after this long is considered lost; its late reply,
-- if any, is dropped by the generation check.
M.TIMEOUT_SECONDS = 45

export type Entry = {
  nextAt: number,
  failures: number,
  inflightSince: number?,
  generation: number,
}

function M.new(): Entry
  return { nextAt = 0, failures = 0, inflightSince = nil, generation = 0 }
end

function M.isBusy(entry: Entry, now: number): boolean
  return entry.inflightSince ~= nil and now - entry.inflightSince < M.TIMEOUT_SECONDS
end

function M.isDue(entry: Entry, now: number): boolean
  return not M.isBusy(entry, now) and now >= entry.nextAt
end

-- Marks a request as started; returns the generation its reply must carry.
function M.start(entry: Entry, now: number): number
  entry.generation += 1
  entry.inflightSince = now
  return entry.generation
end

-- Seconds to wait before retrying after `failures` consecutive errors.
function M.retryDelay(code: string, failures: number, interval: number): number
  local step = 2 ^ math.max(0, failures - 1)
  if code == E.NotConfigured or code == E.Expired then
    -- Purely local checks; the CLI may sign in or renew at any moment.
    return 60
  elseif code == E.Auth then
    return interval
  elseif code == E.NoPlan then
    -- Plans change rarely; check hourly in case the user upgrades.
    return math.max(interval, 3600)
  elseif code == E.RateLimited then
    return math.min(math.max(interval, 300 * step), 3600)
  end
  return math.min(30 * step, interval)
end

-- Records a reply. Returns false when it belongs to a superseded request and
-- must be ignored.
function M.finish(entry: Entry, generation: number, now: number, interval: number, err: model.ProviderError?): boolean
  if generation ~= entry.generation then
    return false
  end
  entry.inflightSince = nil
  if err == nil then
    entry.failures = 0
    entry.nextAt = now + interval
  else
    entry.failures += 1
    entry.nextAt = now + M.retryDelay(err.code, entry.failures, interval)
  end
  return true
end

-- A manual refresh: due now, unless a request is already on its way.
function M.force(entry: Entry, now: number)
  entry.nextAt = now
end

return M
