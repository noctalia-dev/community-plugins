--!nonstrict
local M = {}

function M.num(s: string?): number
  return tonumber(s or "") or 0
end

local function daysFromCivil(y: number, m: number, d: number): number
  if m <= 2 then
    y -= 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function M.parseIso(s: string): number?
  local y, mo, d, h, mi, sec, sign, oh, om =
    string.match(s, "^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)([+-])(%d%d):?(%d%d)")
  if not y then
    return nil
  end
  local t = daysFromCivil(M.num(y), M.num(mo), M.num(d)) * 86400
    + M.num(h) * 3600 + M.num(mi) * 60 + M.num(sec)
  local offset = M.num(oh) * 3600 + M.num(om) * 60
  return sign == "-" and t + offset or t - offset
end

function M.decodeEntities(s: string): string
  s = string.gsub(s, "&lt;", "<")
  s = string.gsub(s, "&gt;", ">")
  s = string.gsub(s, "&quot;", '"')
  s = string.gsub(s, "&#39;", "'")
  s = string.gsub(s, "&amp;", "&")
  return s
end

return M
