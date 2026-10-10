--!nonstrict
-- Claude (Pro / Max / Team / Enterprise subscriptions, as used by Claude Code).
--
-- Accounts: one per Claude Code config folder (ctx.home): the default
-- $CLAUDE_CONFIG_DIR or ~/.claude, folders Headroom added, and ~/.claude-*
-- folders found next to it (see lib/accounts.luau).
--
-- Credentials: the OAuth session Claude Code stores in <folder>/.credentials.json,
-- read-only. Headroom never refreshes or rewrites the token itself: refresh
-- tokens rotate, and spending one here could sign Claude Code out. When the
-- access token has expired, Claude Code renews it: we run
--   claude -p /status --no-session-persistence
-- (with CLAUDE_CONFIG_DIR set to the account's folder unless it is the
-- default), which starts the CLI's sign-in check (renewing and saving the
-- session), makes no model call and keeps no transcript, then read the
-- credentials again. Found folders are left to whoever runs Claude Code there.
--
-- Identity: the account and email in Claude Code's profile (~/.claude.json for
-- the default folder, <folder>/.claude.json for any other), for tooltips and to
-- spot one account signed in to two folders.
--
-- Endpoint: GET https://api.anthropic.com/api/oauth/usage, the one Claude Code's
-- own /usage screen reads. It is not a documented public API, so parsing is
-- defensive: every field of the `limits` array is treated as optional.

local provider = require("../../lib/provider.luau")
local renew = require("../../lib/renew.luau")
local model = require("../../lib/model.luau")
local time = require("../../lib/time.luau")

local E = model.ErrorCode

local USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
local RENEW_ARGS = { "-p", "/status", "--no-session-persistence" }
local CLAUDE_FALLBACKS = { "~/.local/bin/claude", "~/.claude/local/claude" }
local renewSession = renew.new(10 * 60, 30000)
local SESSION_SECONDS = model.SESSION_SECONDS
local WEEK_SECONDS = model.WEEK_SECONDS

local PLAN_NAMES = {
  pro = "Pro",
  max = "Max",
  team = "Team",
  enterprise = "Enterprise",
  free = "Free",
}

local function credentialsPath(ctx): string
  return `{ctx.home}/.credentials.json`
end

-- Claude Code keeps the profile beside its default folder (~/.claude.json)
-- and inside any other one, including ~/.claude named by CLAUDE_CONFIG_DIR.
local function profilePath(ctx): string
  local configured = ctx.env("CLAUDE_CONFIG_DIR")
  if (configured == nil or configured == "") and ctx.home == ctx.expandPath("~/.claude") then
    return ctx.expandPath("~/.claude.json")
  end
  return `{ctx.home}/.claude.json`
end

local function planLabel(oauth): string?
  local sub = oauth.subscriptionType
  if type(sub) ~= "string" or sub == "" then
    return nil
  end
  local name = PLAN_NAMES[sub] or (sub:sub(1, 1):upper() .. sub:sub(2))
  local multiplier = type(oauth.rateLimitTier) == "string" and oauth.rateLimitTier:match("max_(%d+)x")
  if multiplier then
    return `{name} {multiplier}x`
  end
  return name
end

-- "seven_day_oauth_apps" -> "Seven day oauth apps"
local function humanize(key: string): string
  local text = key:gsub("_", " ")
  return text:sub(1, 1):upper() .. text:sub(2)
end

local function fromLimits(limits, ctx): { model.Window }
  local windows = {}
  for _, limit in limits do
    if type(limit) ~= "table" or limit.percent == nil then
      continue
    end
    local resetsAt = time.parseIso8601(limit.resets_at)
    local period = if limit.group == "session" then SESSION_SECONDS
      elseif limit.group == "weekly" then WEEK_SECONDS
      else nil

    local scope = type(limit.scope) == "table" and limit.scope or nil
    local modelName = scope and type(scope.model) == "table" and scope.model.display_name or nil

    if limit.kind == "session" then
      table.insert(windows, model.window({
        id = "session", kind = "session", label = ctx.tr("window.session"),
        usedPercent = limit.percent, resetsAt = resetsAt, periodSeconds = SESSION_SECONDS,
      }))
    elseif limit.kind == "weekly_all" then
      table.insert(windows, model.window({
        id = "weekly", kind = "weekly", label = ctx.tr("window.weekly"),
        usedPercent = limit.percent, resetsAt = resetsAt, periodSeconds = WEEK_SECONDS,
      }))
    elseif modelName ~= nil then
      table.insert(windows, model.window({
        id = `{limit.kind}:{modelName}`, kind = "model",
        label = ctx.tr("window.weekly_model", { model = modelName }),
        usedPercent = limit.percent, resetsAt = resetsAt, periodSeconds = period,
      }))
    else
      table.insert(windows, model.window({
        id = tostring(limit.kind), kind = "other", label = humanize(tostring(limit.kind)),
        usedPercent = limit.percent, resetsAt = resetsAt, periodSeconds = period,
      }))
    end
  end
  return windows
end

local CURRENCY_SYMBOLS = { USD = "$", EUR = "€", GBP = "£" }

-- { amount_minor = 1230, exponent = 2, currency = "USD" } -> "$12.30"
local function money(value): string?
  if type(value) ~= "table" or type(value.amount_minor) ~= "number" then
    return nil
  end
  local exponent = tonumber(value.exponent) or 2
  local amount = value.amount_minor / (10 ^ exponent)
  local code = tostring(value.currency or "")
  local symbol = CURRENCY_SYMBOLS[code]
  local number = string.format(`%.{exponent}f`, amount)
  return if symbol then symbol .. number else `{number} {code}`
end

local function extraUsageNote(data, ctx): model.Note?
  local extra = data.extra_usage
  if type(extra) ~= "table" or extra.is_enabled ~= true then
    return nil
  end
  local spend = type(data.spend) == "table" and data.spend or {}
  local used = money(spend.used)
  local limit = money(spend.limit)
  local value = if used and limit then ctx.tr("note.of", { used = used, limit = limit })
    elseif used then used
    else ctx.tr("note.on")
  return { label = ctx.tr("note.extra_usage"), value = value }
end

-- Exposed for tests: vendor JSON -> Snapshot (or a parse error).
local function parse(data, oauth, ctx): (model.Snapshot?, model.ProviderError?)
  local windows = if type(data.limits) == "table" then fromLimits(data.limits, ctx) else {}
  if #windows == 0 then
    return nil, model.err(E.Parse, "no usage windows in response")
  end
  local notes = {}
  local extra = extraUsageNote(data, ctx)
  if extra then
    table.insert(notes, extra)
  end
  return model.snapshot({
    plan = planLabel(oauth or {}),
    windows = windows,
    notes = notes,
    fetchedAt = ctx.now(),
  }), nil
end

local function readOauth(ctx): (any, model.ProviderError?)
  local creds = ctx.readJson(credentialsPath(ctx))
  local oauth = type(creds) == "table" and creds.claudeAiOauth or nil
  if type(oauth) ~= "table" or type(oauth.accessToken) ~= "string" or oauth.accessToken == "" then
    return nil, model.err(E.NotConfigured)
  end
  if time.isExpired(oauth.expiresAt, ctx.now()) then
    return nil, model.err(E.Expired)
  end
  return oauth, nil
end

return provider.define({
  id = "claude",
  name = "Claude",
  brand = {
    logo = "providers/claude/logo.svg",
    tint = "#D97757",
    glyph = "sparkles",
    dashboard = "https://claude.ai/settings/usage",
  },

  accounts = {
    env = "CLAUDE_CONFIG_DIR",
    default = "~/.claude",
    siblingPrefix = ".claude-",
    command = "claude",
    fallbacks = CLAUDE_FALLBACKS,
    login = { "auth", "login" },
    identity = function(ctx)
      local profile = ctx.readJson(profilePath(ctx))
      local account = type(profile) == "table" and profile.oauthAccount or nil
      if type(account) ~= "table" or type(account.accountUuid) ~= "string" then
        return nil
      end
      -- One person can sit in several organizations, each with its own limits.
      local org = if type(account.organizationUuid) == "string" then account.organizationUuid else ""
      local email = if type(account.emailAddress) == "string" then account.emailAddress else nil
      return { id = `{account.accountUuid}/{org}`, email = email }
    end,
  },

  isConfigured = function(ctx)
    return ctx.fileExists(credentialsPath(ctx))
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.claude.hint")
  end,

  fetch = function(ctx, done)
    local function query(oauth)
      ctx.getJson(USAGE_URL, {
        ["Authorization"] = `Bearer {oauth.accessToken}`,
        ["anthropic-beta"] = "oauth-2025-04-20",
        ["User-Agent"] = ctx.userAgent,
      }, function(data, httpErr)
        if httpErr then
          done(nil, httpErr)
          return
        end
        done(parse(data, oauth, ctx))
      end)
    end

    local oauth, err = readOauth(ctx)
    if err == nil then
      query(oauth)
      return
    end
    local claude = if err.code == E.Expired and ctx.mayRenew then renew.findCommand(ctx, "claude", CLAUDE_FALLBACKS) else nil
    if claude == nil then
      done(nil, err)
      return
    end
    renewSession(ctx, ctx.inHome({ claude, table.unpack(RENEW_ARGS) }), function()
      local renewed, stillErr = readOauth(ctx)
      if stillErr then
        done(nil, stillErr)
      else
        query(renewed)
      end
    end)
  end,

  parse = parse,
})
