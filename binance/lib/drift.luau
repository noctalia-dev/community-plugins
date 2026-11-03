--!strict
-- Target allocation by asset class (allocation.ORDER) and per holding, and
-- how far the portfolio has drifted from it. Class targets are weights:
-- they are normalized, so 60/30/10 and 6/3/1 mean the same. Holding targets
-- are shares of the whole portfolio ("20% NVDA"). The deposit plan only buys, never
-- sells: the plugin stays read-only, so it can only suggest where the next
-- money goes.

local allocation = require("./allocation.luau")
local prefsLib = require("./prefs.luau")

local M = {}

M.DEFAULT_BAND = 0.05

export type Row = { id: string, value: number, share: number, target: number, diff: number }
export type AssetRow = { id: string, asset: string, class: string, value: number, share: number, target: number, diff: number }
export type Drift = { rows: { Row }, assets: { AssetRow }, band: number, off: { string }, crowded: { string }, total: number }
export type Step = { id: string, class: string, asset: string?, rest: boolean?, amount: number }

-- Weights per class -> shares summing to 1, or nil when no weight is set.
function M.targets(weights: { [string]: number? }): { [string]: number }?
  local sum = 0
  for _, id in allocation.ORDER do
    local w = weights[id]
    if type(w) == "number" and w > 0 then
      sum += w
    end
  end
  if sum <= 0 then
    return nil
  end
  local out = {}
  for _, id in allocation.ORDER do
    local w = weights[id]
    if type(w) == "number" and w > 0 then
      out[id] = w / sum
    end
  end
  return out
end

-- Target key of a holding: the prefs symbol convention, EQ_<TICKER> for a
-- stock and the asset code for everything else.
function M.key(kind: string, asset: string): string
  return if kind == "stock" then prefsLib.STOCK_PREFIX .. asset else asset
end

local function offBand(diff: number, band: number): boolean
  -- A tiny epsilon so a share exactly on the band edge stays inside.
  return math.abs(diff) > band + 1e-9
end

-- Class rows in allocation.ORDER for every class that is held or targeted
-- (none without class targets), then one row per holding target. Holding
-- targets are shares of the whole portfolio. `off` lists the class ids and
-- holding keys more than `band` from target; `crowded` the classes whose
-- holding targets add up to more than the class target.
function M.compute(
  holdings: { { kind: string, asset: string, value: number } },
  targets: { [string]: number }?,
  assetTargets: { [string]: number },
  band: number
): Drift?
  local slices = allocation.split(holdings)
  local byId: { [string]: allocation.Slice } = {}
  local total = 0
  for _, s in slices do
    byId[s.id] = s
    total += s.value
  end
  if total <= 0 then
    return nil
  end
  local held: { [string]: number } = {}
  for _, h in holdings do
    if h.value > 0 then
      local k = M.key(h.kind, h.asset)
      held[k] = (held[k] or 0) + h.value
    end
  end
  local keys = {}
  for k in assetTargets do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    if assetTargets[a] ~= assetTargets[b] then
      return assetTargets[a] > assetTargets[b]
    end
    return a < b
  end)
  local assets: { AssetRow } = {}
  local claimed: { [string]: number } = {}
  for _, k in keys do
    local stock = prefsLib.isStock(k)
    local asset = if stock then prefsLib.stockTicker(k) else k
    local class = allocation.classOf(if stock then "stock" else "spot", asset)
    local value = held[k] or 0
    local target = assetTargets[k]
    table.insert(assets, { id = k, asset = asset, class = class, value = value, share = value / total, target = target, diff = value / total - target })
    claimed[class] = (claimed[class] or 0) + target
  end

  local rows: { Row } = {}
  local off: { string } = {}
  if targets then
    for _, id in allocation.ORDER do
      local s = byId[id]
      local target = targets[id] or 0
      -- A class with a targeted holding gets a row even when it is neither
      -- held nor targeted, so its holding targets are checked against it.
      if s ~= nil or target > 0 or claimed[id] then
        local share = if s then s.share else 0
        local diff = share - target
        table.insert(rows, { id = id, value = if s then s.value else 0, share = share, target = target, diff = diff })
        if offBand(diff, band) then
          table.insert(off, id)
        end
      end
    end
  end
  for _, a in assets do
    if offBand(a.diff, band) then
      table.insert(off, a.id)
    end
  end
  local crowded: { string } = {}
  for _, r in rows do
    if (claimed[r.id] or 0) > r.target + 1e-9 then
      table.insert(crowded, r.id)
    end
  end
  return { rows = rows, assets = assets, band = band, off = off, crowded = crowded, total = total }
end

-- Splits `amount` of new money across what is below target, in proportion
-- to how much each is short once the amount is added. A targeted holding is
-- its own line; the rest of its class shares what the class target leaves
-- (`rest`). Returns { { id, amount, class, asset?, rest? } } without zero
-- entries: classes in allocation.ORDER, each holding before its class rest.
function M.plan(d: Drift, amount: number): { Step }
  local out: { Step } = {}
  if amount <= 0 then
    return out
  end
  local units: { { id: string, class: string, asset: string?, rest: boolean?, target: number, value: number } } = {}
  local placed: { [string]: boolean } = {}
  for _, r in d.rows do
    local tSum, vSum, has = 0, 0, false
    for _, a in d.assets do
      if a.class == r.id then
        table.insert(units, { id = a.id, class = a.class, asset = a.asset, target = a.target, value = a.value })
        placed[a.id] = true
        tSum += a.target
        vSum += a.value
        has = true
      end
    end
    table.insert(units, { id = r.id, class = r.id, rest = has, target = math.max(0, r.target - tSum), value = math.max(0, r.value - vSum) })
  end
  for _, a in d.assets do
    if not placed[a.id] then
      table.insert(units, { id = a.id, class = a.class, asset = a.asset, target = a.target, value = a.value })
    end
  end
  local after = d.total + amount
  local short, sum = {}, 0
  for i, u in units do
    local need = u.target * after - u.value
    if need > 0 then
      short[i] = need
      sum += need
    end
  end
  if sum <= 0 then
    return out
  end
  for i, u in units do
    local need = short[i]
    if need then
      -- Capped at the shortfall: with holding targets alone (adding up to
      -- less than 100%), what is left over stays unassigned.
      table.insert(out, { id = u.id, class = u.class, asset = u.asset, rest = if u.rest then true else nil, amount = amount * need / math.max(sum, amount) })
    end
  end
  return out
end

-- A typed amount, or nil. Separators: "1,250.50" and "1 250" drop them;
-- with both, the later one is the decimal mark ("1.250,50" is 1250.5); a
-- lone comma with one or two digits after it is a decimal comma ("250,50").
function M.parseAmount(text: string): number?
  local s = string.gsub(text, "%s", "")
  if not string.match(s, "^[%d.,]+$") then
    return nil
  end
  local lastDot, lastComma = string.find(s, "%.[^.]*$"), string.find(s, ",[^,]*$")
  if lastComma and (lastDot and lastComma > lastDot or not lastDot and string.find(s, ",%d%d?$")) then
    s = string.gsub(string.gsub(s, "%.", ""), ",", ".")
  else
    s = string.gsub(s, ",", "")
  end
  return tonumber(s)
end

-- Classes that just left the band (in `off` now, not flagged before), and the
-- flags to keep. A flag clears only once the class is well back inside
-- (REARM of the band), so a share hovering on the edge notifies once.
M.REARM = 0.8

function M.newlyOff(d: Drift, flagged: { string }): ({ string }, { string })
  local fresh, keep = {}, {}
  local all: { { id: string, diff: number } } = {}
  for _, r in d.rows do
    table.insert(all, r)
  end
  for _, a in d.assets do
    table.insert(all, a)
  end
  for _, r in all do
    local was = table.find(flagged, r.id) ~= nil
    if table.find(d.off, r.id) then
      if not was then
        table.insert(fresh, r.id)
      end
      table.insert(keep, r.id)
    elseif was and math.abs(r.diff) > d.band * M.REARM then
      table.insert(keep, r.id)
    end
  end
  return fresh, keep
end

return M
