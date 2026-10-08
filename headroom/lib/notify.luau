--!nonstrict
-- Which notifications a new snapshot deserves, given the previous one.
--
-- Pure: compares two snapshots and returns the messages to send; the caller
-- sends them. Two kinds, each at most once per window per reset cycle:
--   low    usage crossed the critical threshold. `notified` remembers the
--          cycle (resetsAt) already warned about, and survives restarts
--          through the service's cache.
--   reset  a window that had reached the threshold started a new cycle:
--          the headroom is back.

local M = {}

export type Message = { kind: string, title: string, body: string }

export type Options = {
  critical: number,
  low: boolean, -- send "running low"
  reset: boolean, -- send "has reset"
  now: number,
  tr: (key: string, subst: { [string]: any }?) -> string,
  duration: (seconds: number) -> string,
}

-- Vendors jitter reset timestamps by fractions of a second; a new cycle moves
-- it by at least the window length, so a minute is a safe margin.
local NEW_CYCLE_MIN_SHIFT = 60

function M.messages(providerName: string, previous, current, notified: { [string]: number }, opts: Options): { Message }
  local out = {}
  if current == nil or not (opts.low or opts.reset) then
    return out
  end
  local before = {}
  for _, w in (previous and previous.windows or {}) do
    before[w.id] = w
  end

  for _, w in current.windows do
    local old = before[w.id]
    local cycle = w.resetsAt or 0

    local crossed = w.usedPercent >= opts.critical and (old == nil or old.usedPercent < opts.critical)
    if opts.low and crossed and notified[w.id] ~= cycle then
      notified[w.id] = cycle
      local percent = math.floor(w.usedPercent)
      table.insert(out, {
        kind = "low",
        title = opts.tr("notify.title", { provider = providerName }),
        body = if w.resetsAt
          then opts.tr("notify.body_reset", { window = w.label, percent = percent, reset = opts.duration(w.resetsAt - opts.now) })
          else opts.tr("notify.body", { window = w.label, percent = percent }),
      })
    end

    local newCycle = old ~= nil and old.resetsAt ~= nil and w.resetsAt ~= nil
      and w.resetsAt - old.resetsAt > NEW_CYCLE_MIN_SHIFT
    if opts.reset and newCycle and old.usedPercent >= opts.critical and w.usedPercent < old.usedPercent then
      table.insert(out, {
        kind = "reset",
        title = opts.tr("notify.reset_title", { provider = providerName, window = w.label }),
        body = opts.tr("notify.reset_body", { percent = math.floor(w.usedPercent) }),
      })
    end
  end
  return out
end

return M
