--!nonstrict
-- Running `claude plugin`: the argv (stdin on /dev/null), the one-line outcome of a
-- --json run, the failure log line, and the name and trim checks that keep a forged
-- record out of an argv list. Ported from claude-cockpit's skills.luau (nightwatch75, MIT).

local shared = require("./shared.luau")
local actions = require("./actions.luau")
local M = {}

-- Install/update fetch over git; the host caps a command at 60s anyway.
M.CLI_TIMEOUT = 60000

-- Safe folder/plugin/marketplace name: also what keeps a newline-forged or
-- "-"-leading record out of an argv list.
function M.isName(s)
    return type(s) == "string" and s:match("^[%w_][%w._-]*$") ~= nil
end

function M.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- One-line human outcome of a --json run: the JSON's message, else the
-- first stderr line. Also returns the decoded JSON line, when there is one.
function M.outcomeMessage(result)
    local last = nil
    for line in (result.stdout or ""):gmatch("[^\n]+") do
        last = line
    end
    local data = last and noctalia.json.decode(last)
    if type(data) ~= "table" then data = nil end
    if data and type(data.message) == "string" and data.message ~= "" then
        return data.message, data
    end
    -- A success with nothing to say: the caller says "done".
    if result.exitCode == 0 then return "", data end
    local err = (result.stderr or ""):match("[^\n]+")
    if err then return err, data end
    -- Nothing said: at least say how it ended.
    if result.timedOut then return "timed out", data end
    return result.exitCode == 127 and "claude not found" or `exit {result.exitCode}`, data
end

-- Logged with the command, so a failure on someone else's machine can be traced.
function M.logFailure(args, message)
    noctalia.log(`claude-operator: claude plugin {table.concat(args, " ")}: {message}`)
end

-- `claude plugin <args>` with stdin on /dev/null. noctalia's own stdin is whatever it
-- was started from (a login tty, when launched from a console), and claude waits for
-- input there until it closes, so every listing would hang until the timeout.
function M.cliArgv(args)
    local argv = { "bash", "-c", 'exec "$@" </dev/null', "bash", actions.claudeBin() or "claude", "plugin" }
    for _, a in ipairs(args) do
        table.insert(argv, a)
    end
    return argv
end

function M.runCli(args, done)
    local argv = M.cliArgv(args)
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) ~= "table" then
            done(false, "")
            return
        end
        local message, data = M.outcomeMessage(result)
        message = M.trim(message)
        if result.exitCode ~= 0 then M.logFailure(args, message) end
        done(result.exitCode == 0, message, data)
    end, M.CLI_TIMEOUT)
    if not ok then
        M.logFailure(args, "could not start")
        done(false, "could not start claude")
    end
end

return M
