--!nonstrict
-- Which language the plugin's own date formats should use.
--
-- The host translates strings through noctalia.tr but does not tell a plugin
-- which locale it picked, and this plugin also formats dates itself (weekday
-- names, "9月16日" / "Sep 16", countdowns). The shell's language setting is the
-- closest thing to the truth: read it where the host exposes getSetting (plugin
-- API 26+, hence the feature check) and fall back to the process locale.

local M = {}

-- The host is reached through `host()`, which resolves the `noctalia` global.
-- `set_host` lets the test harness inject a stand-in, because Luau's standalone
-- module sandbox does not expose the calling script's globals the way Noctalia's
-- loader does.
local injected_host

function M.set_host(value)
    injected_host = value
end

local function host()
    return injected_host or noctalia
end

--- The configured language, e.g. "zh-CN", "en_US.UTF-8", or "" when unknown.
function M.name()
    local shell = host()
    if type(shell.getSetting) == "function" then
        -- pcall: a host that does not allow getSetting at this plugin API level
        -- must not break the entry scripts.
        local ok, configured = pcall(shell.getSetting, "general.language")
        if ok and type(configured) == "string" and configured ~= "" then
            return configured
        end
    end
    return shell.getenv("LC_ALL")
        or shell.getenv("LC_TIME")
        or shell.getenv("LANG")
        or ""
end

--- True when the plugin should write its dates the Chinese way.
function M.chinese()
    return M.name():lower():find("^zh") ~= nil
end

return M
