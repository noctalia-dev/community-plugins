--!nonstrict
-- Number, money, time and color formatting shared by the bar, panel and
-- launcher, so every surface writes "$8,316.00" or "+1.82%" the same way.
--
-- Pure apart from translation lookups. Money arrives already converted to the
-- report currency (contract section 0); percentages are fractions.

local M = {}

-- What replaces an amount or quantity while privacy is on.
M.MASK = "••••"

local SYMBOLS = { USD = "$", EUR = "€" }

-- "1234567.891" -> "1,234,567.89" at `decimals` places, sign dropped.
function M.grouped(value: number, decimals: number): string
  local text = string.format(`%.{decimals}f`, math.abs(value))
  local int, frac = text:match("^(%d+)(.*)$")
  int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return int .. frac
end

local function signOf(value: number, signed: boolean?): string
  if value < 0 then
    return "−"
  elseif signed and value > 0 then
    return "+"
  end
  return ""
end

-- Decimals for a price: 2 above 1, then enough to show four significant
-- digits (0.08123, 0.00001234), capped at 8 as Binance quotes.
local function priceDecimals(value: number): number
  local v = math.abs(value)
  if v >= 1 or v == 0 then
    return 2
  end
  return math.min(8, math.floor(-math.log10(v)) + 4)
end

-- A money amount in the report currency.
--   opts.signed   prefix "+" on gains
--   opts.compact  "8.32k" / "1.2M" above 10 000, whole units above 1 000
--   opts.short    with compact: "8.3k" from 1 000 (narrow vertical bars)
--   opts.privacy  return the mask instead
function M.money(value: number?, currency: string?, opts): string
  opts = opts or {}
  if opts.privacy then
    return M.MASK
  end
  if value == nil then
    return "—"
  end
  local body
  local v = math.abs(value)
  if opts.compact and v >= 1e6 then
    body = string.format("%.2fM", v / 1e6)
  elseif opts.compact and (v >= 1e4 or (opts.short and v >= 1e3)) then
    body = string.format("%.1fk", v / 1e3)
  elseif opts.compact and v >= 1e3 then
    body = M.grouped(v, 0)
  else
    body = M.grouped(v, if v > 0 and v < 0.01 then priceDecimals(v) else 2)
  end
  local sign = signOf(value, opts.signed)
  local symbol = SYMBOLS[currency or ""]
  if symbol then
    return sign .. symbol .. body
  end
  -- USDT and anything unknown: the code after the number, as Binance does.
  return if currency then `{sign}{body} {currency}` else sign .. body
end

-- A unit price without currency (tickers carry their quote asset).
function M.price(value: number?): string
  if value == nil then
    return "—"
  end
  return M.grouped(value, priceDecimals(value))
end

-- A fraction as a percentage: 0.0182 -> "+1.82%". Signed by default;
-- `decimals` defaults to 2 (0 from 100% up).
function M.pct(fraction: number?, signed: boolean?, decimals: number?): string
  if fraction == nil then
    return ""
  end
  local p = fraction * 100
  local places = decimals or (if math.abs(p) >= 100 then 0 else 2)
  if math.abs(p) < 0.5 * 10 ^ -places then
    return M.grouped(0, places) .. "%"
  end
  return signOf(p, signed ~= false) .. M.grouped(p, places) .. "%"
end

-- A share of a whole: 0.4089 -> "40.9%".
function M.share(fraction: number): string
  return M.pct(fraction, false, 1)
end

-- A quantity: up to 8 decimals with trailing zeros trimmed, grouped above
-- 1 000 (where two decimals are plenty).
function M.qty(value: number?, privacy: boolean?): string
  if privacy then
    return M.MASK
  end
  if value == nil then
    return "—"
  end
  if math.abs(value) >= 1000 then
    return signOf(value) .. (M.grouped(value, 2):gsub("%.?0+$", ""))
  end
  local text = string.format("%.8f", math.abs(value)):gsub("0+$", ""):gsub("%.$", "")
  return signOf(value) .. text
end

-- The palette has no green role (src/ui/palette.h), and the accent reads as
-- "selected" rather than "up", so gains use a fixed market green. Losses keep
-- the theme's error role. The sign and arrow carry the meaning too.
-- (Kept on purpose, decision of 2026-10-19; see plugin.toml.)
M.GAIN = "#16a34a"

-- Color for a gain, a loss or nothing.
function M.signColor(value: number?): string
  if value == nil or value == 0 then
    return "on_surface_variant"
  end
  return if value > 0 then M.GAIN else "error"
end

-- A fraction that M.pct prints as "0.00%" counts as no change, so it gets no
-- color or arrow.
function M.pctSign(fraction: number?): number
  if fraction == nil or math.abs(fraction) < 0.00005 then
    return 0
  end
  return fraction
end

-- Direction of a P&L as shown: by its percentage when it has one.
function M.pnlSign(pnl): number
  if pnl == nil then
    return 0
  end
  if pnl.pct ~= nil then
    return M.pctSign(pnl.pct)
  end
  return pnl.pnl
end

function M.arrow(value: number?): string?
  if value == nil or value == 0 then
    return nil
  end
  return if value > 0 then "trending-up" else "trending-down"
end

-- ── Time ──────────────────────────────────────────────────────────────────

function M.now(): number
  return noctalia.nowMs()
end

-- Compact duration from milliseconds: "45s", "3m", "2h 5m", "4d".
function M.duration(ms: number): string
  local s = math.max(0, math.floor(ms / 1000))
  if s < 60 then
    return noctalia.tr("panel.time.seconds", { n = s })
  end
  local m = s // 60
  if m < 60 then
    local rest = s % 60
    if m < 5 and rest > 0 then
      return noctalia.tr("panel.time.minutes_seconds", { m = m, s = rest })
    end
    return noctalia.tr("panel.time.minutes", { n = m })
  end
  local h = m // 60
  if h < 48 then
    local rest = m % 60
    if rest > 0 and h < 10 then
      return noctalia.tr("panel.time.hours_minutes", { h = h, m = rest })
    end
    return noctalia.tr("panel.time.hours", { n = h })
  end
  return noctalia.tr("panel.time.days", { n = h // 24 })
end

-- "just now" / "5m ago" for a past timestamp in ms.
function M.ago(atMs: number?): string
  if atMs == nil then
    return "—"
  end
  local delta = M.now() - atMs
  if delta < 45000 then
    return noctalia.tr("panel.time.just_now")
  end
  return noctalia.tr("panel.time.ago", { d = M.duration(delta) })
end

-- "YYYY-MM-DD" -> "Oct 12", with the year when it is not the current one.
-- Month names come from one translation string so locales can reorder them.
local months: { string }? = nil

function M.day(day: string?, withYear: boolean?): string
  if type(day) ~= "string" then
    return ""
  end
  local y, m, d = day:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    return day
  end
  if months == nil then
    months = noctalia.tr("panel.months"):split(" ")
  end
  local name = months[tonumber(m)] or m
  local currentYear = os.date("!%Y", M.now() // 1000)
  if withYear or y ~= currentYear then
    return noctalia.tr("panel.date_year", { month = name, day = tonumber(d), year = y })
  end
  return noctalia.tr("panel.date", { month = name, day = tonumber(d) })
end

-- ── Errors ────────────────────────────────────────────────────────────────

-- Short title for an error code: "errors.<code>" (contract 3.1, owned by
-- the service's translations), else the code itself.
function M.errorTitle(code: string?): string
  if code == nil then
    return ""
  end
  local key = `errors.{code}`
  local text = noctalia.tr(key)
  if text ~= key then
    return text
  end
  local words = code:gsub("_", " ")
  return words:sub(1, 1):upper() .. words:sub(2)
end

return M
