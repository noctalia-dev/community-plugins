--!nonstrict
-- Which notifications a new snapshot deserves.
--
-- Pure: reads the snapshot and the account's latches, updates the latches and
-- returns the messages; the caller sends them. The latches survive restarts
-- through the service's cache, so nothing is announced twice.
--
--   low     a window is at or above the critical threshold: once per cycle
--   reset   a window we warned about has started a new cycle
--   expiry  a reset credit expires within EXPIRY_NOTICE: once per credit

local M = {}

export type Message = { title: string, body: string }

-- window id -> { cycle = resetsAt } we warned about; "credit:..." -> its expiry
export type Latches = { [string]: any }

export type Options = {
  critical: number,
  enabled: boolean, -- low and reset messages
  credits: boolean, -- expiry messages
  interval: number, -- the refresh interval, seconds
  now: number,
  tr: (key: string, subst: { [string]: any }?) -> string,
  trp: (key: string, count: number, subst: { [string]: any }?) -> string,
  duration: (seconds: number) -> string,
}

-- Vendors jitter reset timestamps by fractions of a second; a new cycle moves
-- it by at least the window length.
local SAME_CYCLE = 60
M.EXPIRY_NOTICE = 48 * 3600

local function sameCycle(a: number?, b: number?): boolean
  if a == nil or b == nil then
    return a == b
  end
  return math.abs(a - b) <= SAME_CYCLE
end

function M.messages(name: string, snapshot, latches: Latches, opts: Options): { Message }
  local out = {}
  local seen = {}

  for _, w in snapshot.windows do
    seen[w.id] = true
    local latch = latches[w.id]
    if latch ~= nil and not sameCycle(latch.cycle, w.resetsAt) and w.usedPercent >= opts.critical then
      -- The reset time moved but usage is still high: the same warning holds.
      latch.cycle = w.resetsAt
    elseif latch ~= nil and not sameCycle(latch.cycle, w.resetsAt) then
      -- A new cycle. Announce it only if the old one ended recently: after a
      -- week offline, "has reset" is old news.
      local recent = latch.cycle ~= nil and opts.now - latch.cycle < 2 * opts.interval
      if opts.enabled and recent then
        table.insert(out, {
          title = opts.tr("notify.reset_title", { provider = name, window = w.label }),
          body = opts.tr("notify.reset_body", { percent = math.floor(w.usedPercent) }),
        })
      end
      latches[w.id] = nil
      latch = nil
    end
    if latch == nil and w.usedPercent >= opts.critical then
      latches[w.id] = { cycle = w.resetsAt }
      if opts.enabled then
        local percent = math.floor(w.usedPercent)
        table.insert(out, {
          title = opts.tr("notify.title", { provider = name }),
          body = if w.resetsAt
            then opts.tr("notify.body_reset", { window = w.label, percent = percent, reset = opts.duration(w.resetsAt - opts.now) })
            else opts.tr("notify.body", { window = w.label, percent = percent }),
        })
      end
    end
  end

  for _, credit in snapshot.resetCredits or {} do
    local expiresAt = credit.expiresAt
    if expiresAt and expiresAt - opts.now <= M.EXPIRY_NOTICE then
      local key = `credit:{expiresAt}:{credit.label or ""}`
      if not latches[key] then
        latches[key] = expiresAt
        if opts.credits then
          table.insert(out, {
            title = opts.trp("notify.credit_title", credit.count, { provider = name }),
            body = opts.tr("notify.credit_body", {
              credit = credit.label or opts.trp("resets.unnamed", credit.count),
              duration = opts.duration(expiresAt - opts.now),
            }),
          })
        end
      end
    end
  end

  -- Forget windows that are gone, and credits once they have expired: a reply
  -- without the credit list (one failed read) must not re-arm the notice.
  for key, value in latches do
    local credit = key:sub(1, 7) == "credit:"
    if (credit and not (type(value) == "number" and value > opts.now)) or (not credit and not seen[key]) then
      latches[key] = nil
    end
  end
  return out
end

return M
