--!nonstrict
-- Adapters against recorded vendor responses: the endpoints are undocumented
-- and change shape without notice.

local t = require("./support/t")
local env = require("./support/env")

local function ids(windows)
  local out = {}
  for _, w in windows do
    out[w.id] = w
  end
  return out
end

t.group("claude", function()
  t.test("usage, plan from the token's profile, and the reset grants", function()
    local host, p, ctx = env.provider("claude")
    env.claudeCreds(host, "tok")
    env.serveClaude(host, { tok = "a" })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    local w = ids(snapshot.windows)
    t.eq(w.session.usedPercent, 38)
    t.eq(w.weekly.periodSeconds, 7 * 86400)
    t.eq(w["weekly_scoped:Fable"].label, "Weekly · Fable")
    t.eq(snapshot.plan, "Ultra")
    -- Started, unpaused grants with resets left, soonest to expire first.
    t.eq(#snapshot.resetCredits, 2)
    t.eq(snapshot.resetCredits[1].label, "One full limit reset (September 2026)")
    t.eq(snapshot.resetCredits[1].expiresAt, 1790373600)
    t.ok(env.headerOf(host.requests[2], "User-Agent"):match("^claude%-cli/%d+%.%d+%.%d+ %(external, cli%)$"), "Claude Code user agent")
  end)

  t.test("identity comes from the token, asked once per token", function()
    local host, p, ctx = env.provider("claude")
    env.serveClaude(host, { one = "a", two = "b" })
    env.claudeCreds(host, "one")
    t.eq(p.accounts.identity(ctx), nil, "unknown before a fetch")
    env.fetch(p, ctx)
    env.fetch(p, ctx)
    t.eq(env.requestsTo(host, "/oauth/profile"), 1)
    t.eq(p.accounts.identity(ctx).id, "acct-a/org-a")
    -- `/login` as someone else: a new token, so whose it is must be asked again.
    env.claudeCreds(host, "two")
    t.eq(p.accounts.identity(ctx), nil)
    env.fetch(p, ctx)
    t.eq(p.accounts.identity(ctx).id, "acct-b/org-a")
  end)

  t.test("the grants come at most hourly, and a failed profile is asked again", function()
    local host, p, ctx = env.provider("claude")
    env.claudeCreds(host, "tok")
    local profileUp = false
    local serve = host.httpHandler
    env.serveClaude(host, { tok = "a" })
    serve = host.httpHandler
    host.httpHandler = function(req)
      if req.url:find("/oauth/profile", 1, true) and not profileUp then
        return { ok = false }
      end
      return serve(req)
    end
    local first = env.fetch(p, ctx)
    t.eq(first.plan, nil, "no profile, no plan")
    profileUp = true
    host.clock += 600
    local second = env.fetch(p, ctx)
    t.eq(second.plan, "Ultra", "profile asked again")
    t.eq(env.requestsTo(host, "cedar_ember=1"), 1, "grants not re-read within the hour")
    t.eq(#second.resetCredits, 2, "the last grants still shown")
  end)
end)

t.group("codex", function()
  t.test("windows, and reset credits with their expiry from the second endpoint", function()
    local host, p, ctx = env.provider("codex")
    env.codexAuth(host)
    env.serve(host, {
      ["wham/usage"] = env.fixture("codex_usage.json"),
      ["wham/rate-limit-reset-credits"] = env.fixture("codex_reset_credits.json"),
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.eq(#snapshot.windows, 2)
    t.eq(#snapshot.resetCredits, 2, "redeemed ones left out")
    t.eq(snapshot.resetCredits[1].expiresAt, 1790100000, "soonest first")
    t.eq(env.headerOf(host.requests[2], "ChatGPT-Account-Id"), "acct-1")
  end)

  t.test("no credits: no second request; credit list unreachable: the count alone", function()
    local host, p, ctx = env.provider("codex")
    env.codexAuth(host)
    local usage = env.decode(host, env.fixture("codex_usage.json"))
    usage.rate_limit_reset_credits.available_count = 0
    env.serve(host, { ["wham/usage"] = host.globals.noctalia.json.encode(usage) })
    local none = env.fetch(p, ctx)
    t.eq(none.resetCredits, nil)
    t.eq(env.requestsTo(host, "reset-credits"), 0)

    env.serve(host, {
      ["wham/usage"] = env.fixture("codex_usage.json"),
      ["wham/rate-limit-reset-credits"] = { ok = true, status = 429, body = "" },
    })
    local counted = env.fetch(p, ctx)
    t.eq(#counted.resetCredits, 1)
    t.eq(counted.resetCredits[1].count, 2)
    t.eq(counted.resetCredits[1].expiresAt, nil)
  end)
end)

t.group("antigravity", function()
  t.test("parses the quota summary and keeps distinct Gemini subgroup labels", function()
    local host, p, ctx = env.provider("antigravity")
    local payload = env.decode(host, env.fixture("antigravity_quota.json"))
    table.insert(payload.groups, {
      displayName = "Gemini 4 Argon",
      buckets = {
        {
          bucketId = "gemini-argon-wtu-weekly",
          window = "weekly",
          resetTime = "2026-10-11T01:11:18Z",
          remainingFraction = 1,
        },
      },
    })
    local snapshot, err = p.parse(payload, ctx)
    t.eq(err, nil)
    local w = ids(snapshot.windows)
    t.eq(w["gemini-weekly"].label, "Gemini · Weekly")
    t.eq(w["gemini-5h"].label, "Gemini · Session")
    t.eq(w["3p-weekly"].label, "Claude & GPT · Weekly")
    t.eq(w["gemini-argon-wtu-weekly"].label, "Gemini 4 Argon · Weekly")
  end)

  t.test("filters model groups according to antigravity_models", function()
    local host, p, ctx = env.provider("antigravity")
    local payload = env.decode(host, env.fixture("antigravity_quota.json"))
    table.insert(payload.groups, {
      displayName = "Gemini 4 Argon",
      buckets = {
        {
          bucketId = "gemini-argon-wtu-weekly",
          window = "weekly",
          resetTime = "2026-10-11T01:11:18Z",
          remainingFraction = 1,
        },
      },
    })

    host.config.antigravity_models = "gemini"
    local geminiOnly, err1 = p.parse(payload, ctx)
    t.eq(err1, nil)
    local gw = ids(geminiOnly.windows)
    t.ok(gw["gemini-weekly"] ~= nil, "keeps Gemini Models")
    t.ok(gw["gemini-argon-wtu-weekly"] ~= nil, "keeps Gemini 4 Argon")
    t.eq(gw["3p-weekly"], nil, "drops Claude & GPT weekly")
    t.eq(gw["3p-5h"], nil, "drops Claude & GPT 5h")

    host.config.antigravity_models = "claude_gpt"
    local thirdPartyOnly, err2 = p.parse(payload, ctx)
    t.eq(err2, nil)
    local tw = ids(thirdPartyOnly.windows)
    t.ok(tw["3p-weekly"] ~= nil, "keeps Claude & GPT")
    t.eq(tw["gemini-weekly"], nil, "drops Gemini Models")
    t.eq(tw["gemini-argon-wtu-weekly"], nil, "drops Gemini 4 Argon")

    -- Valid buckets filtered out completely return an empty snapshot rather than a parse error.
    local claudeOnly = { groups = { payload.groups[2] } }
    host.config.antigravity_models = "gemini"
    local emptySnap, err3 = p.parse(claudeOnly, ctx)
    t.eq(err3, nil)
    t.eq(#emptySnap.windows, 0)

    -- A payload with no valid buckets at all is still a parse error.
    local _, parseErr = p.parse({ groups = {} }, ctx)
    t.eq(parseErr.code, "parse")
  end)

  t.test("fetches live quota from daily-cloudcode-pa with a versioned hub User-Agent", function()
    local host, p, ctx = env.provider("antigravity")
    env.write(host, "/home/test/.gemini/antigravity-cli/antigravity-oauth-token", {
      access_token = "tok",
      expires_at = host.clock + 3600,
    })
    env.serve(host, {
      ["daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"] = env.fixture("antigravity_quota.json"),
      ["cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"] = '{"paidTier":{"name":"Google AI Pro"}}',
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.eq(snapshot.plan, "Google AI Pro")
    t.eq(env.requestsTo(host, "daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"), 1)
    t.ok(env.headerOf(host.requests[1], "User-Agent"):match("^antigravity/hub/%d+%.%d+%.%d+"), "versioned hub UA")
  end)
end)

return nil
