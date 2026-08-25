-- Redaction test for service.luau's safeText() and scrub().
--
-- A CLI that fails an HTTP request tends to quote the request, and safeText is
-- the only thing between that and a rendered label. The functions are read out of
-- service.luau rather than copied, so a copy cannot keep passing after the real
-- one changes.
--
--   lua tests/scrub_test.lua      (or luajit)
--
-- Run it from the plugin directory. Exits non-zero if anything fails.

local SOURCE = "service.luau"

local function loadSafeText()
    local file = io.open(SOURCE, "r")
    if file == nil then
        error("run this from the plugin directory: " .. SOURCE .. " not found")
    end
    local source = file:read("*a")
    file:close()

    -- The slice runs from the redaction constants through scrub, which is what
    -- the poller's callback actually calls.
    local chunk = source:match("(local SECRET_VALUE.-)\nlocal function failure")
    if chunk == nil then
        error("could not find safeText in " .. SOURCE .. "; update the markers here")
    end

    -- The only host API the function touches.
    local env = {
        string = string,
        ipairs = ipairs,
        pairs = pairs,
        type = type,
        tostring = tostring,
        noctalia = { string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end } },
    }
    local loaded = load(chunk .. "\nreturn safeText, scrub", "scrubber", "t", env)
    return loaded()
end

local safeText, scrub = loadSafeText()

local function loadClassify()
    local file = io.open(SOURCE, "r")
    local source = file:read("*a")
    file:close()
    local chunk = source:match("(local SECRET_VALUE.-)\nlocal inFlight")
    if chunk == nil then error("could not find classify in " .. SOURCE) end
    local env = {
        string = string,
        ipairs = ipairs,
        pairs = pairs,
        type = type,
        tostring = tostring,
        noctalia = { string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end } },
    }
    local loaded = load(chunk .. "\nreturn classify", "classifier", "t", env)
    return loaded()
end

local classify = loadClassify()

local panelFile = io.open("panel.luau", "r")
local panelSource = panelFile:read("*a")
panelFile:close()

-- Each case names the material that must not survive.
local SECRETS = {
    { "GET /v1/usage?api_key=sk-ant-abc123456 failed", "abc123456" },
    { "request token=eyJhbGciOiJIUzI1NiJ9.SIGNATURE failed", "SIGNATURE" },
    { "client_secret=hunter2 rejected", "hunter2" },
    { "Authorization: Bearer sk-ant-api03-REALKEY", "REALKEY" },
    { '{"api_key": "sk-ant-api03-REALKEY"}', "REALKEY" },
    { '{"token":"eyJhbGciOiJIUzI1NiJ9.PAYLOAD.SIG"}', "PAYLOAD" },
    { "-H 'X-Api-Key: sk-ant-api03-REALKEY'", "REALKEY" },
    { "curl https://user:hunter2@api.anthropic.com/v1/usage", "hunter2" },
    { "authorization: bearer sk-ant-api03-REALKEY", "REALKEY" },
    -- The numeric exemption that keeps "Tokens: 45000" readable is offered to
    -- `token` alone, and never to a long run of digits.
    { "password: 1234", "1234" },
    -- A padded separator is how the CLI's own config file spells it.
    { 'api_key = "sk-ant-api03-REALKEY"', "REALKEY" },
    { "export ANTHROPIC_API_KEY = sk-ant-api03-REALKEY", "REALKEY" },
    { "secret: 99", "99" },
    { "api_key: 123456789012345", "123456789012345" },
    { "OPENAI_API_KEY sk-proj-REALKEYVALUE not accepted", "REALKEY" },
    { "password=hunter2", "hunter2" },
    -- The cap runs before the patterns, so a secret in a runaway line has to
    -- survive the truncation.
    { "api_key=sk-ant-REALKEY123 " .. string.rep("noise ", 60), "REALKEY123" },
}

-- Readings the plugin draws every minute. A scrubber that eats these is worse
-- than the leak it prevents.
local BENIGN = {
    "Claude Pro",
    "Session (5h)",
    "Weekly (7d)",
    "69% of the window elapsed",
    "Resets in 4h 01m at 12:40",
    "62% of monthly limit consumed",
    "10pts under",
    "https://github.com/akitaonrails/ai-usagebar",
    "ai-usagebar exited with code 2",
    "2026-08-20T11:29:59.872624Z",
    "Desk-top mode",
    "ChatGPT Free",
    -- The colon form of the redaction is also how the CLI labels a reading.
    "Tokens: 45000 / 100000",
    "tokens_used: 1500",
    "Session tokens: 98%",
    "Prompt tokens: 1,024",
}

local failures = 0

local function fail(message)
    failures = failures + 1
    io.write("FAIL  ", message, "\n")
end

-- A healthy usage entry is reported as `ok` by the CLI. Only `error` is a
-- failed provider state.
local healthy = classify({ exitCode = 0, stdout = "not json", stderr = "" })
if healthy.code ~= "no_data" then
    fail("malformed successful output should be no_data")
end
local missing = classify({ exitCode = 127, stderr = "comando não encontrado" })
if missing.code ~= "not_installed" then
    fail("exit code 127 should mean not_installed regardless of shell language")
end
if panelSource:find('entry.status ~= "ready"', 1, true)
    or not panelSource:find('entry.status == "error"', 1, true) then
    fail("panel must treat only error entries as failed")
end

for _, case in ipairs(SECRETS) do
    local input, material = case[1], case[2]
    local output = safeText(input)
    if output:find(material, 1, true) then
        fail(material .. " survived: " .. output)
    end
end

for _, input in ipairs(BENIGN) do
    local output = safeText(input)
    if output ~= input then
        fail("mangled a normal reading: " .. input .. " -> " .. output)
    end
end

-- A runaway line would push a bar capsule off the screen.
local long = safeText(string.rep("x", 500))
if #long > 210 then
    fail("long text was not capped: " .. #long .. " characters")
end

-- The poller scrubs the whole report inside one async callback, and the shell
-- kills a callback that overruns its CPU budget: the reading is lost, not just
-- late. So the cost is asserted, not only the output.
--
-- The meter is `string.gsub`, which every pattern in safeText runs through. The
-- work itself happens inside the C matcher, where an instruction-count hook sees
-- nothing, so what gets counted is the calls and the bytes handed to them.
--
-- The report below has the shape of a real `usage --json`: four vendors, six
-- metrics each, and the credential error the CLI writes for a provider it has no
-- key for, which is the string that opens the redaction patterns.
local function sampleReport()
    local entries = {}
    for _, vendor in ipairs({ "anthropic", "openai", "zai", "openrouter" }) do
        local metrics = {}
        for index = 1, 6 do
            metrics[index] = {
                label = "Session (5h)",
                value = "62% of monthly limit consumed",
                detail = "Resets in 4h 01m at 12:40",
                reset_at = "2026-08-20T11:29:59.872624Z",
                severity = "normal",
                percent = 62,
            }
        end
        entries[#entries + 1] = {
            id = vendor,
            name = vendor,
            display_name = "Claude Pro",
            plan = "Claude Pro",
            status = "ok",
            stale = false,
            fetched_at = "2026-08-20T11:29:59.872624Z",
            metrics = metrics,
            sections = { { type = "session" }, { type = "weekly" } },
            error = "credentials error: " .. vendor .. ": no API key. Either set an API key in a"
                .. " valid environment variable or set `api_key` under [" .. vendor .. "] in the"
                .. " config file. " .. string.rep("Retry later. ", 40),
        }
    end
    return { entries = entries }
end

local calls, bytes = 0, 0
local realGsub = string.gsub
string.gsub = function(subject, ...)
    calls = calls + 1
    bytes = bytes + #subject
    return realGsub(subject, ...)
end
scrub(sampleReport())
string.gsub = realGsub

-- Bytes, not calls: the count barely moves, since normalising whitespace is one
-- gsub per string either way. What moves is how much text the patterns are handed,
-- 37352 bytes for this report before the rewrite against 17664 after. The ceiling
-- sits between the two, near enough that widening the gate back to all four
-- keywords at once (22400) trips it as surely as moving the cap back after the
-- patterns (37352).
local MAX_BYTES = 20000
if bytes > MAX_BYTES then
    fail("the redaction patterns were handed " .. bytes .. " bytes of a four-vendor report"
        .. " in " .. calls .. " gsub calls, past the " .. MAX_BYTES .. " bytes this callback"
        .. " budgets for")
end

if failures > 0 then
    io.write(failures, " failure(s)\n")
    os.exit(1)
end

io.write("ok: ", #SECRETS, " secrets redacted, ", #BENIGN, " readings untouched, length capped, ",
    calls, " gsub calls over ", bytes, " bytes per report\n")
