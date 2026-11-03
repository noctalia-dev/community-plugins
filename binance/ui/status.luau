--!nonstrict
-- What is wrong right now, in priority order, derived from report.status.
-- The panel draws each issue as a banner; the bar swaps its glyph for the
-- first one and lists them in its tooltip. One place decides, so both agree.
--
-- Issue = { id, tone: "error" | "info", glyph, title, body?, action? }
-- action = "copy_install" | "retry_keyring" | "account" (the panel maps it).

local fmt = require("./fmt.luau")

local M = {}

M.INSTALL_CRYPTOGRAPHY = "sudo pacman -S python-cryptography"

-- Codes with their own issue, or that the service handles silently.
local HANDLED = {
  rate_limited = true,
  keyring_locked = true,
  no_secret_service = true,
  missing_dependency = true,
  busy = true,
  not_implemented = true,
}

-- Codes the user has to act on; everything else heals on a later refresh.
local ACTIONABLE = {
  auth_rejected = true,
  clock_skew = true,
  invalid_data_dir = true,
  unsupported_version = true,
  item_missing = true,
  keyring_corrupt = true,
  keyring_readback_failed = true,
}

local SOURCE_ORDER = { "prices", "balances", "stocks", "quotes", "flows", "trades" }

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

function M.issues(report): { any }
  local out = {}
  if type(report) ~= "table" or type(report.status) ~= "table" then
    return out
  end
  local status = report.status
  local now = fmt.now()

  if status.dependency then
    table.insert(out, {
      id = "dependency",
      tone = "error",
      glyph = "package",
      title = tr("panel.issue.dependency_title", { package = status.dependency }),
      body = tr("panel.issue.dependency_body", { command = M.INSTALL_CRYPTOGRAPHY }),
      action = "copy_install",
    })
  end

  if status.keyring == "locked" then
    table.insert(out, {
      id = "keyring",
      tone = "error",
      glyph = "lock",
      title = tr("panel.issue.keyring_locked_title"),
      body = tr("panel.issue.keyring_locked_body"),
      action = "retry_keyring",
    })
  elseif status.keyring == "no_service" then
    table.insert(out, {
      id = "keyring",
      tone = "error",
      glyph = "lock-off",
      title = tr("panel.issue.no_service_title"),
      body = tr("panel.issue.no_service_body"),
      action = "retry_keyring",
    })
  end

  local limit = status.rateLimit
  if limit and limit["until"] > now then
    local banned = limit.status == 418
    table.insert(out, {
      id = "rate_limit",
      tone = if banned then "error" else "info",
      glyph = "hourglass",
      title = tr(if banned then "panel.issue.banned_title" else "panel.issue.rate_limited_title"),
      body = tr(if limit.scope == "all" then "panel.issue.rate_limited_all" else "panel.issue.rate_limited_public", {
        left = fmt.duration(limit["until"] - now),
      }),
    })
  end

  -- One issue per remaining error code, naming the sources it affects.
  local byCode, codes = {}, {}
  for _, name in SOURCE_ORDER do
    local source = status.sources and status.sources[name]
    local err = source and source.error
    if err and not HANDLED[err.code] then
      if byCode[err.code] == nil then
        byCode[err.code] = { sources = {}, okAt = source.okAt, err = err }
        table.insert(codes, err.code)
      end
      local entry = byCode[err.code]
      table.insert(entry.sources, tr(`panel.source.{name}`))
      if source.okAt and (entry.okAt == nil or source.okAt < entry.okAt) then
        entry.okAt = source.okAt
      end
    end
  end
  for _, code in codes do
    local entry = byCode[code]
    local body = table.concat(entry.sources, ", ")
    if entry.okAt then
      body = tr("panel.issue.sources_updated", { sources = body, ago = fmt.ago(entry.okAt) })
    end
    local hint = tr(`panel.issue.hint.{code}`)
    if hint ~= `panel.issue.hint.{code}` then
      body = `{body}. {hint}`
    end
    table.insert(out, {
      id = `source_{code}`,
      tone = if ACTIONABLE[code] then "error" else "info",
      glyph = if ACTIONABLE[code] then "alert-circle" else "cloud-off",
      title = fmt.errorTitle(code),
      body = body,
      action = if code == "auth_rejected" or code == "item_missing" then "account" else "refresh",
    })
  end

  -- Stale with no error to explain it: data came from the disk cache.
  if status.stale and #out == 0 and status.lastRefreshAt then
    table.insert(out, {
      id = "stale",
      tone = "info",
      glyph = "clock",
      title = tr("panel.issue.stale_title", { ago = fmt.ago(status.lastRefreshAt) }),
    })
  end
  return out
end

-- Whether the Account tab needs the user (shown as a dot on the tab).
function M.accountNeedsAttention(report): boolean
  local account = type(report) == "table" and report.account or nil
  if account == nil then
    return false
  end
  return account.error ~= nil or account.stage == "awaiting_api_key" or account.stage == "awaiting_verify"
end

-- "Refreshing balances…" while a run is in flight, else nil.
function M.busyText(report): string?
  local status = type(report) == "table" and report.status or nil
  if status == nil or not status.busy then
    return nil
  end
  if status.busyWhat then
    return tr(`panel.busy.{status.busyWhat}`)
  end
  return tr("panel.busy.generic")
end

return M
