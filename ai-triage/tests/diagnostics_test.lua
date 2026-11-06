-- Failed usage reads must explain the cause and recommend a relevant action.
local file = assert(io.open("shared.luau"))
local source = file:read("*a")
file:close()
local env = setmetatable({ noctalia = { string = {
    trim = function(s) return tostring(s):match("^%s*(.-)%s*$") end,
} } }, { __index = _G })
local shared = assert(load(source, "shared", "t", env))()

local cases = {
    { "missing Claude token", "anthropic", "credentials error: no access token; run `claude` to log in",
        "signed_out", "login", "claude auth login" },
    { "rejected Claude login", "anthropic", "HTTP 401: authentication rejected — credentials may be missing, expired, or invalid",
        "authentication", "login", "claude auth login" },
    { "expired login", "anthropic", "HTTP 403: authorization token expired",
        "authentication", "login", "claude auth login" },
    { "Codex login", "openai", "HTTP 401: unauthorized", "authentication", "login", "codex login" },
    { "Copilot login", "copilot", "HTTP 401: unauthorized", "authentication", "login", "gh auth login" },
    { "named account", "anthropic@work", "HTTP 401: authentication rejected", "authentication", "named_account" },
    { "named Codex account", "openai@work", "credentials error: no access token", "signed_out", "named_account" },
    { "missing API key", "deepseek", "credentials error: no API key configured", "missing_key", "missing_key" },
    { "rejected API key", "deepseek", "HTTP 401: unauthorized", "authentication", "missing_key" },
    { "Anthropic API key", "anthropic_api", "HTTP 401: authentication rejected", "authentication", "missing_key" },
    { "rate limit", "anthropic", "HTTP 429: Rate limited", "rate_limited", "rate_limited" },
    { "auth rate limit", "anthropic", "HTTP 429: authentication rate limited", "rate_limited", "rate_limited" },
    { "server outage", "anthropic", "HTTP 503: authentication service unavailable", "server", "server" },
    { "server error", "openai", "HTTP 500: internal error", "server", "server" },
    { "permission", "openai", "HTTP 403: forbidden", "permission", "permission" },
    { "network", "openai", "network transport error: DNS lookup failed", "network", "network" },
    { "deadline", "anthropic", "network transport error: request timed out", "timeout", "timeout" },
    { "schema drift", "openai", "schema mismatch: weekly window has an unknown shape", "schema", "schema" },
    { "credentials file", "anthropic", "credentials error: permission denied reading credentials file", "credentials", "credentials" },
    { "local Antigravity", "antigravity", "credentials error: Antigravity: no local server found", "local_server", "local_server" },
    { "Antigravity auth", "antigravity", "HTTP 401: authentication rejected", "authentication", "local_server" },
    { "unknown", "custom:local", "Upstream quota read failed", "unknown", "unknown" },
}

for _, case in ipairs(cases) do
    local name, id, detail, code, action, command = table.unpack(case)
    local diagnostic = shared.diagnostic({ id = id, status = "error", error = detail })
    assert(diagnostic.code == code, name .. ": incorrect cause " .. diagnostic.code)
    assert(diagnostic.actionKey == "ui.diagnostic.action." .. action, name .. ": incorrect recommendation")
    assert(diagnostic.command == command, name .. ": incorrect sign-in command")
    assert(diagnostic.detail == detail, name .. ": original diagnostic must remain available")
    if action == "named_account" then
        assert(diagnostic.actionArgs.account == "work", "named login hints must identify their own account")
    end
    if code == "rate_limited" or code == "server" or code == "network" then
        assert(diagnostic.command == nil, name .. ": transient failures must not suggest re-authentication")
    end
end

local cached = { id = "anthropic", status = "ready", stale = true, metrics = { { percent = 80 } },
    sections = { { type = "text", label = "HTTP 401", value = "authentication rejected" } } }
assert(shared.diagnostic(cached).code == "authentication", "cached quota must not conceal a rejected login")
cached.sections, cached.stale = {}, false
assert(shared.diagnostic(cached) == nil, "a healthy refresh must clear the diagnosis")
assert(shared.diagnostic(nil) == nil, "no provider is not a provider failure")

shared.recordTelemetrySample({ providerId = "openai", name = "Codex",
    entry = { status = "error", error = "HTTP 401: authentication rejected" },
    sessionMetric = { percent = 80 }, weeklyMetric = { percent = 90 } })
assert(shared.telemetryBaselines.openai == nil, "failed readings must not recalibrate healthy quota pacing")
io.write("ok: 22 provider failure cases, account-specific actions, recovery and stale quota isolation\n")
