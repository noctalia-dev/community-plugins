local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local DEBUG_LOG_PATH = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/yt-music/debug.log"

local function debug_enabled()
    return noctalia.getConfig("debug_logging") == true
end

-- Bound the file: past MAX_BYTES keep only the newest TRIM_TO bytes (cut at a
-- line boundary), so appends stay cheap and long debug sessions cannot grow
-- the file without limit.
local MAX_BYTES = 512 * 1024
local TRIM_TO = 128 * 1024

local function append(line)
    local prev = noctalia.readFile(DEBUG_LOG_PATH) or ""
    if #prev > MAX_BYTES then
        prev = prev:sub(#prev - TRIM_TO + 1)
        prev = prev:gsub("^[^\r\n]*[\r\n]+", "")
    end
    noctalia.writeFile(DEBUG_LOG_PATH, prev .. line .. "\n")
end

local function log(tag, msg)
    if not debug_enabled() then return end
    local line = "[" .. tag .. "] " .. msg
    print(line)
    append(line)
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