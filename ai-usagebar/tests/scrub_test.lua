-- Redaction test for service.luau's safeText().
--
-- Everything the CLI writes reaches the screen, and a CLI that fails an HTTP
-- request tends to quote the request. safeText is the only thing standing
-- between that and a rendered label, so it gets a test.
--
-- The function is read out of service.luau rather than copied here: a copy
-- would keep passing after the real one changed.
--
--   lua tests/scrub_test.lua      (or luajit)
--
-- Run it from the plugin directory. Exits non-zero on the first failure.

local SOURCE = "service.luau"

local function loadSafeText()
    local file = io.open(SOURCE, "r")
    if file == nil then
        error("run this from the plugin directory: " .. SOURCE .. " not found")
    end
    local source = file:read("*a")
    file:close()

    -- The slice runs from the redaction constants to the end of the function.
    local chunk = source:match("(local SECRET_VALUE.-\nend)\n")
    if chunk == nil then
        error("could not find safeText in " .. SOURCE .. "; update the markers here")
    end

    -- The only host API the function touches.
    local env = {
        string = string,
        ipairs = ipairs,
        tostring = tostring,
        noctalia = { string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end } },
    }
    local loaded = load(chunk .. "\nreturn safeText", "safeText", "t", env)
    return loaded()
end

local safeText = loadSafeText()

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
    { "OPENAI_API_KEY sk-proj-REALKEYVALUE not accepted", "REALKEY" },
    { "password=hunter2", "hunter2" },
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
}

local failures = 0

local function fail(message)
    failures = failures + 1
    io.write("FAIL  ", message, "\n")
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

if failures > 0 then
    io.write(failures, " failure(s)\n")
    os.exit(1)
end

io.write("ok: ", #SECRETS, " secrets redacted, ", #BENIGN, " readings untouched, length capped\n")
