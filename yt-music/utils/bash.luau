local Bash = {}

local PLUGIN_DIR = noctalia.pluginDir()

-- Quote a value for safe embedding in a /bin/sh command string.
-- Single quotes take everything literally until the next ', so the only
-- dangerous char is "'": close the quote, emit a literal ', reopen.
function Bash.sh_quote(value)
    if value == nil then return "''" end
    local s = tostring(value)
    if s == "" then return "''" end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Runs:  bash scripts/<file> <fn> '<arg1>' '<arg2>' ...
-- Fn name and every arg go through sh_quote -> nothing is interpolated.
-- Bash files read params positionally ($1..$N); the fn dispatches inside.
function Bash.run_script(file, fn, cb, timeout, ...)
    local cmd = "bash " .. Bash.sh_quote(PLUGIN_DIR .. "/scripts/" .. file)
    cmd = cmd .. " " .. Bash.sh_quote(fn)
    for _, a in ipairs({ ... }) do
        cmd = cmd .. " " .. Bash.sh_quote(a)
    end
    if type(cb) == "function" then
        return noctalia.runAsync(cmd, cb, timeout)
    end
    return noctalia.runAsync(cmd)
end

-- Long-lived stream: runs the same shaped command but routes every stdout line
-- to on_line until the process exits (e.g. the mpv IPC event stream).
function Bash.run_stream(file, fn, on_line, ...)
    local cmd = "bash " .. Bash.sh_quote(PLUGIN_DIR .. "/scripts/" .. file)
    cmd = cmd .. " " .. Bash.sh_quote(fn)
    for _, a in ipairs({ ... }) do
        cmd = cmd .. " " .. Bash.sh_quote(a)
    end
    return noctalia.runStream(cmd, on_line)
end

return Bash