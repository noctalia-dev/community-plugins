--!nonstrict
-- sessions — pure data module: runs list-claude-sessions and shapes its flat
-- output into project groups the panel renders. No UI state, no closures
-- over caller state (same rule todo/storage.luau follows) — the panel alone
-- owns what is expanded, searched or being confirmed.
--
-- Never polled: M.refresh is called from the panel's onOpen and its refresh
-- button only. A "project" here is a distinct cwd a session was run from —
-- NOT literally a `~/.claude/projects/<encoded>/` directory, though most of
-- the time they line up 1:1; see decodeProjectDir for the one case they
-- don't (a session that states no cwd at all).

local M = {}

local HOME = noctalia.expandPath("~")
local PROJECTS_DIR = noctalia.expandPath("~/.claude/projects")
M.GLOBAL_CLAUDE_MD = noctalia.expandPath("~/.claude/CLAUDE.md")

local scriptPath = `{noctalia.pluginDir()}/list-claude-sessions`
local findClaudeMdPath = `{noctalia.pluginDir()}/find-claude-md`

-- Best-effort decode of an encoded project dir name, used ONLY when a
-- session never states its own cwd. Not reversible in general (a literal
-- "-" in a path is indistinguishable from an encoded "/"), so this is a
-- display fallback only — actions always use the session's recorded paths.
local function decodeProjectDir(encoded)
    if type(encoded) ~= "string" or encoded == "" or encoded:sub(1, 1) ~= "-" then
        return nil
    end
    return "/" .. encoded:sub(2):gsub("%-", "/")
end

-- One session record from the script, reshaped for the panel: a stable
-- label (AI title, else opening prompt cut short, else the id) plus the
-- jsonl path and subagent sidecar dir a delete acts on. `firstPrompt` stays
-- its own field, untruncated, for the panel's preview.
local function shapeSession(raw, cwd)
    local id = raw.id
    local aiTitle = (type(raw.title) == "string") and raw.title or ""
    local firstPrompt = (type(raw.firstPrompt) == "string") and raw.firstPrompt or ""
    local label = aiTitle
    if label == "" then
        if firstPrompt ~= "" then
            label = (#firstPrompt > 72) and (firstPrompt:sub(1, 72) .. "…") or firstPrompt
        else
            label = noctalia.tr("session_untitled", { id = id:sub(1, 8) })
        end
    end
    local dir = tostring(raw.projectDir or "")
    return {
        id = id,
        cwd = cwd,
        gitBranch = (type(raw.gitBranch) == "string" and raw.gitBranch ~= "") and raw.gitBranch or nil,
        mtime = tonumber(raw.mtime) or 0,
        size = tonumber(raw.size) or 0,
        label = label,
        firstPrompt = firstPrompt,
        -- Model + context size from the session's last assistant turn; 0/""
        -- for a session with no assistant turn yet.
        model = (type(raw.model) == "string") and raw.model or "",
        contextTokens = tonumber(raw.contextTokens) or 0,
        jsonlPath = PROJECTS_DIR .. "/" .. dir .. "/" .. id .. ".jsonl",
        sidecarDir = PROJECTS_DIR .. "/" .. dir .. "/" .. id,
    }
end

-- Groups the flat session list by resolved cwd, sorted most-recent-first
-- both within a project and across projects.
function M.groupByProject(rawSessions)
    local byCwd = {}
    local order = {}
    for _, raw in ipairs(rawSessions) do
        local cwd = raw.cwd
        if type(cwd) ~= "string" or cwd == "" then
            cwd = decodeProjectDir(raw.projectDir) or noctalia.tr("unknown_project")
        end
        local group = byCwd[cwd]
        if group == nil then
            group = { cwd = cwd, claudeMdPath = cwd .. "/CLAUDE.md", sessions = {}, lastActivity = 0 }
            byCwd[cwd] = group
            table.insert(order, group)
        end
        local session = shapeSession(raw, cwd)
        table.insert(group.sessions, session)
        if session.mtime > group.lastActivity then
            group.lastActivity = session.mtime
        end
    end
    for _, group in ipairs(order) do
        table.sort(group.sessions, function(a, b)
            return a.mtime > b.mtime
        end)
    end
    table.sort(order, function(a, b)
        return a.lastActivity > b.lastActivity
    end)
    return order
end

-- Runs list-claude-sessions and hands the grouped project list to
-- done(projects, err) — err is nil on success.
function M.refresh(done)
    local ok = noctalia.runAsync(`bash '{scriptPath}'`, function(result)
        if type(result) ~= "table" or result.success == false or result.exitCode ~= 0 then
            done(nil, noctalia.tr("err_sessions_fetch"))
            return
        end
        local data = noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" or type(data.sessions) ~= "table" then
            done(nil, noctalia.tr("err_sessions_data"))
            return
        end
        done(M.groupByProject(data.sessions), nil)
    end)
    if not ok then
        done(nil, noctalia.tr("err_sessions_launch"))
    end
end

-- Deletes one session's transcript and its subagent sidecar dir (if any), as
-- a direct argv exec — no shell in the way, so no shellQuote is needed and
-- `rm` needs no commandExists guard (it ships on every Linux install).
function M.deleteSession(session, done)
    local ok = noctalia.runAsync({ "rm", "-rf", "--", session.jsonlPath, session.sidecarDir }, function(result)
        done(type(result) == "table" and result.exitCode == 0)
    end)
    if not ok then
        done(false)
    end
end

-- ── CLAUDE.md discovery ──────────────────────────────────────────────────
-- The Sessions/CLAUDE.md tabs otherwise only know about projects that have
-- run a Claude Code session — a real CLAUDE.md nested deeper, or sitting in
-- a directory nobody has run `claude` from yet, would never show up. This
-- scans $HOME for every one instead.

-- Filesystem types find-claude-md must never walk into: a stalled NFS/SMB/
-- sshfs share would otherwise stall (or badly slow down) a scan that is
-- meant to be a quick $HOME walk.
local REMOTE_FSTYPES = {
    nfs = true, nfs4 = true, cifs = true, smb = true, smbfs = true, smb3 = true,
    sshfs = true, ["fuse.sshfs"] = true, davfs = true, davfs2 = true, ["fuse.davfs"] = true,
    ftpfs = true, ["fuse.ftpfs"] = true, afpfs = true, ceph = true, glusterfs = true,
    ["9p"] = true, ["fuse.rclone"] = true,
}

-- Mount points of remote filesystems under `root`. /proc/mounts fields are
-- space-separated with a "\NNN" octal escape for space/tab in a path — same
-- convention file-search's fallbackMounts already decodes.
local function remoteMountsUnder(root)
    local text = noctalia.readFile("/proc/mounts")
    if type(text) ~= "string" then
        return {}
    end
    local prefix = root:gsub("/+$", "") .. "/"
    local found = {}
    for line in text:gmatch("[^\n]+") do
        local mountPoint, fstype = line:match("^%S+%s+(%S+)%s+(%S+)")
        if mountPoint ~= nil and REMOTE_FSTYPES[fstype] then
            local decoded = mountPoint:gsub("\\(%d%d%d)", function(octal)
                local code = tonumber(octal, 8)
                return (code ~= nil) and string.char(code) or ""
            end)
            if decoded == root or decoded:sub(1, #prefix) == prefix then
                table.insert(found, decoded)
            end
        end
    end
    return found
end

-- Every real CLAUDE.md under $HOME, skipping .git/node_modules/.cache/.venv
-- and any remote mount. done(paths, err) — err is nil on success.
function M.findClaudeMdFiles(done)
    local argv = { "bash", findClaudeMdPath, HOME }
    for _, mount in ipairs(remoteMountsUnder(HOME)) do
        table.insert(argv, mount)
    end
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) ~= "table" or result.exitCode ~= 0 then
            done(nil, noctalia.tr("err_claudemd_scan"))
            return
        end
        local paths = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            table.insert(paths, line)
        end
        done(paths, nil)
    end, 60000)
    if not ok then
        done(nil, noctalia.tr("err_claudemd_scan"))
    end
end

return M
