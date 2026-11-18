#!/usr/bin/env lua
-- The passphrase path, tested without a shell and without NetworkManager.
--
-- The rule this file exists to defend: a Wi-Fi passphrase must never appear in a
-- process command line (world-readable in /proc), so it is handed to nmcli as a
-- file, that file is 0600 *before* the secret is written into it, it is removed on
-- every path out, and if it cannot be prepared privately the join is refused
-- rather than attempted without it.
--
-- The functions under test are lifted verbatim out of service.luau, so this cannot
-- drift from the code that ships the way a hand-copy would.
--
--     lua tests/secret-path.lua

local DIR = (arg and arg[0] or "tests/secret-path.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local ROOT = DIR .. "/.."

--------------------------------------------------------------------------- harness

local failures, checks = {}, 0
local function check(what, ok, detail)
  checks = checks + 1
  if ok then
    io.write("PASS  ", what, "\n")
  else
    io.write("FAIL  ", what, detail and ("   [" .. tostring(detail) .. "]") or "", "\n")
    failures[#failures + 1] = what
  end
end

local file = assert(io.open(ROOT .. "/service.luau", "r"))
local source = file:read("*a")
file:close()

local from = assert(source:find("local function withSecretFile", 1, true))
local to = assert(source:find("local function failWifi", 1, true))

local calls = {}      -- every argv handed to a runner
local scripted = {}   -- exit code per program name
local written = {}    -- path -> contents
local removed = {}    -- path -> count
local existing = {}   -- path -> true

local noctalia = {}
function noctalia.tr(key) return key end
function noctalia.fileExists(path) return existing[path] == true end
function noctalia.removeFile(path)
  removed[path] = (removed[path] or 0) + 1
  existing[path] = nil
end
function noctalia.writeFile(path, content)
  if scripted.write == false then return false end
  written[path] = content
  existing[path] = true
  return true
end

local net = {}
function net.passwdFileContents(password) return password .. "\n" end

local TMP = "/tmp/netctl-secret-test.tmp"
local CMD_TIMEOUT_MS, UP_TIMEOUT_MS = 1000, 2000
local function dataFile(name) return name == "secret.tmp" and TMP or nil end

local function finish(argv, onResult)
  calls[#calls + 1] = table.concat(argv, " ")
  local program = argv[1]
  local code = scripted[program]
  if code == nil then code = 0 end
  onResult({ exitCode = code, stdout = "", stderr = code ~= 0 and (program .. " failed") or "", timedOut = false })
end

local function runTool(argv, _, onResult) finish(argv, onResult) end
local function run(args, _, onResult)
  local argv = { "nmcli" }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  finish(argv, onResult)
end

-- The region under test, verbatim from service.luau.
local chunk = "return function(run, runTool, dataFile, net, noctalia, CMD_TIMEOUT_MS, UP_TIMEOUT_MS)\n"
  .. source:sub(from, to - 1)
  .. "\nreturn { withSecretFile = withSecretFile, activateWithSecret = activateWithSecret }\nend\n"
local exports = assert(load(chunk, "secret-path", "t"))()
local api = exports(run, runTool, dataFile, net, noctalia, CMD_TIMEOUT_MS, UP_TIMEOUT_MS)

local function reset()
  calls, written, removed, existing = {}, {}, {}, {}
  scripted = {}
end

-- withSecretFile hands its result to a callback rather than returning it, so the
-- result is collected this way.
local function prepare(password)
  local out
  api.withSecretFile(password, function(value) out = value end)
  return out
end

--------------------------------------------------------------------------- tests

-- 1. the file is created private first, then filled
reset()
local path = prepare("hunter2")
check("the passphrase file is created by install -m 600 before anything is written",
  calls[1] == "install -m 600 /dev/null " .. TMP, calls[1])
check("the secret is written only after the file exists privately", written[TMP] == "hunter2\n", tostring(written[TMP]))
check("the path is handed back to the caller", path == TMP, tostring(path))
check("no nmcli call is made while preparing the file",
  not calls[1]:match("^nmcli"), calls[1])

-- 2. an install that fails means no secret is written anywhere
reset()
scripted.install = 1
local none = prepare("hunter2")
check("a failed install refuses instead of writing the passphrase", none == nil, tostring(none))
check("a failed install writes nothing", next(written) == nil, "wrote " .. tostring(next(written)))

-- 3. a failed write means no secret file is left behind
reset()
scripted.write = false
none = prepare("hunter2")
check("a failed write refuses", none == nil, tostring(none))
check("a failed write removes the file it could not fill", (removed[TMP] or 0) >= 1, tostring(removed[TMP]))

-- 4. activation carries the secret in a file, never on the command line
reset()
local activated
api.activateWithSecret("uuid-1", "hunter2", function(result) activated = result end)
check("activation reads the passphrase from the file",
  calls[#calls] == "nmcli con up uuid-1 passwd-file " .. TMP, calls[#calls])
check("no argument anywhere contains the passphrase",
  not table.concat(calls, " "):find("hunter2", 1, true), table.concat(calls, " | "))
check("the file is removed once activation returns", (removed[TMP] or 0) == 1, tostring(removed[TMP]))
check("the result reaches the caller", activated ~= nil and activated.exitCode == 0)

-- 5. a saved profile with no passphrase: plain con up, no file at all
reset()
api.activateWithSecret("uuid-2", "", function() end)
check("an empty passphrase joins with a plain con up", calls[#calls] == "nmcli con up uuid-2", calls[#calls])
check("an empty passphrase creates no file", next(written) == nil, tostring(next(written)))

-- 6. fail closed: no passphrase file, no activation
reset()
scripted.install = 1
local refused
api.activateWithSecret("uuid-3", "hunter2", function(result) refused = result end)
check("activation is refused when the file cannot be prepared privately",
  refused ~= nil and refused.exitCode ~= 0, refused and tostring(refused.exitCode) or "no result")
check("a refused activation never reaches nmcli",
  not table.concat(calls, " "):find("con up", 1, true), table.concat(calls, " | "))
check("a refused activation leaves no secret behind", next(written) == nil, tostring(next(written)))

--------------------------------------------------------------------------- summary

io.write(string.format("\n%d checks, %d failed\n", checks, #failures))
os.exit(#failures == 0 and 0 or 1)
