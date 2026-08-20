local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local DEBUG_LOG_PATH = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/noctalia-ytmusic/debug.log"

local function debug_enabled()
    return noctalia.getConfig("debug_logging") == true
end

local function log(tag, msg)
    if not debug_enabled() then return end
    local line = "[" .. tag .. "] " .. msg
    print(line)
    local prev = noctalia.readFile(DEBUG_LOG_PATH) or ""
    noctalia.writeFile(DEBUG_LOG_PATH, prev .. line .. "\n")
end

-- Binds a fixed "ytm/<module>" (or "ytapi/<module>") tag so every log
-- line names its origin and layer in the plugin.
local function module(...)
    local parts = { ... }
    local tag = table.concat(parts, "/")
    return function(msg)
        log(tag, msg)
    end
end

return {
    log = log,
    module = module,
    debug_enabled = debug_enabled,
    DEBUG_LOG_PATH = DEBUG_LOG_PATH
}