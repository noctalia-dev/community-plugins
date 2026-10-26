--!nonstrict
-- The settled balance kept by month (spec §6.6, §9.4). A pass over every day since the
-- tracking start costs about 12 ms per year of data, against a CPU budget of 25 ms per
-- callback: the total of each past month is computed once, and again only when one of
-- its days changes. A first pass that does not fit in one call is spread over several.

local Model = require("./model.luau")
local Time = require("./time.luau")
local Types = require("./types.luau")

type Book = Types.Book
type Contract = Types.Contract
type Settled = Types.Settled

export type Totals = {
  -- A date's record, holiday or day off changed: its month is computed again.
  changed: (dateKey: string) -> (),
  -- The settled balance on `today`, or nil when the past months are not all computed
  -- after `sliceMs` (wall time): the next call goes on from there.
  summary: (today: string, sliceMs: number) -> Types.BalanceSummary?,
}

local Totals = {}

local function monthOf(dateKey: string): string
  return string.sub(dateKey, 1, 8) .. "01"
end

local function nextMonth(month: string): string
  local year, number = Time.parseDate(month)
  return Time.dateKey((year :: number) + (number :: number) // 12, (number :: number) % 12 + 1, 1)
end

local function sameContract(a: Contract, b: Contract): boolean
  if a.from ~= b.from or a.weeklyHours ~= b.weeklyHours then
    return false
  end
  for day = 1, 7 do
    if a.targets[day] ~= b.targets[day] then
      return false
    end
  end
  return true
end

-- First date whose target may differ between two contract histories; "" for every date
-- (the first contract also applies before it starts), nil when they are the same.
local function divergence(old: { Contract }?, new: { Contract }?): string?
  local a, b = old or {}, new or {}
  for i = 1, math.max(#a, #b) do
    local x, y = a[i], b[i]
    if not x or not y or not sameContract(x, y) then
      if i == 1 then
        return ""
      end
      local from = (x or y).from
      return if x and y and y.from < from then y.from else from
    end
  end
  return nil
end

-- `clock` gives seconds (os.clock): the slices are measured with it.
function Totals.new(book: Book, clock: () -> number): Totals
  -- Past months by first day: the settled days of the month from `from`, the month's
  -- first day or the tracking start when it falls within.
  local months: { [string]: { from: string, settled: Settled } } = {}
  local contracts: { Contract }? = book.balance.contractHistory

  local totals = {}

  function totals.changed(dateKey: string)
    months[monthOf(dateKey)] = nil
  end

  function totals.summary(today: string, sliceMs: number): Types.BalanceSummary?
    local balance = book.balance
    local since = divergence(contracts, balance.contractHistory)
    if since then
      local first = since ~= "" and monthOf(since) or ""
      for month in months do
        if month >= first then
          months[month] = nil
        end
      end
    end
    contracts = balance.contractHistory

    local deadline = clock() + sliceMs / 1000
    local start, current = balance.trackingStart, monthOf(today)
    local delta, toReview, needsReview = 0, {}, {}
    local function add(settled: Settled)
      delta += settled.deltaMs
      table.move(settled.toReview, 1, #settled.toReview, #toReview + 1, toReview)
      table.move(settled.needsReview, 1, #settled.needsReview, #needsReview + 1, needsReview)
    end
    local month, computed = monthOf(start), false
    while month < current do
      local from = if start > month then start else month
      local entry = months[month]
      if not entry or entry.from ~= from then
        -- At least one month per call, so that the next ones always get closer.
        if computed and clock() > deadline then
          return nil
        end
        entry = { from = from, settled = Model.settle(book, from, nextMonth(month)) }
        months[month] = entry
        computed = true
      end
      add(entry.settled)
      month = nextMonth(month)
    end
    add(Model.settle(book, if start > current then start else current, today))
    return Model.balanceOf(balance, { deltaMs = delta, toReview = toReview, needsReview = needsReview })
  end

  return totals
end

return Totals
