--!nonstrict
-- sessions — pure data module: runs list-claude-sessions and shapes its flat
-- output into project groups the panel renders. No UI state, no closures
-- over caller state (same rule todo/storage.luau follows) — the panel alone
-- owns what is expanded, searched or being confirmed.
--
-- Never polled: M.refresh is called from the panel's onOpen and its refresh
-- button only. A "project" here is a distinct cwd a session was run from —
-- NOT literally a `~/.claude/projects/<encoded>/` directory, though most of
-- the time they line up 1:1; see decodeProjectDir for a session that states
-- no cwd at all, and resolvedCwd for one whose folder was renamed or moved.

local M = {}

local HOME = noctalia.expandPath("~")
local PROJECTS_DIR = noctalia.expandPath("~/.claude/projects")
local SESSION_ENV_DIR = noctalia.expandPath("~/.claude/session-env")
local FILE_HISTORY_DIR = noctalia.expandPath("~/.claude/file-history")
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
    local customTitle = (type(raw.customTitle) == "string") and raw.customTitle or ""
    local firstPrompt = (type(raw.firstPrompt) == "string") and raw.firstPrompt or ""
    local label = (customTitle ~= "") and customTitle or aiTitle
    if label == "" then
        if firstPrompt ~= "" then
            label = (#firstPrompt > 72) and (firstPrompt:sub(1, 72) .. "…") or firstPrompt
        else
            label = noctalia.tr("session_untitled", { id = id:sub(1, 8) })
        end
    end
    local dir = tostring(raw.projectDir or "")
    local resolved = (type(raw.resolvedCwd) == "string") and raw.resolvedCwd or ""
    return {
        id = id,
        cwd = cwd,
        cwdKnown = type(raw.cwd) == "string" and raw.cwd ~= "",
        gitBranch = (type(raw.gitBranch) == "string" and raw.gitBranch ~= "") and raw.gitBranch or nil,
        mtime = tonumber(raw.mtime) or 0,
        size = tonumber(raw.size) or 0,
        empty = raw.empty == true, -- no user turn: opened and closed without a prompt
        label = label,
        firstPrompt = firstPrompt,
        -- Model + context size from the session's last assistant turn; 0/""
        -- for a session with no assistant turn yet.
        model = (type(raw.model) == "string") and raw.model or "",
        contextTokens = tonumber(raw.contextTokens) or 0,
        projectDir = dir,
        -- ok | relocated | misplaced | orphan | unknown, see list-claude-sessions.
        status = (type(raw.status) == "string" and raw.status ~= "") and raw.status or "ok",
        resolvedCwd = resolved,
        hasMemory = raw.hasMemory == true,
        -- The folder resume and copy cd into: the real folder of a relocated session.
        runCwd = resolved ~= "" and resolved or cwd,
        jsonlPath = PROJECTS_DIR .. "/" .. dir .. "/" .. id .. ".jsonl",
        sidecarDir = PROJECTS_DIR .. "/" .. dir .. "/" .. id,
        sessionEnvDir = SESSION_ENV_DIR .. "/" .. id,
        fileHistoryDir = FILE_HISTORY_DIR .. "/" .. id,
        memoryDir = PROJECTS_DIR .. "/" .. dir .. "/memory",
        projectPath = PROJECTS_DIR .. "/" .. dir,
    }
end

-- Groups the flat session list by folder (the real one of a relocated
-- session, else the recorded cwd), sorted most-recent-first both within a
-- project and across projects.
function M.groupByProject(rawSessions)
    local byCwd = {}
    local order = {}
    for _, raw in ipairs(rawSessions) do
        local cwd = raw.cwd
        if type(raw.resolvedCwd) == "string" and raw.resolvedCwd ~= "" then
            cwd = raw.resolvedCwd
        elseif type(cwd) ~= "string" or cwd == "" then
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
-- The scan reads every transcript under ~/.claude/projects (about 30 s for
-- ~300 sessions, 400 MB), so it needs a longer timeout than runAsync's
-- default of a few seconds, which kills it (exit 143) and leaves the tab empty.
-- 60 s is the most runAsync accepts (it clamps timeoutMs to [50, 60000]).
local SCAN_TIMEOUT_MS = 60000

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
    end, SCAN_TIMEOUT_MS)
    if not ok then
        done(nil, noctalia.tr("err_sessions_launch"))
    end
end

-- True when no other session shares this session's ~/.claude/projects dir,
-- i.e. deleting it leaves the project dir empty apart from memory/.
function M.isLastInProject(projects, session)
    for _, group in ipairs(projects) do
        for _, other in ipairs(group.sessions) do
            if other.id ~= session.id and other.projectDir == session.projectDir then
                return false
            end
        end
    end
    return true
end

function M.memoryKept(session)
    return noctalia.fileExists(session.memoryDir) == true
end

-- Ids become path parts under rm -rf: only hex and dashes, never "." or "/".
local function validId(id)
    return type(id) == "string" and id:match("^[%x-]+$") ~= nil
end

-- The id folders in session-env and file-history are shared by every copy of
-- the id; they go only when no project folder still holds a transcript of it.
-- Paths arrive as positional args, never inside the script text.
M.CLEANUP_SH = 'for p in "$1"/*/"$2".jsonl; do [ -e "$p" ] && exit 0; done; rm -rf -- "$3" "$4"'

-- Deletes one session's transcript and subagent sidecar, then the shared id
-- folders (see CLEANUP_SH), as direct argv execs, one after the other (one
-- command at a time). The final rmdir only removes the (now empty) memory and
-- project dirs and fails harmlessly when they hold anything, so `done`
-- reports the first rm alone.
local DELETE_TIMEOUT_MS = 30000

local function deleteOne(session, done)
    if not validId(session.id) then
        done(false)
        return
    end
    local ok = noctalia.runAsync({ "rm", "-rf", "--", session.jsonlPath, session.sidecarDir }, function(result)
        local success = type(result) == "table" and result.exitCode == 0
        if not success then
            done(false)
            return
        end
        local function removeDirs()
            -- done waits for rmdir so memoryKept never sees a memory/ about to go.
            local started = noctalia.runAsync({ "rmdir", "--", session.memoryDir, session.projectPath }, function()
                done(true)
            end)
            if not started then
                done(true)
            end
        end
        local cleaning = noctalia.runAsync({
            "sh", "-c", M.CLEANUP_SH, "sh", PROJECTS_DIR, session.id, session.sessionEnvDir, session.fileHistoryDir,
        }, removeDirs)
        if not cleaning then
            removeDirs()
        end
    end, DELETE_TIMEOUT_MS)
    if not ok then
        done(false)
    end
end

function M.deleteSession(session, done)
    deleteOne(session, done)
end

-- Deletes several sessions (cleanEmpty), each with deleteOne's sequence.
-- The host runs at most 8 commands per plugin at once and a refused runAsync
-- returns false without calling back, so only DELETE_LANES sessions run at
-- a time (one command each), leaving room for the rest of the plugin.
-- done(failed) gets the number of sessions that were not deleted.
local DELETE_LANES = 4

function M.deleteSessions(list, done)
    local failed, index, running = 0, 1, 0
    if #list == 0 then
        done(0)
        return
    end
    local function startNext()
        while running < DELETE_LANES and index <= #list do
            local session = list[index]
            index += 1
            running += 1
            deleteOne(session, function(success)
                if not success then
                    failed += 1
                end
                running -= 1
                if index > #list and running == 0 then
                    done(failed)
                else
                    startNext()
                end
            end)
        end
    end
    startNext()
end

-- Appends a custom-title record, the same line /rename writes, so Claude
-- Code and list-claude-sessions both pick it up. The snippet first adds a
-- newline if the transcript lacks a final one, so the record never glues
-- onto the last line. A transcript deleted meanwhile fails instead of being
-- recreated.
M.RENAME_SH = 'f="$1"; [ -f "$f" ] || exit 1; [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && printf "\\n" >> "$f"; printf "%s\\n" "$2" >> "$f"'

function M.renameSession(session, title, done)
    if not validId(session.id) then
        done(false)
        return
    end
    title = title:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
    if title == "" or utf8.len(title) == nil or utf8.len(title) > 120 then
        done(false)
        return
    end
    local line = noctalia.json.encode({ type = "custom-title", customTitle = title, sessionId = session.id })
    local ok = noctalia.runAsync({ "sh", "-c", M.RENAME_SH, "sh", session.jsonlPath, line }, function(result)
        done(type(result) == "table" and result.exitCode == 0)
    end)
    if not ok then
        done(false)
    end
end

-- ── Repair a misplaced transcript ────────────────────────────────────────
-- A misplaced transcript (no folder matches its project dir, its recorded
-- cwd exists) resumes once it sits in the project folder that cwd encodes
-- to; the cwd text inside the file is not used, so the repair is a move and
-- nothing is rewritten. The cwd folder is never created.

-- Claude Code's folder name: one "-" per character that is not a letter or
-- digit. Only ASCII counts as letter/digit, a multibyte character is one dash.
local function encodeCwd(cwd)
    local out = {}
    for _, code in utf8.codes(cwd) do
        local c = string.char(code < 128 and code or 0)
        table.insert(out, c:match("^%w$") and c or "-")
    end
    return table.concat(out)
end

-- The cwd to move the transcript to, or nil and an error code.
function M.repairTarget(session)
    local cwd = session.cwd
    if session.status ~= "misplaced" then
        return nil, "status"
    end
    if not validId(session.id) or type(cwd) ~= "string" then
        return nil, "unsafe"
    end
    if cwd:sub(1, 1) ~= "/" then
        return nil, "not_absolute"
    end
    if cwd:find("%c") or utf8.len(cwd) == nil or ("/" .. cwd .. "/"):find("/../", 1, true) then
        return nil, "unsafe"
    end
    -- Non-canonical forms and characters Claude's own encoding may treat differently.
    if cwd:find("//", 1, true) or ("/" .. cwd .. "/"):find("/./", 1, true) or (#cwd > 1 and cwd:sub(-1) == "/") then
        return nil, "unsafe"
    end
    for _, code in utf8.codes(cwd) do
        -- Astral: Claude counts UTF-16 units (two dashes), we count code points.
        if code >= 0x10000 or (code >= 0x80 and code <= 0x9F) or code == 0x2028 or code == 0x2029 then
            return nil, "unsafe"
        end
    end
    local encoded = encodeCwd(cwd)
    if #encoded > 200 then
        return nil, "unsafe"
    end
    if encoded == session.projectDir then
        return nil, "same_dir"
    end
    return cwd, nil
end

-- Moves the transcript and its sidecar into the cwd's project folder as
-- direct argv steps, each after the previous one, stopping at the first
-- failure. The cwd must exist; mv -n never overwrites; an existing target is
-- refused up front.
function M.repairSession(session, done)
    local cwd, code = M.repairTarget(session)
    if not cwd then
        done(false, code)
        return
    end
    if not noctalia.fileExists(cwd) then
        done(false, "cwd_missing")
        return
    end
    local target = PROJECTS_DIR .. "/" .. encodeCwd(cwd)
    if noctalia.fileExists(`{target}/{session.id}.jsonl`) then
        done(false, "exists")
        return
    end
    local hasSidecar = noctalia.fileExists(session.sidecarDir)
    if hasSidecar and noctalia.fileExists(`{target}/{session.id}`) then
        done(false, "exists")
        return
    end
    local steps = { { argv = { "mkdir", "-p", "--", target }, code = "mkdir" } }
    table.insert(steps, { argv = { "mv", "-n", "--", session.jsonlPath, target .. "/" }, code = "move" })
    if hasSidecar then
        table.insert(steps, { argv = { "mv", "-n", "--", session.sidecarDir, target .. "/" }, code = "sidecar" })
    end
    local function run(i)
        local step = steps[i]
        if step == nil then
            -- mv -n exits 0 when it skips, so check the result.
            if not noctalia.fileExists(`{target}/{session.id}.jsonl`) or noctalia.fileExists(session.jsonlPath) then
                done(false, "move")
            elseif hasSidecar and (not noctalia.fileExists(`{target}/{session.id}`) or noctalia.fileExists(session.sidecarDir)) then
                done(false, "sidecar")
            else
                done(true)
            end
            return
        end
        local started = noctalia.runAsync(step.argv, function(result)
            if type(result) == "table" and result.exitCode == 0 then
                run(i + 1)
            else
                done(false, step.code)
            end
        end)
        if not started then
            done(false, step.code)
        end
    end
    run(1)
end

-- ── Orphan leftovers ─────────────────────────────────────────────────────
-- list-claude-orphans is read-only; removal happens here, after every path
-- is re-validated in Lua, as direct argv execs (no shell).

local orphansPath = `{noctalia.pluginDir()}/list-claude-orphans`
local UUID_PAT = ("%x"):rep(8) .. ("%-" .. ("%x"):rep(4)):rep(3) .. "%-" .. ("%x"):rep(12)

-- Scans for orphans, keeping every id in liveIds. done(orphans, err).
function M.checkOrphans(liveIds, done)
    local argv = { "bash", orphansPath }
    for _, id in ipairs(liveIds) do
        if validId(id) then
            table.insert(argv, "--exclude")
            table.insert(argv, id)
        end
    end
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) ~= "table" or result.success == false or result.exitCode ~= 0 then
            done(nil, noctalia.tr("err_sessions_fetch"))
            return
        end
        local data = noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" or type(data.orphans) ~= "table" then
            done(nil, noctalia.tr("err_sessions_data"))
            return
        end
        done(data.orphans, nil)
    end)
    if not ok then
        done(nil, noctalia.tr("err_sessions_launch"))
    end
end

-- The orphan's own name when its path is exactly <parent>/<name> with a
-- clean name, else nil.
local function childName(path, parent)
    if type(path) ~= "string" or path:sub(1, #parent + 1) ~= parent .. "/" then
        return nil
    end
    local name = path:sub(#parent + 2)
    if name == "" or name == "." or name == ".." or name:find("/", 1, true) or name:find("%c") then
        return nil
    end
    return name
end

-- Removes the orphans checkOrphans returned. All-or-nothing validation first:
-- one bad entry refuses the whole batch and nothing runs.
function M.removeOrphans(orphans, done)
    local idPaths, projects = {}, {}
    for _, o in ipairs(orphans) do
        local kind = type(o) == "table" and o.kind
        if kind == "session-env" or kind == "file-history" then
            local name = childName(o.path, kind == "session-env" and SESSION_ENV_DIR or FILE_HISTORY_DIR)
            if not name or not name:match("^" .. UUID_PAT .. "$") then
                done(false)
                return
            end
            table.insert(idPaths, o.path)
        elseif kind == "project" then
            if not childName(o.path, PROJECTS_DIR) then
                done(false)
                return
            end
            table.insert(projects, o.path)
        else
            done(false)
            return
        end
    end
    -- Sequential: id folders, then each project's (empty) memory dir, then the project dir.
    local function removeProjects()
        if #projects == 0 then
            done(true)
            return
        end
        local memories = {}
        for _, p in ipairs(projects) do
            table.insert(memories, p .. "/memory")
        end
        table.insert(memories, 1, "--")
        table.insert(memories, 1, "rmdir")
        -- A project without memory/ makes this rmdir fail harmlessly: ignored.
        local started = noctalia.runAsync(memories, function()
            local argv = { "rmdir", "--" }
            for _, p in ipairs(projects) do
                table.insert(argv, p)
            end
            if not noctalia.runAsync(argv, function(result)
                done(type(result) == "table" and result.exitCode == 0)
            end) then
                done(false)
            end
        end)
        if not started then
            done(false)
        end
    end
    if #idPaths == 0 then
        removeProjects()
        return
    end
    local argv = { "rm", "-rf", "--" }
    for _, p in ipairs(idPaths) do
        table.insert(argv, p)
    end
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) == "table" and result.exitCode == 0 then
            removeProjects()
        else
            done(false)
        end
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
