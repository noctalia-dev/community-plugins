--!nonstrict

-- Keep commands as argv from settings all the way to exec. Never guess whether
-- an app is a TUI, or run user settings through a shell.
local M = {}

local function invalid(message)
    noctalia.notifyError("System Menu", message .. " Check Settings → Plugins → System Menu.")
    return nil
end

local function arguments(value, label)
    if type(value) ~= "table" then return invalid(label .. " must be an argument list.") end
    local result = {}
    for index, arg in ipairs(value) do
        if type(arg) ~= "string" or arg:find("%c") then
            return invalid(label .. ": item " .. index .. " must be text without control characters.")
        end
        table.insert(result, arg)
    end
    return result
end

local function executable(value, label)
    if type(value) ~= "string" then value = "" end
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return invalid("Choose a program for " .. label .. ".") end
    if value:find("%c") or value:sub(1, 1) == "-" then
        return invalid(label .. ": enter an executable, without arguments.")
    end
    if value:sub(1, 2) == "~/" then value = noctalia.expandPath(value) end
    if value:sub(1, 1) ~= "/" and (value:find("%s") or value:find("/", 1, true)) then
        return invalid(label .. ": use a program name or absolute path; put options in the argument list.")
    end
    if not noctalia.commandExists(value) then
        return invalid(label .. ": executable not found or not executable: " .. value)
    end
    return value
end

local function terminalCommand(program)
    local terminal = executable(noctalia.getConfig("terminal"), "Terminal")
    if not terminal then return nil end
    local hint = noctalia.getConfig("show_terminal_arguments") and "" or " (enable Terminal — advanced options to edit)"
    local args = arguments(noctalia.getConfig("terminal_args"), "Terminal arguments" .. hint)
    if not args then return nil end
    local argv = { terminal }
    for _, arg in ipairs(args) do table.insert(argv, arg) end
    if program then
        local execArgs = arguments(noctalia.getConfig("terminal_exec_args"), "Run-program arguments" .. hint)
        if not execArgs then return nil end
        for _, arg in ipairs(execArgs) do table.insert(argv, arg) end
        local format = noctalia.getConfig("terminal_command_format")
        if format == "argv" then
            for _, arg in ipairs(program) do table.insert(argv, arg) end
        elseif format == "quoted" then
            -- Some terminals accept one POSIX-style command string rather than
            -- argv. Quote every item, including empty strings and apostrophes.
            local quoted = {}
            for _, arg in ipairs(program) do
                table.insert(quoted, "'" .. arg:gsub("'", "'\\''") .. "'")
            end
            table.insert(argv, table.concat(quoted, " "))
        else
            return invalid("Choose a valid terminal command format" .. hint .. ".")
        end
    end
    return argv
end

local function launch(argv, desktop)
    if not argv then return end
    -- GUI applications and terminals must be detached, not captured as short
    -- subprocess jobs. Only the desktop launch helper is short-lived/captured;
    -- it gives gtk-launch a separate session and /dev/null output for GUI apps.
    local callback = nil
    if desktop then
        callback = function(result)
            if result.exitCode ~= 0 then
                noctalia.notifyError("System Menu", "Could not open desktop entry " .. desktop .. ". Check its ID and installation.")
            end
        end
    end
    if noctalia.runAsync(argv, callback) then
        panel.close()
    else
        invalid("Could not start the application.")
    end
end

function M.openTerminal()
    launch(terminalCommand())
end

function M.open(label, mode, command, args)
    if mode == "desktop" then
        if type(command) ~= "string" then command = "" end
        local id = command:match("^%s*(.-)%s*$")
        if id == "" then return invalid("Choose a desktop entry for " .. label .. ".") end
        if not id:match("^[%w_][%w_.+%-]*$") then
            return invalid(label .. ": enter a desktop entry ID, not a path or command.")
        end
        if id:sub(-8) ~= ".desktop" then id = id .. ".desktop" end
        local gtkLaunch = executable("gtk-launch", "Desktop launcher")
        if not gtkLaunch then return end
        local python = executable("python3", "Desktop launcher")
        if python then launch({ python, "-I", noctalia.pluginDir() .. "/desktop-launch.py", id }, id) end
        -- Command arguments are deliberately inactive in desktop mode. The
        -- installed entry owns Exec, Terminal, D-Bus and Flatpak launch details.
        return
    end
    if mode ~= "direct" and mode ~= "terminal" then
        return invalid(label .. ": choose Direct, In terminal or Desktop entry.")
    end
    local program = executable(command, label)
    if not program then return end
    local extra = arguments(args, label .. " arguments")
    if not extra then return end
    local argv = { program }
    for _, arg in ipairs(extra) do table.insert(argv, arg) end
    if mode == "terminal" then argv = terminalCommand(argv) end
    launch(argv)
end

return M
