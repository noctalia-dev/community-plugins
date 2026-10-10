--!nonstrict
-- live — pure data module for the Live tab, same rules as sessions.luau: no
-- UI state. M.refresh runs live-claude-sessions, which reads Claude Code's own
-- per-process state files, and sorts the result into the three attention
-- groups the panel renders: waiting (needs the user), busy, idle.
--
-- Polled by the panel only while it is open AND on the Live tab (see
-- LIVE_REFRESH_TICKS in panel.luau); never from the service, never with the
-- panel closed.

local M = {}

local scriptPath = `{noctalia.pluginDir()}/live-claude-sessions`
local focusPath = `{noctalia.pluginDir()}/focus-claude-session`
-- Transcript stats cache, keyed per session id (see the script header).
local dataDir = noctalia.pluginDataDir()

M.GROUPS = { "waiting", "busy", "idle" }

local function str(v)
    return type(v) == "string" and v or ""
end

local function shape(raw)
    local status = str(raw.status)
    if status ~= "waiting" and status ~= "busy" then
        status = "idle"
    end
    local name = str(raw.title)
    if name == "" then
        name = str(raw.name)
    end
    local bridge = str(raw.bridgeSessionId)
    return {
        pid = tonumber(raw.pid) or 0,
        id = str(raw.sessionId),
        cwd = str(raw.cwd),
        name = name ~= "" and name or str(raw.sessionId):sub(1, 8),
        status = status,
        waitingFor = str(raw.waitingFor),
        -- Claude Code stamps milliseconds; the panel works in seconds.
        since = math.floor((tonumber(raw.statusUpdatedAt) or tonumber(raw.startedAt) or 0) / 1000),
        lastPrompt = str(raw.lastPrompt),
        model = str(raw.model),
        contextTokens = tonumber(raw.contextTokens) or 0,
        costUSD = tonumber(raw.costUSD),
        gitBranch = str(raw.gitBranch),
        permissionMode = str(raw.permissionMode),
        -- Set while Remote Control is on: the session is then also open on claude.ai.
        webUrl = bridge:match("^session_[%w]+$") and ("https://claude.ai/code/" .. bridge) or nil,
    }
end

-- done(groups, err): groups = { waiting = {...}, busy = {...}, idle = {...},
-- count = n, costUSD = sum }, each list newest status change first.
function M.refresh(done)
    if dataDir == nil then
        done(nil, noctalia.tr("err_live_fetch"))
        return
    end
    local ok = noctalia.runAsync({ "bash", scriptPath, dataDir .. "/live" }, function(result)
        local data = type(result) == "table" and result.exitCode == 0 and noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" or type(data.sessions) ~= "table" then
            done(nil, noctalia.tr("err_live_fetch"))
            return
        end
        local groups = { waiting = {}, busy = {}, idle = {}, count = 0, costUSD = 0 }
        for _, raw in ipairs(data.sessions) do
            if type(raw) == "table" and str(raw.sessionId):match("^[%x-]+$") then
                local s = shape(raw)
                table.insert(groups[s.status], s)
                groups.count += 1
                groups.costUSD += s.costUSD or 0
            end
        end
        for _, g in ipairs(M.GROUPS) do
            table.sort(groups[g], function(a, b)
                return a.since > b.since
            end)
        end
        done(groups, nil)
    end, 15000)
    if not ok then
        done(nil, noctalia.tr("err_live_fetch"))
    end
end

-- Focuses the session's terminal window (niri/Umbriel); false when not found.
function M.focus(session, done)
    local ok = noctalia.runAsync({ "bash", focusPath, tostring(session.pid) }, function(result)
        done(type(result) == "table" and result.exitCode == 0)
    end)
    if not ok then
        done(false)
    end
end

return M
