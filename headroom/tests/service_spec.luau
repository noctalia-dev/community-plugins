--!nonstrict
-- The poller end to end, against a fake host: accounts, identity, failures,
-- restarts.

local t = require("./support/t")
local env = require("./support/env")

local WORK = "/home/test/.claude-work"

local function claudeOnly(host)
  host.config.provider_codex = "off"
  host.config.provider_antigravity = "off"
end

t.group("service", function()
  t.test("a folder switched to another account is not mistaken for a copy", function()
    -- The bug: two folders, then a `/login` swap. Identity read from Claude
    -- Code's profile file lagged the token, so one account showed twice.
    local host = env.host()
    claudeOnly(host)
    env.claudeCreds(host, "tok-a")
    env.claudeCreds(host, "tok-b", WORK)
    env.serveClaude(host, { ["tok-a"] = "a", ["tok-b"] = "b", ["tok-a2"] = "a", ["tok-c"] = "c" })
    local svc = env.start(host, "service.luau")
    t.eq(env.account(host, "claude").phase, "ready")
    t.eq(env.account(host, `claude:{WORK}`).phase, "ready")

    -- The work folder signs in to the default's account: now a copy, hidden.
    env.claudeCreds(host, "tok-a2", WORK)
    env.advance(host, svc, 30)
    t.eq(env.account(host, `claude:{WORK}`), nil, "a found copy is left out")

    -- And to a third account: shown again, with its own numbers.
    env.claudeCreds(host, "tok-c", WORK)
    env.advance(host, svc, 30)
    local work = env.account(host, `claude:{WORK}`)
    t.ok(work and work.duplicateOf == nil, "listed again")
    t.eq(work.phase, "ready")
    t.eq(work.email, "c@example.com")
  end)

  t.test("a found copy stays hidden across a restart", function()
    -- After a restart no token is identified yet; the copy, fetched first
    -- because its numbers are older, must not show up as a second account.
    local host = env.host()
    claudeOnly(host)
    env.claudeCreds(host, "tok-a")
    env.claudeCreds(host, "tok-a2", WORK)
    env.serveClaude(host, { ["tok-a"] = "a", ["tok-a2"] = "a" })
    local svc = env.start(host, "service.luau")
    t.eq(env.account(host, `claude:{WORK}`), nil)
    for _ = 1, 11 do
      env.advance(host, svc, 30) -- the default is fetched again; the copy is not
    end
    host.watchers = {}
    svc = env.start(host, "service.luau")
    t.eq(env.account(host, `claude:{WORK}`), nil, "still a copy")
    for _ = 1, 4 do
      env.advance(host, svc, 30)
    end
    t.eq(env.account(host, `claude:{WORK}`), nil, "still a copy once both are known")
    t.eq(env.account(host, "claude").phase, "ready")
  end)

  t.test("numbers and alerts of the previous account go with it", function()
    local host = env.host()
    claudeOnly(host)
    host.config.critical_percent = 90
    env.claudeCreds(host, "tok-a")
    local usage = env.decode(host, env.fixture("claude_usage.json"))
    usage.limits[2].percent = 95
    env.serveClaude(host, { ["tok-a"] = "a", ["tok-b"] = "b" }, host.globals.noctalia.json.encode(usage))
    local svc = env.start(host, "service.luau")
    t.eq(#host.notifications, 1, "running low")

    -- `/login` as someone at 10%: no "has reset" for a reset that never happened.
    usage.limits[2].percent = 10
    env.serveClaude(host, { ["tok-a"] = "a", ["tok-b"] = "b" }, host.globals.noctalia.json.encode(usage))
    env.claudeCreds(host, "tok-b")
    env.advance(host, svc, 30)
    t.eq(#host.notifications, 1)
    t.eq(env.account(host, "claude").email, "b@example.com")
  end)

  t.test("a request that never answers fails and backs off", function()
    local host = env.host()
    claudeOnly(host)
    env.claudeCreds(host, "tok")
    host.httpHandler = nil -- nothing ever answers
    local svc = env.start(host, "service.luau")
    t.ok(env.account(host, "claude").busy, "in flight")
    for _ = 1, 21 do
      env.advance(host, svc, 5)
    end
    local claude = env.account(host, "claude")
    t.eq(claude.phase, "failing")
    t.eq(claude.error.code, "network")
    t.eq(claude.busy, false)
    t.eq(#host.requests, 1, "not retried while it was out")
  end)

  t.test("an adapter that throws on a reply fails visibly", function()
    local host = env.host()
    claudeOnly(host)
    env.claudeCreds(host, "tok")
    env.serve(host, { ["/oauth/profile"] = "{}", ["/oauth/usage"] = '{"limits": [{"kind": "session", "percent": 5, "resets_at": "2026-10-03T20:19:59Z"}]}' })
    -- The date parser throws inside the reply.
    host.globals.os.time = function(tbl)
      if tbl then
        error("boom")
      end
      return host.clock
    end
    env.start(host, "service.luau")
    local claude = env.account(host, "claude")
    t.eq(claude.phase, "failing")
    t.eq(claude.busy, false)
  end)

  t.test("a sign-in with nothing usable in it is not an error", function()
    local host = env.host()
    host.config.provider_claude = "off"
    host.config.provider_antigravity = "off"
    env.write(host, "/home/test/.codex/auth.json", { auth_mode = "apikey", OPENAI_API_KEY = "sk-x" })
    env.start(host, "service.luau")
    local codex = env.account(host, "codex")
    t.eq(codex.phase, "signed_out")
    t.eq(codex.error, nil)
  end)

  t.test("after a restart, recent numbers are reused and old owners are dropped", function()
    local host = env.host()
    claudeOnly(host)
    env.claudeCreds(host, "tok-a")
    env.serveClaude(host, { ["tok-a"] = "a", ["tok-b"] = "b" })
    env.start(host, "service.luau")
    t.eq(#host.requests, 2, "profile and usage")

    host.clock += 60
    host.requests, host.watchers = {}, {}
    env.start(host, "service.luau")
    t.eq(#host.requests, 0, "a minute-old fetch is still current")
    t.eq(env.account(host, "claude").phase, "ready")

    -- Restarted after a `/login` to another account: the cached numbers go
    -- as soon as the new token's owner is known.
    env.claudeCreds(host, "tok-b")
    host.watchers = {}
    local svc = env.start(host, "service.luau")
    t.eq(env.account(host, "claude").email, "b@example.com")
    t.eq(env.account(host, "claude").phase, "ready")
    t.ok(svc, "started")
  end)

  t.test("a throttled account is not fetched early by a manual refresh", function()
    local host = env.host()
    claudeOnly(host)
    env.claudeCreds(host, "tok")
    env.serve(host, { ["/oauth/profile"] = "{}", ["/oauth/usage"] = { ok = true, status = 429, body = "" } })
    local svc = env.start(host, "service.luau")
    t.eq(env.account(host, "claude").error.code, "rate_limited")
    local before = #host.requests
    svc.call("onIpc", "refresh")
    env.advance(host, svc, 60)
    t.eq(#host.requests, before)
  end)

  t.test("a long account name is cut on a character boundary", function()
    local host = env.host()
    claudeOnly(host)
    env.claudeCreds(host, "tok")
    env.serveClaude(host, { tok = "a" })
    env.start(host, "service.luau")
    local name = string.rep("名", 40)
    host.globals.noctalia.state.set("command", { action = "rename", key = "claude", label = name })
    t.eq(utf8.len(env.account(host, "claude").name), 32)
  end)
end)

return nil
