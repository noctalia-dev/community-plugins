--!nonstrict
-- Codex (ChatGPT Plus / Pro / Business / Enterprise plans, as used by the Codex CLI).
--
-- Credentials: the ChatGPT sign-in the Codex CLI stores in
--   $CODEX_HOME/auth.json   (default ~/.codex/auth.json)
-- read-only, for the same reason as the Claude adapter: the Codex CLI owns
-- token refresh. API-key-only setups have no plan limits to report.
--
-- Endpoint: GET https://chatgpt.com/backend-api/wham/usage, the one the Codex
-- CLI's /status reads. Undocumented, so every field is treated as optional.

local provider = require("../../lib/provider.luau")
local model = require("../../lib/model.luau")
local time = require("../../lib/time.luau")
local jwt = require("../../lib/jwt.luau")

local E = model.ErrorCode

local USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
local AUTH_CLAIMS = "https://api.openai.com/auth"

local PLAN_NAMES = {
  free = "Free",
  plus = "Plus",
  pro = "Pro",
  team = "Business",
  business = "Business",
  enterprise = "Enterprise",
  edu = "Edu",
}

local function authPath(ctx): string
  local home = ctx.env("CODEX_HOME")
  if home ~= nil and home ~= "" then
    return `{home}/auth.json`
  end
  return ctx.expandPath("~/.codex/auth.json")
end

local function planLabel(planType: any): string?
  if type(planType) ~= "string" or planType == "" then
    return nil
  end
  return PLAN_NAMES[planType] or (planType:sub(1, 1):upper() .. planType:sub(2))
end

-- Classifies a window by its length, so a vendor change from 5h to 4h, or the
-- addition of a monthly window, still lands in the right bar slot.
local function kindFor(seconds: number?): string
  if seconds == nil then
    return "other"
  elseif seconds <= 12 * 3600 then
    return "session"
  elseif seconds >= 6 * 86400 and seconds <= 8 * 86400 then
    return "weekly"
  end
  return "other"
end

local function toWindow(raw, id: string, label: string?, ctx, now: number): model.Window?
  if type(raw) ~= "table" or raw.used_percent == nil then
    return nil
  end
  local period = tonumber(raw.limit_window_seconds)
  local resetsAt = time.toUnix(raw.reset_at)
  if resetsAt == nil and tonumber(raw.reset_after_seconds) then
    resetsAt = now + tonumber(raw.reset_after_seconds)
  end
  local kind = kindFor(period)
  return model.window({
    id = id,
    kind = if label then "other" else kind,
    label = label or (if kind == "other" and period then ctx.duration(period) else ctx.tr(`window.{kind}`)),
    usedPercent = raw.used_percent,
    resetsAt = resetsAt,
    periodSeconds = period,
  })
end

-- { primary_window, secondary_window } -> windows, optionally under a feature label.
local function collect(windows, rateLimit, prefix: string, label: string?, ctx, now)
  if type(rateLimit) ~= "table" then
    return
  end
  for _, slot in { "primary_window", "secondary_window" } do
    local raw = rateLimit[slot]
    local slotLabel = label
    if label and type(raw) == "table" and tonumber(raw.limit_window_seconds) then
      slotLabel = `{label} · {ctx.duration(tonumber(raw.limit_window_seconds))}`
    end
    local w = toWindow(raw, `{prefix}{slot}`, slotLabel, ctx, now)
    if w then
      table.insert(windows, w)
    end
  end
end

local function creditsNote(credits, ctx): model.Note?
  if type(credits) ~= "table" then
    return nil
  end
  if credits.unlimited == true then
    return { label = ctx.tr("note.credits"), value = ctx.tr("note.unlimited") }
  end
  if credits.has_credits == true then
    return { label = ctx.tr("note.credits"), value = tostring(credits.balance or "0") }
  end
  return nil
end

local function parse(data, fallbackPlan: string?, ctx): (model.Snapshot?, model.ProviderError?)
  local now = ctx.now()
  local windows = {}
  collect(windows, data.rate_limit, "", nil, ctx, now)
  collect(windows, data.code_review_rate_limit, "code_review:", ctx.tr("window.code_review"), ctx, now)
  if type(data.additional_rate_limits) == "table" then
    for i, extra in data.additional_rate_limits do
      if type(extra) == "table" then
        local name = extra.limit_name or extra.metered_feature or `#{i}`
        collect(windows, extra.rate_limit or extra, `extra:{name}:`, tostring(name), ctx, now)
      end
    end
  end
  if #windows == 0 then
    return nil, model.err(E.Parse, "no usage windows in response")
  end
  local notes = {}
  local credits = creditsNote(data.credits, ctx)
  if credits then
    table.insert(notes, credits)
  end
  return model.snapshot({
    plan = planLabel(data.plan_type) or fallbackPlan,
    windows = windows,
    notes = notes,
    fetchedAt = now,
  }), nil
end

return provider.define({
  id = "codex",
  name = "Codex",
  brand = {
    logo = "providers/codex/logo.svg",
    tint = "on_surface",
    glyph = "brand-openai",
    dashboard = "https://chatgpt.com/codex/settings/usage",
  },

  isConfigured = function(ctx)
    return ctx.fileExists(authPath(ctx))
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.codex.hint")
  end,

  fetch = function(ctx, done)
    local auth = ctx.readJson(authPath(ctx))
    local tokens = type(auth) == "table" and auth.tokens or nil
    if type(tokens) ~= "table" or type(tokens.access_token) ~= "string" or tokens.access_token == "" then
      done(nil, model.err(E.NotConfigured))
      return
    end

    local access = jwt.claims(tokens.access_token, ctx.decodeJson)
    if access and time.isExpired(access.exp, ctx.now()) then
      done(nil, model.err(E.Expired))
      return
    end
    local identity = jwt.claims(tokens.id_token, ctx.decodeJson)
    local claims = identity and identity[AUTH_CLAIMS]
    local fallbackPlan = type(claims) == "table" and planLabel(claims.chatgpt_plan_type) or nil

    local headers = {
      ["Authorization"] = `Bearer {tokens.access_token}`,
      ["User-Agent"] = ctx.userAgent,
    }
    if type(tokens.account_id) == "string" and tokens.account_id ~= "" then
      headers["ChatGPT-Account-Id"] = tokens.account_id
    end
    ctx.getJson(USAGE_URL, headers, function(data, err)
      if err then
        done(nil, err)
        return
      end
      done(parse(data, fallbackPlan, ctx))
    end)
  end,

  parse = parse,
})
