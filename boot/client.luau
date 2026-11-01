--!nonstrict
-- Bridge to the unprivileged `noctalia-switch-os` front end (argv only, no shell).
local M = {}
local BACKEND = "@backend@"
if string.sub(BACKEND, 1, 1) == "@" then BACKEND = "noctalia-switch-os" end
M.backend = BACKEND

function M.request(arguments, callback)
    local argv = { BACKEND }
    for _, value in ipairs(arguments) do table.insert(argv, tostring(value)) end
    local accepted = noctalia.runAsync(argv, function(result)
        local data = noctalia.json.decode(result.stdout or "")
        if result.timedOut then
            callback(nil, "Reading boot entries timed out. Complete or cancel any open authentication prompt.")
        elseif type(data) ~= "table" then
            callback(nil, "Noctalia Boot did not return valid data. Check that the NixOS module is installed.")
        elseif data.error and data.supported ~= false then
            callback(nil, tostring(data.error))
        elseif result.exitCode ~= 0 and data.supported ~= false then
            callback(nil, "The operation failed")
        else
            callback(data, nil)
        end
    end, 30000)
    if not accepted then callback(nil, "Could not start the Noctalia Boot backend") end
end

function M.enabled() return noctalia.getConfig("enabled") ~= false end
return M
