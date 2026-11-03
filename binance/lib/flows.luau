--!nonstrict
-- Deposits and withdrawals from the helper's flows-daily.json: the return on
-- net deposits, flows inside a date range, and cumulative net deposits per
-- day. Pure. The helper values each flow in USD and EUR at flow time, so
-- EUR amounts never use today's rate.

local days = require("./days.luau")

local M = {}

-- Per-day sums of every completed flow, in USD and in EUR at flow-time rates.
export type Day = {
  n: number,
  inUsd: number,
  outUsd: number,
  inEur: number,
  outEur: number,
  valued: number, -- flows with a USD value
  noUsd: number, -- flows that could not be priced
  noEur: number, -- flows without a EUR amount (no price or no EURUSDT then)
  noEurUsd: number, -- USD value of the priced flows among noEur
}

export type Summary = {
  days: { Day }, -- oldest first, as the helper writes them
  count: number,
  at: number, -- when the helper last wrote the file
  ready: boolean, -- every source read back to its limit (or failed this run), every flow priced or unpriceable
  since: string?, -- day of the first flow
  uncovered: { string },
  coverage: { [string]: { fromMs: number, toMs: number, complete: boolean, error: string? } },
}

-- Parses flows-daily.json. The helper sums and orders the days, so this
-- stays small however many flows the account has.
function M.parse(raw): Summary?
  if type(raw) ~= "table" or type(raw.days) ~= "table" or type(raw.coverage) ~= "table" then
    return nil
  end
  local summary = { days = {}, count = tonumber(raw.count) or 0, at = tonumber(raw.at_ms) or 0, ready = true,
    since = raw.since_day, uncovered = {}, coverage = {} }
  for source, c in raw.coverage do
    if type(c) == "table" then
      local entry = {
        fromMs = tonumber(c.from_ms) or math.huge,
        toMs = tonumber(c.to_ms) or 0,
        complete = c.complete == true,
        error = c.error,
      }
      summary.coverage[source] = entry
      summary.ready = summary.ready and (entry.complete or entry.error ~= nil)
    end
  end
  for _, id in (type(raw.uncovered) == "table" and raw.uncovered) or {} do
    table.insert(summary.uncovered, id)
  end
  for _, d in raw.days do
    local n = type(d) == "table" and days.number(d.day or "")
    if n then
      table.insert(summary.days, {
        n = n,
        inUsd = tonumber(d.in_usd) or 0,
        outUsd = tonumber(d.out_usd) or 0,
        inEur = tonumber(d.in_eur) or 0,
        outEur = tonumber(d.out_eur) or 0,
        valued = tonumber(d.valued) or 0,
        noUsd = tonumber(d.no_usd) or 0,
        noEur = tonumber(d.no_eur) or 0,
        noEurUsd = tonumber(d.no_eur_usd) or 0,
      })
      -- Flows a later chunk will price: not counted as unpriced yet.
      summary.ready = summary.ready and (tonumber(d.awaiting) or 0) == 0
    end
  end
  return summary
end

-- Net amount deposited on one day in the display currency; flows without
-- an amount in it count as 0.
local function net(day: Day, eur: boolean): number
  return if eur then day.inEur - day.outEur else day.inUsd - day.outUsd
end

local function unpriced(day: Day, eur: boolean): boolean
  return (if eur then day.noEur else day.noUsd) > 0
end

-- Share of unpriced flows above which the return is withheld: below it the
-- return is published and the unpriced flows are named in `uncovered`.
M.UNPRICED_MAX_SHARE = 0.01

-- Value now minus inflows plus outflows, once every source is read. When
-- flows without an amount in the display currency are more than 1% of the
-- inflows, pnl and pct are left out and `unavailable` says why: a
-- pre-2020 EUR deposit left out would otherwise read as profit.
function M.netDeposit(summary: Summary?, value: number, eur: boolean)
  if summary == nil or not summary.ready or summary.since == nil then
    return nil
  end
  local inflow, outflow = 0, 0
  local inUsd, movedUsd, valued, noUsd, noEurUsd, missing = 0, 0, 0, 0, 0, 0
  for _, day in summary.days do
    inflow += if eur then day.inEur else day.inUsd
    outflow += if eur then day.outEur else day.outUsd
    inUsd += day.inUsd
    movedUsd += day.inUsd + day.outUsd
    valued += day.valued
    noUsd += day.noUsd
    noEurUsd += day.noEurUsd
    missing += if eur then day.noEur else day.noUsd
  end
  local uncovered = table.clone(summary.uncovered)
  local result = { since = summary.since, uncovered = uncovered }
  if missing > 0 then
    table.insert(uncovered, "unpriced_flows")
    -- In USD: their known USD value, and the average priced flow for each
    -- one without a price at all.
    local average = if valued > 0 then movedUsd / valued else math.huge
    local unpricedUsd = noUsd * average + (if eur then noEurUsd else 0)
    if inUsd <= 0 or unpricedUsd > M.UNPRICED_MAX_SHARE * inUsd then
      result.unavailable = "unpriced_flows"
      return result
    end
  end
  result.pnl = value - inflow + outflow
  local base = inflow - outflow
  result.pct = if base > 0 then result.pnl / base else nil
  return result
end

-- Whether flows are known for the whole of days fromN+1 .. toN: every
-- source read from before that span through the start of day toN, none
-- failed, and every flow in it priced.
function M.covers(summary: Summary?, fromN: number, toN: number, eur: boolean): boolean
  if summary == nil or not summary.ready then
    return false
  end
  for _, c in summary.coverage do
    if c.error ~= nil or c.fromMs > (fromN + 1) * days.DAY_MS or c.toMs < toN * days.DAY_MS then
      return false
    end
  end
  for _, day in summary.days do
    if day.n > fromN and day.n <= toN and unpriced(day, eur) then
      return false
    end
  end
  return true
end

-- Net deposits (in minus out) on days fromN+1 .. toN.
function M.netIn(summary: Summary, fromN: number, toN: number, eur: boolean): number
  local total = 0
  for _, day in summary.days do
    if day.n > fromN and day.n <= toN then
      total += net(day, eur)
    end
  end
  return total
end

-- Cumulative net deposits at the end of each day in `dayNumbers` (sorted).
function M.cumulative(summary: Summary, dayNumbers: { number }, eur: boolean): { number }
  local out, total, i = {}, 0, 1
  local list = summary.days
  for k, n in dayNumbers do
    while i <= #list and list[i].n <= n do
      total += net(list[i], eur)
      i += 1
    end
    out[k] = total
  end
  return out
end

return M
