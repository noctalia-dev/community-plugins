--!nonstrict
-- Shared setup for specs: a fake host with the plugin's assets, sign-ins to
-- write into it, and scripted vendor endpoints.

local sources = require("../_generated/sources")
local hostLib = require("./host")
local loader = require("./loader")

local M = {}

M.sources = sources
M.find = hostLib.find

M.CLAUDE_HOME = "/home/test/.claude"
M.CODEX_HOME = "/home/test/.codex"

-- JWTs (alg none) whose exp is relative to the host's default clock 1_790_000_000.
M.JWT_VALID = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3OTAwMDM2MDB9.sig"
M.JWT_ID_PRO = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9wbGFuX3R5cGUiOiJwcm8ifX0.sig"

function M.host()
  local host = hostLib.new(sources)
  for path, content in sources do
    if path:match("%.svg$") then
      host.files[path] = content
    end
  end
  host.files["/plugin/plugin.toml"] = sources["plugin.toml"]
  return host
end

function M.start(host, entryPath: string)
  return loader.entry(sources, host, entryPath).start()
end

function M.modules(host)
  return loader.entry(sources, host, "service.luau")
end

function M.fixture(name: string): string
  return assert(sources[`tests/fixtures/{name}`], `missing fixture {name}`)
end

function M.decode(host, text: string)
  return host.globals.noctalia.json.decode(text)
end

local writes = 0

-- Writes a file the way a CLI would: a new mtime each time.
function M.write(host, path: string, value)
  writes += 1
  host.files[path] = if type(value) == "string" then value else host.globals.noctalia.json.encode(value)
  host.mtimes[path] = host.clock + writes
end

-- Claude Code's sign-in in `home` (default: ~/.claude).
function M.claudeCreds(host, token: string, home: string?)
  M.write(host, `{home or M.CLAUDE_HOME}/.credentials.json`, {
    claudeAiOauth = { accessToken = token, expiresAt = (host.clock + 3600) * 1000, subscriptionType = "max" },
  })
end

-- The Claude endpoints. `accounts` maps an access token to the account it
-- belongs to ("a" -> uuid "acct-a"); the profile endpoint answers from it, so
-- identity follows the token, as it does at Anthropic.
function M.serveClaude(host, accounts: { [string]: string }, usage: string?)
  local json = host.globals.noctalia.json
  host.httpHandler = function(req)
    local token = M.headerOf(req, "Authorization"):match("Bearer (.+)")
    if req.url:find("/api/oauth/profile", 1, true) then
      local who = accounts[token]
      local profile = json.decode(M.fixture("claude_profile.json"))
      profile.account.uuid, profile.account.email = `acct-{who}`, `{who}@example.com`
      return { ok = true, status = 200, body = json.encode(profile) }
    end
    local data = json.decode(usage or M.fixture("claude_usage.json"))
    if req.url:find("cedar_ember=1", 1, true) then
      data.cedar_ember = json.decode(M.fixture("claude_grants.json"))
    end
    return { ok = true, status = 200, body = json.encode(data) }
  end
end

function M.codexAuth(host, accountId: string?)
  M.write(host, `{M.CODEX_HOME}/auth.json`, {
    auth_mode = "chatgpt",
    tokens = { access_token = M.JWT_VALID, id_token = M.JWT_ID_PRO, account_id = accountId or "acct-1" },
  })
end

-- Routes requests by URL substring to bodies (or full responses).
function M.serve(host, routes)
  host.httpHandler = function(req)
    for needle, response in routes do
      if string.find(req.url, needle, 1, true) then
        return if type(response) == "string" then { ok = true, status = 200, body = response } else response
      end
    end
    return { ok = true, status = 404, body = "" }
  end
end

function M.headerOf(req, name: string): string?
  for _, line in req.headers or {} do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k and k:lower() == name:lower() then
      return v
    end
  end
  return nil
end

-- Moves the clock and runs the service's tick.
function M.advance(host, svc, seconds: number)
  host.clock += seconds
  svc.call("update")
end

-- An account in the published report.
function M.account(host, key: string)
  for _, view in host.stateValues.report.providers do
    for _, a in view.accounts do
      if a.key == key then
        return a
      end
    end
  end
  return nil
end

function M.requestsTo(host, needle: string): number
  local n = 0
  for _, req in host.requests do
    if req.url:find(needle, 1, true) then
      n += 1
    end
  end
  return n
end

-- A provider adapter loaded in a fresh host, with the context the service
-- would give its default account.
function M.provider(id: string)
  local host = M.host()
  local mods = M.modules(host)
  local p = mods.require(`providers/{id}/init.luau`)
  local context = mods.require("lib/context.luau")
  local accounts = mods.require("lib/accounts.luau")
  local base = context.new(host.globals.noctalia, "headroom-noctalia/test")
  local ctx = if p.accounts
    then context.forAccount(base, p.accounts, { kind = "default", home = accounts.defaultHome(p.accounts, base) })
    else base
  return host, p, ctx
end

function M.fetch(provider, ctx)
  local snapshot, err
  provider.fetch(ctx, function(s, e)
    snapshot, err = s, e
  end)
  return snapshot, err
end

return M
