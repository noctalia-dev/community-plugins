--!nonstrict
-- The contract between the service (the only entry that fetches or spawns the
-- helper) and the presentation entries (bar, panel, launcher). Each entry runs
-- in its own Luau VM, so they share data exclusively through these
-- noctalia.state keys. Shapes: contract.md section 3; reference values:
-- fixtures/snapshot*.json.

local M = {}

M.PANEL_ID = "ayagmar/binance:panel"
M.VERSION = 1

-- Published by the service after every change, a full replacement each time.
-- Report shape: contract section 3.1. Money is already in `currency`;
-- percentages are fractions; `?` fields may be absent.
M.REPORT = "report"

-- Published by the service in answer to a `lookup` command:
--   { query, at, results: { Ticker }, error: ErrorView? }
M.LOOKUP = "lookup"

-- Written by bar/panel/launcher, watched by the service. `at` makes repeats
-- distinct. Actions: contract section 3.3.
M.COMMAND = "command"

local function send(command)
  command.at = noctalia.nowMs()
  noctalia.state.set(M.COMMAND, command)
end

-- scope: "all" (default) | "prices" | "balances" | "stocks" | "flows"
-- ("flows" is only synced on request or daily; "all" leaves it out)
function M.requestRefresh(scope: string?)
  send({ action = "refresh", scope = scope })
end

-- Prices refresh every 30 s while the panel is open, 60 s otherwise.
function M.panelOpen(open: boolean)
  send({ action = "panel", open = open })
end

-- Connect wizard and account.
function M.keygen()
  send({ action = "keygen" })
end

function M.copyPublicKey()
  send({ action = "copy_public_key" })
end

function M.storeApiKey()
  send({ action = "store_api_key" })
end

function M.verify()
  send({ action = "verify" })
end

function M.disconnect()
  send({ action = "disconnect" })
end

function M.retryKeyring()
  send({ action = "retry_keyring" })
end

-- Preferences, persisted by the service in prefs.json.
function M.setPrivacy(value: boolean)
  send({ action = "set_privacy", value = value })
end

-- mode: "full" | "value" | "icon"
function M.setBarMode(mode: string)
  send({ action = "set_bar_mode", mode = mode })
end

-- Watchlist; symbols are exchange pairs such as "BTCUSDT".
function M.watchAdd(symbol: string)
  send({ action = "watch_add", symbol = symbol })
end

function M.watchRemove(symbol: string)
  send({ action = "watch_remove", symbol = symbol })
end

-- index is the 1-based target position.
function M.watchMove(symbol: string, index: number)
  send({ action = "watch_move", symbol = symbol, index = index })
end

-- Alerts. kind: "above" | "below" | "move_pct" (value is a fraction for
-- move_pct). cooldownMin defaults to 60.
function M.alertAdd(symbol: string, kind: string, value: number, cooldownMin: number?)
  send({ action = "alert_add", symbol = symbol, kind = kind, value = value, cooldownMin = cooldownMin })
end

-- fields: any of { kind, value, cooldownMin, enabled }
function M.alertUpdate(id: string, fields)
  local command = { action = "alert_update", id = id }
  for key, value in fields do
    command[key] = value
  end
  send(command)
end

-- A holding's target share of the portfolio (0-1), or nil to remove it.
function M.setAssetTarget(key: string, share: number?)
  send({ action = "set_asset_target", key = key, share = share })
end

function M.alertRemove(id: string)
  send({ action = "alert_remove", id = id })
end

-- preset: "7d" | "30d" | "ytd" | "all" | "custom" (from/to "YYYY-MM-DD").
function M.setRange(preset: string, from: string?, to: string?)
  send({ action = "set_range", preset = preset, from = from, to = to })
end

-- Writes holdings and the return on deposits to a CSV in the downloads
-- folder; the outcome arrives as report.export.
function M.exportCsv()
  send({ action = "export_csv" })
end

-- Keyless price lookup for the launcher; the answer arrives on M.LOOKUP.
function M.lookup(query: string)
  send({ action = "lookup", query = query })
end

return M
