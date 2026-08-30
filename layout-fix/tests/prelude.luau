--!nonstrict
-- Test harness: a fake Noctalia runtime for service.luau.
--
-- The service talks to the host through a handful of functions (runAsync,
-- notify, the plugin's own directories, getConfig). Stub those and it runs
-- in a plain luau interpreter, with shell commands answered from a table.
-- run-tests.sh concatenates this file, service.luau and one case.

LayoutTest = {}
local T = LayoutTest

T.files = {}          -- path -> contents
T.notifications = {}  -- { title, body } in order
T.errors = {}         -- the same for notifyError
T.commands = {}       -- every command string the service ran, in order
T.config = {}         -- what getConfig answers
T.logs = {}
T.installedCommands = { pkexec = true, grep = true }
T.failNextRun = false

-- Commands are matched by substring, most recently registered first, so a
-- case can override a general answer with a specific one.
T.responses = {}
T.responseOrder = {}

function T.respond(pattern, stdout)
    T.responses[pattern] = stdout
    table.insert(T.responseOrder, 1, pattern)
end

local function answerFor(cmd)
    for _, pattern in ipairs(T.responseOrder) do
        if string.find(cmd, pattern, 1, true) ~= nil then
            local answer = T.responses[pattern]
            if type(answer) == "function" then
                return answer(cmd)
            end
            return answer
        end
    end
    return ""
end

noctalia = {
    -- Synchronous on purpose: the callback runs before runAsync returns, so
    -- a case reads the outcome on the next line instead of pumping a loop.
    runAsync = function(cmd, callback, _timeout)
        table.insert(T.commands, cmd)
        if T.failNextRun then
            T.failNextRun = false
            return false
        end
        callback({ stdout = answerFor(cmd), stderr = "", exitCode = 0 })
        return true
    end,

    getConfig = function(key)
        return T.config[key]
    end,

    -- Keys, not sentences: a case asserting on English wording would break
    -- the moment the wording improves.
    tr = function(key, args)
        if args == nil then
            return key
        end
        local parts = {}
        for name, value in pairs(args) do
            table.insert(parts, name .. "=" .. tostring(value))
        end
        table.sort(parts)
        return key .. "(" .. table.concat(parts, ",") .. ")"
    end,

    notify = function(title, body)
        table.insert(T.notifications, { title = title, body = body })
    end,
    notifyError = function(title, body)
        table.insert(T.errors, { title = title, body = body })
    end,

    fileExists = function(path) return T.files[path] ~= nil end,
    readFile = function(path) return T.files[path] or "" end,
    writeFile = function(path, content) T.files[path] = content end,

    commandExists = function(name) return T.installedCommands[name] == true end,

    pluginDir = function() return "/plugin" end,
    pluginDataDir = function() return "/data" end,

    log = function(line) table.insert(T.logs, tostring(line)) end,
    setUpdateInterval = function() end,
}
