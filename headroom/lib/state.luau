--!nonstrict
-- The contract between the service (the only entry that fetches) and the
-- presentation entries (bar, panel). Each entry runs in its own Luau VM, so
-- they share data exclusively through these noctalia.state keys.

local M = {}

M.PANEL_ID = "ayagmar/headroom:panel"
M.VERSION = "0.2.0"

-- Published by the service:
--   {
--     lastRefreshAt: number?,      Unix seconds of the last completed fetch
--     providers: { ProviderView }, registry order, providers set to "off" left out
--   }
-- ProviderView:
--   { id, name, brand, hint,       hint: how to sign in, already translated
--     canAdd: boolean,             the CLI that signs accounts in is installed
--     accounts: { AccountView } }  the default first; at least one
-- AccountView (lib/accounts.luau):
--   { key,                         stable id; commands name accounts by it
--     kind: "default" | "added" | "found",
--     label: string?,              nil for the default account unless renamed
--     email: string?, home: string?,   for tooltips
--     launch: string?,             shell command starting the CLI as this account
--     status: "loading" | "ok" | "error" | "absent",   absent = not signed in
--     snapshot: Snapshot?,         last good data, kept through errors
--     error: ProviderError?,       current failure, with `hint` filled in
--     stale: boolean,              snapshot is from the disk cache or predates an error
--     busy: boolean,               a fetch is in flight
--     signingIn: boolean,          a login terminal was opened, sign-in pending
--     canSignIn: boolean,          Headroom can open the CLI's login for it
--     duplicateOf: string? }       name of an earlier account it is signed in to; not fetched
M.REPORT = "report"

-- Written by bar/panel, watched by the service. `at` makes repeats distinct.
--   { action = "refresh", maxAge? }
--   { action = "add", provider, label }    new account, then its login
--   { action = "sign_in", key }            the login, for an existing account
--   { action = "rename", key, label }      "" gives back the usual name
--   { action = "remove", key }             delete an added account, hide a found one
M.COMMAND = "command"

local function send(command)
  command.at = noctalia.nowMs()
  noctalia.state.set(M.COMMAND, command)
end

-- Asks the service for fresh data. `maxAge` (seconds) skips accounts fetched
-- more recently than that; without it every account is fetched.
function M.requestRefresh(maxAge: number?)
  send({ action = "refresh", maxAge = maxAge })
end

function M.addAccount(providerId: string, label: string)
  send({ action = "add", provider = providerId, label = label })
end

function M.signIn(key: string)
  send({ action = "sign_in", key = key })
end

function M.renameAccount(key: string, label: string)
  send({ action = "rename", key = key, label = label })
end

function M.removeAccount(key: string)
  send({ action = "remove", key = key })
end

-- Where a provider appears (its "Providers ·" setting): "bar" (bar and panel),
-- "panel" (panel only) or "off" (never fetched, never shown).
function M.providerMode(id: string): string
  local mode = M.config(`provider_{id}`, "bar")
  return if mode == "panel" or mode == "off" then mode else "bar"
end

-- Whether the bar shows only each provider's default account ("default") or
-- every signed-in account ("all").
function M.barShowsAllAccounts(): boolean
  return M.config("bar_accounts", "default") == "all"
end

-- Reads a config value with a fallback for unset or mistyped values.
function M.config(key: string, fallback: any): any
  local value = noctalia.getConfig(key)
  if value == nil or type(value) ~= type(fallback) then
    return fallback
  end
  return value
end

function M.thresholds(): (number, number)
  local warn = M.config("warn_percent", 70)
  local critical = M.config("critical_percent", 90)
  return math.min(warn, critical), critical
end

return M
