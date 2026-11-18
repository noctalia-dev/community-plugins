--!nonstrict
-- The portfolio export: holdings and the return on deposits as CSV, built
-- from a published report (amounts already in report.currency). Pure.

local M = {}

-- One text cell. Quoted when it holds a comma, quote or line break; a cell a
-- spreadsheet would read as a formula (= + - @, or a leading tab or CR) gets
-- a leading apostrophe. Asset names come from Binance, so they are text.
function M.text(value: string?): string
  local s = value or ""
  if string.match(s, "^[=+%-@\t\r]") then
    s = "'" .. s
  end
  if string.find(s, '[,"\r\n]') then
    s = '"' .. string.gsub(s, '"', '""') .. '"'
  end
  return s
end

-- A number cell, never in exponent form; empty when unknown. Numbers are
-- written by the plugin, so a minus sign is a sign, not a formula.
function M.number(value: number?, decimals: number?): string
  if value == nil or value ~= value then
    return ""
  end
  local s = string.format(`%.{decimals or 8}f`, value)
  if string.find(s, ".", 1, true) then
    s = (string.gsub(s, "0+$", ""))
    s = (string.gsub(s, "%.$", ""))
  end
  return if s == "-0" then "0" else s
end

local function row(cells: { string }): string
  return table.concat(cells, ",")
end

local function pct(fraction: number?): string
  return M.number(if fraction ~= nil then fraction * 100 else nil, 4)
end

-- `stamp` is the export time as text ("2026-10-19 14:05").
function M.build(report, stamp: string): string
  local cur = report.currency
  local lines = {
    row({ M.text("Binance portfolio"), M.text(stamp), M.text(`currency {cur}`) }),
    "",
    row({ "kind", "asset", "quantity", "price", "value", "avg_cost", "cost", "unrealized_pnl", "unrealized_pct" }),
  }
  for _, h in report.holdings or {} do
    local floating = h.floating or {}
    table.insert(lines, row({
      M.text(h.kind),
      M.text(h.asset),
      M.number(h.qty),
      M.number(h.price),
      M.number(h.value, 2),
      M.number(h.avgCost),
      M.number(h.cost, 2),
      M.number(floating.pnl, 2),
      pct(floating.pct),
    }))
  end

  table.insert(lines, "")
  table.insert(lines, row({ "return", "from", "to", "kind", "start_value", "end_value", "net_deposits", "pnl", "pct" }))
  local totals = report.totals or {}
  local net = totals.netDeposit
  if net ~= nil then
    table.insert(lines, row({
      "since_first_deposit",
      M.text(net.since),
      "",
      "net_of_flows",
      "",
      M.number(totals.value, 2),
      M.number(totals.value - net.pnl, 2),
      M.number(net.pnl, 2),
      pct(net.pct),
    }))
  end
  local range = report.range
  if range ~= nil and range.error == nil then
    table.insert(lines, row({
      M.text(range.preset),
      M.text(range.from),
      M.text(range.to),
      M.text(range.kind),
      M.number(range.startValue, 2),
      M.number(range.endValue, 2),
      "",
      M.number(range.pnl, 2),
      pct(range.pct),
    }))
  end
  return table.concat(lines, "\n") .. "\n"
end

-- XDG_DOWNLOAD_DIR from user-dirs.dirs text ("$HOME/Downloads"), or nil.
function M.downloadDir(userDirs: string?, home: string): string?
  local value = userDirs and string.match("\n" .. userDirs, '\nXDG_DOWNLOAD_DIR="([^"\n]*)"')
  if value == nil or value == "" then
    return nil
  end
  value = string.gsub(value, "^%$HOME", home)
  return if string.sub(value, 1, 1) == "/" then value else nil
end

return M
