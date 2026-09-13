--!nonstrict
-- Persist bounded plugin files under Noctalia's per-plugin data directory.
-- Callers provide leaf filenames so path validation stays centralized here.

local storage = {}

storage.MAX_BYTES = 4194304

local function safeLeafName(name)
    return type(name) == "string" and #name <= 128
        and name:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") ~= nil
end

function storage.dataDir()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then noctalia.log("radio-tellus: pluginDataDir failed: " .. tostring(err)) end
    return dir
end

function storage.dataPath(name)
    if not safeLeafName(name) then
        noctalia.log("radio-tellus: refused invalid plugin data filename")
        return nil
    end
    local dir = storage.dataDir()
    return dir and (dir .. "/" .. name) or nil
end

function storage.readText(name)
    local path = storage.dataPath(name)
    if path == nil or not noctalia.fileExists(path) then return nil, "missing" end
    local info = noctalia.fileInfo(path)
    local size = info and tonumber(info.size) or nil
    if size and size > storage.MAX_BYTES then return nil, "oversized" end
    local raw = noctalia.readFile(path)
    if type(raw) ~= "string" then return nil, "unreadable" end
    -- Keep the byte limit when metadata is unavailable or changes during read.
    if #raw > storage.MAX_BYTES then return nil, "oversized" end
    return raw
end

function storage.readJson(name)
    local raw, readError = storage.readText(name)
    if raw == nil then return nil, readError end
    local decoded, decodeError = noctalia.json.decode(raw)
    if decoded == nil then return nil, tostring(decodeError or "invalid JSON") end
    return decoded
end

function storage.writeJson(name, value)
    local path = storage.dataPath(name)
    if path == nil then return false end
    local encoded, encodeError = noctalia.json.encode(value)
    if type(encoded) ~= "string" then
        noctalia.log("radio-tellus: JSON encode failed: " .. tostring(encodeError))
        return false
    end
    local temporary = path .. "." .. tostring(math.floor(noctalia.nowMs()))
        .. "-" .. tostring(math.random(100000, 999999)) .. ".next"
    local ok, err = noctalia.writeFile(temporary, encoded .. "\n")
    if not ok then
        noctalia.log("radio-tellus: could not write " .. name .. ": " .. tostring(err))
        return false
    end
    ok, err = noctalia.renameFile(temporary, path)
    if not ok then
        noctalia.removeFile(temporary)
        noctalia.log("radio-tellus: could not publish " .. name .. ": " .. tostring(err))
    end
    return ok
end

function storage.hardenDataDir()
    local dir = storage.dataDir()
    if dir == nil or not noctalia.commandExists("chmod") then return false end
    return noctalia.runAsync({ "chmod", "700", dir }, function(result)
        if type(result) ~= "table" or math.floor(tonumber(result.exitCode) or -1) ~= 0 then
            noctalia.log("radio-tellus: could not restrict plugin data directory permissions")
        end
    end, 2000)
end

return storage
