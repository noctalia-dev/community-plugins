--!nonstrict
-- When to fetch an account next. One entry per account, always in exactly one
-- state:
--   idle      waiting for `nextAt` (the interval after a good reply)
--   inflight  a request is out; only the reply carrying `generation` counts
--   backoff   waiting for `nextAt` after a failure; `code` says which
--
-- Transitions:  idle/backoff --start--> inflight --succeed--> idle
--                                        inflight --fail/expire--> backoff
-- A request with no reply after TIMEOUT_SECONDS fails as a network error, so
-- a lost reply backs off like any other failure instead of being retried
-- silently. Pure data in, data out; the service owns the clock.

local model = require("./model.luau")

local M = {}

local E = model.ErrorCode

-- Longer than the slowest legitimate fetch: a CLI renewal (30s) followed by
-- two requests at the host's 30s HTTP timeout.
M.TIMEOUT_SECONDS = 100

export type Entry = {
  state: string, -- "idle" | "inflight" | "backoff"
  nextAt: number, -- idle, backoff: when it is due
  since: number, -- inflight: when the request went out
  generation: number,
  failures: number, -- consecutive
  code: string?, -- backoff: the error code
}

function M.new(): Entry
  return { state = "idle", nextAt = 0, since = 0, generation = 0, failures = 0, code = nil }
end

function M.isBusy(entry: Entry): boolean
  return entry.state == "inflight"
end

function M.isDue(entry: Entry, now: number): boolean
  return entry.state ~= "inflight" and now >= entry.nextAt
end

-- Seconds to wait after `failures` consecutive errors of kind `code`.
function M.retryDelay(code: string, failures: number, interval: number): number
  local step = 2 ^ math.max(0, failures - 1)
  if code == E.NotConfigured or code == E.Expired then
    -- Local checks; the CLI may sign in or renew at any moment.
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

-- A request goes out. Returns the generation its reply must carry.
function M.start(entry: Entry, now: number): number
  entry.generation += 1
  entry.state = "inflight"
  entry.since = now
  return entry.generation
end

-- A reply. Returns false when it belongs to a request that is no longer the
-- current one (superseded, or already timed out) and must be ignored.
function M.finish(entry: Entry, generation: number, now: number, interval: number, err: model.ProviderError?): boolean
  if entry.state ~= "inflight" or generation ~= entry.generation then
    return false
  end
  if err == nil then
    entry.state, entry.failures, entry.code = "idle", 0, nil
    entry.nextAt = now + interval
  else
    entry.state, entry.code = "backoff", err.code
    entry.failures += 1
    entry.nextAt = now + M.retryDelay(err.code, entry.failures, interval)
  end
  return true
end

-- The error for a request that has been out too long, or nil. The caller
-- reports it through finish() like any other failure.
function M.expired(entry: Entry, now: number): model.ProviderError?
  if entry.state == "inflight" and now - entry.since >= M.TIMEOUT_SECONDS then
    return model.err(E.Network, "no reply")
  end
  return nil
end

-- Asks for a fetch now. Refused while a request is out, and while the vendor
-- is throttling us: asking early only extends its wait.
function M.force(entry: Entry, now: number): boolean
  if entry.state == "inflight" or (entry.state == "backoff" and entry.code == E.RateLimited) then
    return false
  end
  entry.nextAt = math.min(entry.nextAt, now)
  return true
end

-- The sign-in changed: a request still out was made for the old one, so its
-- reply is dropped and the new sign-in is fetched now. A throttle stays, as a
-- token renewal changes the sign-in too and would otherwise end it early.
function M.abandon(entry: Entry, now: number)
  if entry.state == "inflight" then
    entry.generation += 1
    entry.state, entry.nextAt = "idle", now
  else
    M.force(entry, now)
  end
end

-- Data fetched at `fetchedAt` (before a restart) is good until one interval
-- after it.
function M.resume(entry: Entry, fetchedAt: number, now: number, interval: number)
  if entry.state == "idle" then
    entry.nextAt = math.min(fetchedAt, now) + interval
  end
end

-- A shorter interval takes effect now rather than after the current wait.
function M.cap(entry: Entry, now: number, interval: number)
  if entry.state == "idle" then
    entry.nextAt = math.min(entry.nextAt, now + interval)
  end
end

return M
