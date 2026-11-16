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
-- Identity: GET https://api.anthropic.com/api/oauth/profile with the same
-- token, once per token. Not Claude Code's profile file (~/.claude.json): every
-- running Claude Code session rewrites it, so after a `/login` it can name the
-- previous account for days, and two folders would look like one account.
-- The profile also names the plan ("Ultra", "Team").
--
-- Usage: GET https://api.anthropic.com/api/oauth/usage, the endpoint Claude
-- Code's /usage reads; at most hourly with ?cedar_ember=1, which adds the
-- account's free limit resets. Both endpoints are undocumented, so every field
-- is optional. Anthropic only lists the resets for Claude Code, so requests
-- carry Claude Code's User-Agent, with the installed version (`claude
-- --version`, once).

local provider = require("../../lib/provider.luau")
local renew = require("../../lib/renew.luau")
local model = require("../../lib/model.luau")
local time = require("../../lib/time.luau")

local E = model.ErrorCode

local USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
local PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
-- The reset grants come with the usage read at most this often: Anthropic
-- throttles that variant harder than the plain read.
local GRANTS_EVERY = 3600
-- Claude Code's version for the User-Agent until `claude --version` answers,
-- or when Claude Code isn't installed.
local KNOWN_VERSION = "2.1.322"
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

-- What the profile says about the plan: its own name ("Ultra"), else the
-- organization type with the tier's multiplier ("Team 5x").
local function planLabel(org): string?
  if type(org) ~= "table" then
    return nil
  end
  if type(org.plan_display_name) == "string" and org.plan_display_name ~= "" then
    return org.plan_display_name
  end
  local kind = type(org.organization_type) == "string" and org.organization_type:gsub("^claude_", "") or nil
  if kind == nil or kind == "" then
    return nil
  end
  local name = PLAN_NAMES[kind] or (kind:sub(1, 1):upper() .. kind:sub(2))
  local multiplier = type(org.rate_limit_tier) == "string" and org.rate_limit_tier:match("_(%d+)x$")
  return if multiplier then `{name} {multiplier}x` else name
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
    local surface = scope and type(scope.surface) == "string" and scope.surface or nil
    -- Limits scoped to a model or a surface share a kind; tell them apart.
    local id = tostring(limit.kind) .. (if modelName then `:{modelName}` else "") .. (if surface then `@{surface}` else "")

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
        id = id, kind = "model",
        label = ctx.tr(if limit.group == "session" then "window.session_model" else "window.weekly_model", { model = modelName }),
        usedPercent = limit.percent, resetsAt = resetsAt, periodSeconds = period,
      }))
    else
      table.insert(windows, model.window({
        id = id, kind = "other", label = humanize(surface or tostring(limit.kind)),
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

-- Free resets Anthropic grants (Settings > Usage, "Reset for free"): the ones
-- that have started and aren't paused, and how many of them can be spent now
-- (`usable_now`). model.snapshot drops the ended ones.
local function resetGrants(block, now: number): ({ model.ResetCredit }?, number?)
  if type(block) ~= "table" or block.eligible ~= true or type(block.grants) ~= "table" then
    return nil, nil
  end
  local out = {}
  local usable = 0
  for _, grant in block.grants do
    local left = type(grant) == "table" and tonumber(grant.resets_left) or 0
    local startsAt = time.toUnix(grant.starts_at)
    if left > 0 and grant.paused ~= true and (startsAt == nil or startsAt <= now) then
      table.insert(out, {
        count = left,
        label = if type(grant.label) == "string" and grant.label ~= "" then grant.label else nil,
        expiresAt = time.toUnix(grant.ends_at),
      })
      if grant.usable_now ~= false then
        usable += left
      end
    end
  end
  return out, usable
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

-- Vendor JSON -> Snapshot (or a parse error). `profile` is the
-- /api/oauth/profile answer for the token, for the plan name.
local function parse(data, profile, ctx): (model.Snapshot?, model.ProviderError?)
  local windows = if type(data.limits) == "table" then fromLimits(data.limits, ctx) else {}
  if #windows == 0 then
    return nil, model.err(E.Parse, "no usage windows in response")
  end
  local notes = {}
  local extra = extraUsageNote(data, ctx)
  if extra then
    table.insert(notes, extra)
  end
  local credits, usable = resetGrants(data.cedar_ember, ctx.now())
  return model.snapshot({
    plan = planLabel(type(profile) == "table" and profile.organization or nil),
    windows = windows,
    notes = notes,
    resetCredits = credits,
    resetsUsable = usable,
    fetchedAt = ctx.now(),
  }), nil
end

-- Per account folder, in memory; a restart asks again. `known`: whose its
-- current token is (stored only once the profile answered). `grants`: the
-- reset grants as last read with that token (re-read at most every
-- GRANTS_EVERY, and with each new token).
type Known = { token: string, profile: any }
local known: { [string]: Known } = {}
local grants: { [string]: { token: string, at: number, list: { model.ResetCredit }?, usable: number? } } = {}

-- One person can sit in several organizations, each with its own limits.
local function identityOf(profile): { id: string, email: string? }?
  local account = profile.account
  if type(account) ~= "table" or type(account.uuid) ~= "string" then
    return nil
  end
  local org = type(profile.organization) == "table" and profile.organization or {}
  local orgId = if type(org.uuid) == "string" then org.uuid else ""
  return { id = `{account.uuid}/{orgId}`, email = if type(account.email) == "string" then account.email else nil }
end

local cliVersion: string? = nil
local versionAsked = false

local function userAgent(ctx): string
  if not versionAsked then
    versionAsked = true
    local claude = renew.findCommand(ctx, "claude", CLAUDE_FALLBACKS)
    if claude then
      ctx.run({ claude, "--version" }, 5000, function(result)
        cliVersion = result and result.exitCode == 0 and result.stdout:match("^%s*(%d+%.%d+%.%d+)") or nil
      end)
    end
  end
  return `claude-cli/{cliVersion or KNOWN_VERSION} (external, cli)`
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
    dashboard = "https://claude.ai/settings/usage",
  },

  accounts = {
    env = "CLAUDE_CONFIG_DIR",
    default = "~/.claude",
    siblingPrefix = ".claude-",
    command = "claude",
    fallbacks = CLAUDE_FALLBACKS,
    login = { "auth", "login" },
    credentials = ".credentials.json",
    -- Known once the folder's current token has been fetched with.
    identity = function(ctx)
      local creds = ctx.readJson(credentialsPath(ctx))
      local oauth = type(creds) == "table" and creds.claudeAiOauth or nil
      local entry = known[ctx.home or ""]
      if entry == nil or type(oauth) ~= "table" or oauth.accessToken ~= entry.token then
        return nil
      end
      return identityOf(entry.profile)
    end,
  },

  isConfigured = function(ctx)
    return ctx.fileExists(credentialsPath(ctx))
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.claude.hint")
  end,

  fetch = function(ctx, done)
    local key = ctx.home or ""

    local function query(oauth)
      local headers = {
        ["Authorization"] = `Bearer {oauth.accessToken}`,
        ["anthropic-beta"] = "oauth-2025-04-20",
        ["User-Agent"] = userAgent(ctx),
      }
      local function usage(profile)
        local last = grants[key]
        local withGrants = last == nil or last.token ~= oauth.accessToken or ctx.now() - last.at >= GRANTS_EVERY
        if withGrants then
          -- Answered or not, the next reads go without them for a while: a
          -- rejected variant must not cost the usage itself.
          local same = last and last.token == oauth.accessToken
          last = { token = oauth.accessToken, at = ctx.now(), list = if same then last.list else nil, usable = if same then last.usable else nil }
          grants[key] = last
        end
        ctx.getJson(if withGrants then `{USAGE_URL}?cedar_ember=1` else USAGE_URL, headers, function(data, httpErr)
          if httpErr then
            done(nil, httpErr)
            return
          end
          local snapshot, parseErr = parse(data, profile, ctx)
          if snapshot and withGrants then
            last.list, last.usable = snapshot.resetCredits, snapshot.resetsUsable
          elseif snapshot then
            snapshot.resetCredits = model.resetCredits(last.list, ctx.now())
            snapshot.resetsUsable = last.usable
          end
          done(snapshot, parseErr)
        end)
      end
      local entry = known[key]
      if entry and entry.token == oauth.accessToken then
        usage(entry.profile)
        return
      end
      -- A new token: learn whose it is first. Without an answer the usage is
      -- still worth showing, just not tied to an account; the next fetch asks again.
      ctx.getJson(PROFILE_URL, headers, function(profile)
        if profile then
          known[key] = { token = oauth.accessToken, profile = profile }
        end
        usage(profile)
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
