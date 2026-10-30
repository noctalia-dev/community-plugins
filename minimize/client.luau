--!nonstrict
-- Thin bridge to the unprivileged `noctalia-minimizer` backend. Arguments are
-- passed as an argv array: titles and ids are never interpreted by a shell.
local M = {}
local BACKEND = "@backend@"
if string.sub(BACKEND, 1, 1) == "@" then BACKEND = "noctalia-minimizer" end
M.backend = BACKEND

function M.request(arguments, callback)
    local argv = { BACKEND }
    for _, value in ipairs(arguments) do table.insert(argv, tostring(value)) end
    local accepted = noctalia.runAsync(argv, function(result)
        local data = noctalia.json.decode(result.stdout or "")
        if result.timedOut then
            callback(nil, "The window backend timed out; Niri may be busy")
        elseif type(data) ~= "table" then
            callback(nil, "Noctalia Minimize did not return valid data. Check that noctalia-minimizer is installed.")
        elseif data.error then
            callback(nil, tostring(data.error))
        elseif result.exitCode ~= 0 then
            callback(nil, "The window operation failed")
        else
            callback(data, nil)
        end
    end, 10000)
    if not accepted then callback(nil, "Could not start the Noctalia Minimize backend") end
end

local function report(title)
    return function(data, err)
        if err then noctalia.notifyError(title, err)
        elseif data and data.warning then noctalia.notifyError("Some windows were not moved", data.warning) end
    end
end

function M.enabled() return noctalia.getConfig("enabled") ~= false end
function M.minimize() if M.enabled() then M.request({"minimize"}, report("Minimize window")) end end
function M.minimizeAll() if M.enabled() then M.request({"minimize-all"}, report("Minimize all windows")) end end
function M.restoreAll() if M.enabled() then M.request({"restore-all"}, report("Restore windows")) end end
function M.restoreLast() if M.enabled() then M.request({"restore-last"}, report("Restore window")) end end
return M
