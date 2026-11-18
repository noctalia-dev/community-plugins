--!nonstrict
-- shared — the search core behind all entries (bar widget, panel, launcher
-- provider, Space tab), pulled in via require().
--
-- Owns the search STATE and the helpers that read it:
--   scope        which roots the index covers ("folder" | "all")
--   whole        whole-system search ("/" instead of the search folder)
--   folders      the extra folder list joins the search folder
--   ranking      fzf scoring ("default" | "path")
--   schemeSupported  the installed fzf understands --scheme
--   mounts / mountsAt  removable volume mount points / time of the last scan
--   roots        what an index built now would cover, ancestors first
--   indexRoots / absoluteRecords  how the index on disk was built
-- Each entry is its own Luau host with its own instance of this module; the
-- files under pluginDataDir() are the only channel between them.

local shared = {}

-- ── constants ────────────────────────────────────────────────────────────────

-- Part of the cache fingerprint; bump when the record format or the pruned names change.
shared.INDEX_FORMAT = "2"

-- Volume metadata pruned at every root (matched with -iname).
shared.VOLUME_NOISE = {
    "lost+found",
    -- Windows / NTFS
    "$RECYCLE.BIN", "RECYCLER", "System Volume Information",
    -- Linux XDG trash on removable media (.Trash-<uid>)
    ".Trash-*",
    -- macOS volume services
    ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
    ".DocumentRevisions-V100", ".PKInstallSandboxManager",
    -- macOS Time Machine
    "Backups.backupdb", "*.sparsebundle", "*.backupbundle",
    -- AppleDouble sidecars and AFP/netatalk leftovers
    "._*", ".DS_Store", ".AppleDouble", ".AppleDB", ".AppleDesktop",
    "Network Trash Folder", "Temporary Items", "TheVolumeSettingsFolder",
}

-- Search scope: which roots the index covers. Persisted as a one-word file in the plugin data directory.
shared.SCOPE_GLYPHS = { folder = "folder", all = "folders" }
shared.NEXT_SCOPE = { folder = "all", all = "folder" }
shared.DEFAULT_SCOPE = "folder"

-- How fzf scores a match, persisted next to the scope: "path" is --scheme=path, "default" is fzf's generic scoring.
shared.RANKING_GLYPHS = { default = "arrows-sort", path = "sitemap" }
shared.NEXT_RANKING = { default = "path", path = "default" }
shared.DEFAULT_RANKING = "path"

-- Walk timeouts in ms, by scope.
shared.BUILD_TIMEOUT_LOCAL = 180000
shared.BUILD_TIMEOUT_DISKS = 1800000

-- Seconds a mount scan stays good for.
shared.MOUNT_TTL = 30

shared.BUILD_TIMEOUT_WHOLE = 600000

-- Filesystems a whole-system walk may enter; every other /proc/mounts entry is pruned by path.
shared.LOCAL_FS = {
    ext2 = true, ext3 = true, ext4 = true, btrfs = true, xfs = true,
    f2fs = true, bcachefs = true, zfs = true, jfs = true, reiserfs = true,
    nilfs2 = true, vfat = true, msdos = true, exfat = true, ntfs = true,
    ntfs3 = true, fuseblk = true, hfs = true, hfsplus = true, tmpfs = true,
}

-- Remote filesystems (any "fuse" / "fuse.<name>" type counts too, see isRemote).
shared.REMOTE_FS = {
    nfs = true, nfs4 = true, cifs = true, smb3 = true, smbfs = true, davfs = true,
    ceph = true, glusterfs = true, afs = true, ["9p"] = true, lustre = true,
}

-- Always pruned from a whole-system walk.
shared.WHOLE_SKIP = { "/proc", "/sys", "/dev", "/run" }

-- ── state ────────────────────────────────────────────────────────────────────

shared.scope = shared.DEFAULT_SCOPE
shared.whole = false        -- whole-system search ("/" instead of the search folder)
shared.folders = false      -- the extra folder list joins the search folder
shared.ranking = shared.DEFAULT_RANKING
shared.schemeSupported = false
shared.mounts = {}          -- mount points of the detected removable volumes
shared.mountsAt = 0         -- unix seconds of the last mount scan (0 = never)
shared.roots = {}           -- what an index built now would cover, ancestors first
shared.indexRoots = {}      -- what the index ON DISK was built with (indexRootsOf)
shared.absoluteRecords = false -- records are absolute (set when #indexRoots > 1)

local probing = false
local pendingProbeDone = nil

-- ── small helpers ────────────────────────────────────────────────────────────

function shared.tr(key, args)
    return noctalia.tr(key, args)
end

function shared.trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function shared.shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function shared.startsWith(value, prefix)
    return value:sub(1, #prefix) == prefix
end

-- Wall-clock seconds.
function shared.now()
    return noctalia.nowMs() / 1000
end

-- Byte count as text, three significant figures.
function shared.formatBytes(n)
    local units = { "B", "KB", "MB", "GB", "TB" }
    local index, value = 1, n + 0.0
    while value >= 1024 and index < #units do
        value /= 1024
        index += 1
    end
    if value >= 100 or index == 1 then
        return string.format("%.0f %s", value, units[index])
    end
    return string.format("%.1f %s", value, units[index])
end

-- Open a path with the system MIME association.
function shared.openPath(path)
    noctalia.runAsync({ "xdg-open", path })
end

-- file:// URI for a local path; every byte outside the unreserved set is percent-encoded.
local function fileUri(path)
    return "file://" .. (path:gsub("[^%w%-%._~/]", function(byte)
        return string.format("%%%02X", string.byte(byte))
    end))
end

-- Show the entry selected in its containing folder (FileManager1.ShowItems);
-- falls back to opening the containing folder.
function shared.revealPath(path)
    local parent = path:match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then
        parent = "/"
    end
    local ok = noctalia.runAsync({
        "gdbus",
        "call",
        "--session",
        "--dest",
        "org.freedesktop.FileManager1",
        "--object-path",
        "/org/freedesktop/FileManager1",
        "--method",
        "org.freedesktop.FileManager1.ShowItems",
        '["' .. fileUri(path) .. '"]',
        "",
    }, function(result)
        if result.exitCode ~= 0 or result.timedOut then
            shared.openPath(parent)
        end
    end, 5000)
    if not ok then
        shared.openPath(parent)
    end
end

-- ── fzf capability + scoring ─────────────────────────────────────────────────

-- Sets schemeSupported from `fzf --version` (--scheme needs fzf >= 0.36); one spawn per script load.
function shared.probeFzfScheme()
    noctalia.runAsync("fzf --version 2>/dev/null", function(result)
        local major, minor = (result.stdout or ""):match("(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
        shared.schemeSupported = major ~= nil and minor ~= nil and (major > 0 or minor >= 36)
    end, 5000)
end

-- The scoring flag for the next search: what the toggle asks for, if fzf can.
function shared.rankingFlag()
    return (shared.ranking == "path" and shared.schemeSupported) and " --scheme=path" or ""
end

-- Whether the plugin may start a walk by itself: only for the search folder scope.
function shared.autoIndexAllowed()
    return shared.scope == "folder"
end

-- ── plugin data directory ────────────────────────────────────────────────────

-- Private per-plugin storage; nil (with a log line) when no state directory resolves.
function shared.dataDir()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("file-search: pluginDataDir failed: " .. tostring(err))
        return nil
    end
    return dir
end

-- A folder added by hand must be a plain absolute path: no control characters, no ".", ".." or empty segment, not "/".
function shared.validRoot(path)
    if path:sub(1, 1) ~= "/" or path == "/" or path:find("%c") ~= nil or path:find("//", 1, true) ~= nil then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then
            return false
        end
    end
    return true
end

-- Folders added from the panel, one absolute path per line in the plugin data directory; invalid lines are dropped.
function shared.extraRoots()
    local dir = shared.dataDir()
    local raw = dir and noctalia.readFile(dir .. "/extra_roots")
    local list = {}
    if type(raw) ~= "string" then
        return list
    end
    for line in raw:gmatch("[^\n]+") do
        local path = line:gsub("/+$", "")
        if shared.validRoot(path) then
            table.insert(list, path)
        end
    end
    return list
end

function shared.writeExtraRoots(list)
    local dir = shared.dataDir()
    if dir == nil then
        return
    end
    local ok, err = noctalia.writeFile(dir .. "/extra_roots", table.concat(list, "\n"))
    if not ok then
        noctalia.log("file-search: could not persist the extra folders: " .. tostring(err))
    end
end

-- Shell header shared by every cache command: list, meta (fingerprint) and count files for the current cache tag.
function shared.cacheSh(dir)
    local tag = shared.cacheTag()
    return "CACHE_DIR=" .. shared.shellQuote(dir)
        .. '\nCACHE="$CACHE_DIR/list-' .. tag .. '"'
        .. '\nMETA="$CACHE_DIR/meta-' .. tag .. '"'
        .. '\nCOUNTF="$CACHE_DIR/count-' .. tag .. '"'
end

-- The cache file suffix: the scope, plus "-dirs" / "-root" for the folder list / whole-system index.
function shared.cacheTag()
    if shared.whole then
        return shared.scope .. "-root"
    end
    return shared.folders and (shared.scope .. "-dirs") or shared.scope
end

function shared.readFolders(dir)
    local raw = noctalia.readFile(dir .. "/folders")
    return type(raw) == "string" and shared.trim(raw) == "on"
end

function shared.writeFolders(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/folders", value and "on" or "off")
    if not ok then
        noctalia.log("file-search: could not persist the folder mode: " .. tostring(err))
    end
end

function shared.readWhole(dir)
    local raw = noctalia.readFile(dir .. "/whole-system")
    return type(raw) == "string" and shared.trim(raw) == "on"
end

function shared.writeWhole(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/whole-system", value and "on" or "off")
    if not ok then
        noctalia.log("file-search: could not persist whole-system search: " .. tostring(err))
    end
end

function shared.readScope(dir)
    local raw = noctalia.readFile(dir .. "/scope")
    if type(raw) == "string" then
        local value = shared.trim(raw)
        if value == "external" then
            return "all"
        end
        if shared.SCOPE_GLYPHS[value] ~= nil then
            return value
        end
    end
    return shared.DEFAULT_SCOPE
end

function shared.writeScope(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/scope", value)
    if not ok then
        noctalia.log("file-search: could not persist the scope: " .. tostring(err))
    end
end

function shared.readRanking(dir)
    local raw = noctalia.readFile(dir .. "/ranking")
    if type(raw) == "string" then
        local value = shared.trim(raw)
        if shared.RANKING_GLYPHS[value] ~= nil then
            return value
        end
    end
    return shared.DEFAULT_RANKING
end

function shared.writeRanking(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/ranking", value)
    if not ok then
        noctalia.log("file-search: could not persist the ranking: " .. tostring(err))
    end
end

-- ── settings ─────────────────────────────────────────────────────────────────

function shared.searchRoot()
    local dir = noctalia.getConfig("search_folder")
    if dir == nil or dir == "" then
        dir = noctalia.getenv("HOME") or "/tmp"
    else
        dir = noctalia.expandPath(dir)
    end
    dir = dir:gsub("/+$", "")
    if dir == "" then
        dir = "/"
    end
    return dir
end

-- Excluded directory names from the setting, split on ',' or ';'; entries containing '/' are skipped and logged. Hidden entries add a '.*' pattern.
function shared.excludeNames()
    local raw = noctalia.getConfig("exclude_dirs")
    if type(raw) ~= "string" then
        raw = ""
    end
    local names = {}
    for entry in raw:gmatch("[^,;]+") do
        local name = shared.trim(entry)
        if name:find("/") then
            noctalia.log("file-search: ignoring exclude entry with '/': '" .. name .. "'")
        elseif name ~= "" then
            table.insert(names, name)
        end
    end
    if noctalia.getConfig("show_hidden") ~= true then
        table.insert(names, ".*")
    end
    return names
end

-- ── removable volume detection ───────────────────────────────────────────────

-- A mount point worth indexing: absolute, not "/", no control character, not the boot partition.
function shared.usableMount(path)
    if path == nil or path == "" or path:sub(1, 1) ~= "/" then
        return false
    end
    if path == "/" or path:find("%c") ~= nil then
        return false
    end
    return path ~= "/boot" and not shared.startsWith(path, "/boot/")
end

-- Decodes \xNN escapes in an lsblk value; nil when one decodes to a control byte.
function shared.unescapeHex(value)
    local rejected = false
    local out = value:gsub("\\x(%x%x)", function(hex)
        local code = tonumber(hex, 16)
        if code == nil or code < 32 or code == 127 then
            rejected = true
            return ""
        end
        return string.char(code)
    end)
    if rejected then
        return nil
    end
    return out
end

function shared.pairValue(line, key)
    return (" " .. line):match(" " .. key .. '="(.-)"')
end

-- Mount points of the volumes that are USB or removable; the PKNAME chain is
-- walked up to the parent disk, which carries TRAN / RM.
function shared.parseLsblk(out)
    local rows, byName = {}, {}
    for line in out:gmatch("[^\n]+") do
        local name = shared.pairValue(line, "NAME")
        if name ~= nil and name ~= "" then
            local row = {
                parent = shared.pairValue(line, "PKNAME") or "",
                removable = shared.pairValue(line, "RM") == "1",
                transport = shared.pairValue(line, "TRAN") or "",
                mount = shared.unescapeHex(shared.pairValue(line, "MOUNTPOINT") or ""),
            }
            byName[name] = row
            table.insert(rows, row)
        end
    end
    local found = {}
    for _, row in ipairs(rows) do
        if shared.usableMount(row.mount) then
            local node, depth = row, 0
            while node ~= nil and depth < 4 do
                if node.transport == "usb" or node.removable then
                    table.insert(found, row.mount)
                    break
                end
                node = (node.parent ~= "") and byName[node.parent] or nil
                depth += 1
            end
        end
    end
    return found
end

-- Fallback without util-linux: removable mounts under /run/media/<user>/ and /media/ from /proc/mounts.
function shared.fallbackMounts()
    local text = noctalia.readFile("/proc/mounts")
    if type(text) ~= "string" then
        return {}
    end
    local found = {}
    for line in text:gmatch("[^\n]+") do
        local raw = line:match("^%S+%s+(%S+)%s")
        if raw ~= nil then
            local rejected = false
            local path = raw:gsub("\\(%d%d%d)", function(octal)
                local code = tonumber(octal, 8)
                if code == nil or code < 32 or code == 127 then
                    rejected = true
                    return ""
                end
                return string.char(code)
            end)
            if rejected then
                path = ""
            end
            local rest = path:match("^/run/media/[^/]+/(.+)$") or path:match("^/media/(.+)$")
            if rest ~= nil and rest ~= "" and shared.usableMount(path) then
                table.insert(found, path)
            end
        end
    end
    return found
end

-- Whether a mount scan is in flight.
function shared.probeBusy()
    return probing
end

-- Refresh `shared.mounts`, then call done(). No spawn for the search-folder
-- scope (unless `any`); a scan younger than MOUNT_TTL is reused unless `force`.
-- A caller arriving during a scan replaces the waiting continuation (latest wins).
function shared.probeMounts(force, done, any)
    if shared.scope == "folder" and not shared.whole and not any then
        shared.mounts = {}
        shared.mountsAt = 0
        done()
        return
    end
    if not force and shared.mountsAt > 0 and (shared.now() - shared.mountsAt) < shared.MOUNT_TTL then
        done()
        return
    end
    if probing then
        pendingProbeDone = done
        return
    end
    local function finish()
        shared.mountsAt = shared.now()
        probing = false
        local queued = pendingProbeDone
        pendingProbeDone = nil
        done()
        if queued ~= nil then
            queued()
        end
    end
    if not noctalia.commandExists("lsblk") then
        shared.mounts = shared.fallbackMounts()
        finish()
        return
    end
    probing = true
    local ok = noctalia.runAsync("lsblk -P -o NAME,PKNAME,RM,TRAN,MOUNTPOINT 2>/dev/null", function(result)
        if result.exitCode == 0 and not result.timedOut then
            shared.mounts = shared.parseLsblk(result.stdout or "")
        else
            shared.mounts = shared.fallbackMounts()
        end
        finish()
    end, 10000)
    if not ok then
        shared.mounts = shared.fallbackMounts()
        finish()
    end
end

-- ── index identity ───────────────────────────────────────────────────────────

-- The roots the index covers, ancestors first and without nested overlaps. A
-- whole-system "/" root keeps the mounts as separate roots (wholePrunePaths prunes them).
function shared.computeRoots()
    local list = {}
    local whole = shared.whole
    if not whole then
        table.insert(list, shared.searchRoot())
        if shared.folders then
            for _, extra in ipairs(shared.extraRoots()) do
                table.insert(list, extra)
            end
        end
    end
    if shared.scope ~= "folder" then
        for _, mount in ipairs(shared.mounts) do
            table.insert(list, (mount:gsub("/+$", "")))
        end
    end
    table.sort(list)
    local kept = {}
    for _, path in ipairs(list) do
        local nested = false
        for _, parent in ipairs(kept) do
            if path == parent or shared.startsWith(path, parent == "/" and "/" or parent .. "/") then
                nested = true
                break
            end
        end
        if path ~= "" and not nested then
            table.insert(kept, path)
        end
    end
    if whole then
        table.insert(kept, 1, "/")
    end
    return kept
end

local function isRemote(fstype)
    return shared.REMOTE_FS[fstype] or fstype == "fuse" or fstype:sub(1, 5) == "fuse."
end

-- Paths a walk of "/" must not enter: WHOLE_SKIP and every pseudo mount;
-- opts.network adds the remote mounts, opts.external the removable disks.
-- Read from /proc/mounts at build time only; nested paths are dropped.
function shared.prunePaths(opts)
    local list = {}
    for _, path in ipairs(shared.WHOLE_SKIP) do
        table.insert(list, path)
    end
    local text = noctalia.readFile("/proc/mounts")
    if type(text) == "string" then
        for line in text:gmatch("[^\n]+") do
            local raw, fstype = line:match("^%S+%s+(%S+)%s+(%S+)")
            if raw ~= nil and not shared.LOCAL_FS[fstype] and (opts.network or not isRemote(fstype)) then
                local rejected = false
                local path = raw:gsub("\\(%d%d%d)", function(octal)
                    local code = tonumber(octal, 8)
                    if code == nil or code < 32 or code == 127 then
                        rejected = true
                        return ""
                    end
                    return string.char(code)
                end)
                if not rejected and path ~= "/" and path:sub(1, 1) == "/" then
                    table.insert(list, path)
                end
            end
        end
    end
    if opts.external then
        for _, mount in ipairs(shared.mounts) do
            table.insert(list, (mount:gsub("/+$", "")))
        end
    end
    table.sort(list)
    local kept = {}
    for _, path in ipairs(list) do
        local last = kept[#kept]
        if path ~= "" and path ~= last and (last == nil or not shared.startsWith(path, last .. "/")) then
            table.insert(kept, path)
        end
    end
    return kept
end

-- The Search tab's whole-system walk: remote mounts and removable disks too.
function shared.wholePrunePaths()
    return shared.prunePaths({ network = true, external = true })
end

-- The fingerprint of how the cache was built: format, scope, roots and exclusions. All entries recognize an index by it.
function shared.indexKey()
    return shared.INDEX_FORMAT .. "\n" .. shared.scope
        .. "\n--\n" .. table.concat(shared.roots, "\n")
        .. "\n--\n" .. table.concat(shared.excludeNames(), "\n")
end

-- Whether the cache on disk matches the current fingerprint.
function shared.cacheFresh(dir)
    return noctalia.readFile(dir .. "/meta-" .. shared.cacheTag()) == shared.indexKey()
end

-- The roots the index on disk was built with, read back from its fingerprint; nil when there is no index.
function shared.indexRootsOf(dir)
    local meta = noctalia.readFile(dir .. "/meta-" .. shared.cacheTag())
    if type(meta) ~= "string" then
        return nil
    end
    local section = meta:match("\n%-%-\n(.-)\n%-%-\n")
    if section == nil then
        return nil
    end
    local list = {}
    for line in section:gmatch("[^\n]+") do
        table.insert(list, line)
    end
    return #list > 0 and list or nil
end

-- An index record turned into a path, or nil when it could resolve outside the index roots. Call from callbacks, not from render.
function shared.absolutePath(record)
    if record == "" or record:find("%c") ~= nil then
        return nil
    end
    local path = record:gsub("/+$", "")
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            return nil
        end
    end
    -- Validated against the roots of the index the record came from.
    local from = #shared.indexRoots > 0 and shared.indexRoots or shared.roots
    if shared.absoluteRecords then
        for _, root in ipairs(from) do
            if shared.startsWith(path, root == "/" and "/" or root .. "/") then
                return path
            end
        end
        return nil
    end
    local root = from[1]
    if root == nil or path == "" or path:sub(1, 1) == "/" then
        return nil
    end
    if root == "/" then
        return root .. path
    end
    return root .. "/" .. path
end

-- ── the two commands ─────────────────────────────────────────────────────────

-- Seconds a walk of the current scope is allowed to take.
function shared.buildTimeout()
    local extras = shared.folders and not shared.whole and #shared.extraRoots() > 0
    if shared.scope ~= "folder" or extras then
        return shared.BUILD_TIMEOUT_DISKS
    end
    return shared.whole and shared.BUILD_TIMEOUT_WHOLE or shared.BUILD_TIMEOUT_LOCAL
end

-- The tree walk as a shell script; `key` is the fingerprint it leaves in the meta file.
-- Cache, meta and count files are written via mktemp and renamed into place;
-- stale temp files older than 90 minutes are removed.
-- On success it prints "<count> <elapsed_ms>" and writes the same pair to the count file.
function shared.buildCommand(dir, key, absolute)
    -- Names containing a newline are pruned first, then volume noise, then user exclusions.
    local names = { "-name " .. shared.shellQuote("*\n*") }
    for _, pattern in ipairs(shared.VOLUME_NOISE) do
        table.insert(names, "-iname " .. shared.shellQuote(pattern))
    end
    for _, name in ipairs(shared.excludeNames()) do
        table.insert(names, "-name " .. shared.shellQuote(name))
    end
    -- A whole-system walk also prunes mount points by full path (glob characters escaped).
    if shared.whole and shared.roots[1] == "/" then
        for _, path in ipairs(shared.wholePrunePaths()) do
            local glob = path:gsub("[%*%?%[%]\\]", "\\%0")
            table.insert(names, "-path " .. shared.shellQuote(glob))
        end
    end
    local prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    local args = {}
    for _, root in ipairs(shared.roots) do
        table.insert(args, shared.shellQuote(root))
    end
    -- Records are relative to the root (%P) for a single root, absolute (%p) for several.
    local printSpec = absolute
        and "-type d -printf '%p/\\n' -o -printf '%p\\n'"
        or "-type d -printf '%P/\\n' -o -printf '%P\\n'"
    local walk = "find " .. table.concat(args, " ") .. " -mindepth 1 " .. prune
        .. printSpec .. ' > "$TMP" 2>/dev/null'

    return shared.cacheSh(dir)
        .. '\nrm -f "$CACHE_DIR/index.list" "$CACHE_DIR/index.meta"\n'
        .. 'find "$CACHE_DIR" -maxdepth 1 \\( -name \'list-*.*\' -o -name \'meta-*.*\''
        .. " -o -name 'count-*.*' \\) -mmin +90 -delete 2>/dev/null\n"
        .. 'START=$(date +%s%3N)\n'
        .. 'TMP=$(mktemp "$CACHE_DIR/list-' .. shared.cacheTag() .. '.XXXXXX") || exit 1\n'
        .. walk .. "\n"
        .. 'mv -f "$TMP" "$CACHE" || exit 1\n'
        .. 'TMPM=$(mktemp "$CACHE_DIR/meta-' .. shared.cacheTag() .. '.XXXXXX") || exit 1\n'
        .. "printf '%s' " .. shared.shellQuote(key) .. ' > "$TMPM"\n'
        .. 'mv -f "$TMPM" "$META" || exit 1\n'
        .. 'COUNT=$(wc -l < "$CACHE") || exit 1\n'
        .. 'ELAPSED=$(( $(date +%s%3N) - START ))\n'
        .. 'TMPN=$(mktemp "$CACHE_DIR/count-' .. shared.cacheTag() .. '.XXXXXX") || exit 1\n'
        .. 'printf "%s %s" "$COUNT" "$ELAPSED" > "$TMPN"\n'
        .. 'mv -f "$TMPN" "$COUNTF" || exit 1\n'
        .. 'printf "%s %s" "$COUNT" "$ELAPSED"'
end

-- One search over the cache, capped at `limit` rows; an empty query returns the head of the index.
function shared.searchCommand(dir, text, limit)
    if shared.trim(text) == "" then
        return shared.cacheSh(dir) .. '\nhead -n ' .. limit .. ' "$CACHE" 2>/dev/null'
    end
    return shared.cacheSh(dir) .. "\nfzf" .. shared.rankingFlag()
        .. " --filter=" .. shared.shellQuote(text)
        .. ' < "$CACHE" 2>/dev/null | head -n ' .. limit
end

return shared
