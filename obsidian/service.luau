--!nonstrict
-- Obsidian vault: daily capture + git status/commit/pull/push.

local STATE_KEY = "obs_snapshot"
local COMMAND_KEY = "obs_command"
local RESULT_KEY = "obs_action_result"

local MAX_RECENT = 40
local MAX_GIT_FILES = 40

local snapshot = {
  available = false,
  loading = true,
  busy = false,
  vaultPath = "",
  vaultName = "",
  dailyPath = "",
  dailyRel = "",
  dailyExists = false,
  dailyPreview = "",
  recent = {},
  git = {
    isRepo = false,
    branch = "",
    dirty = 0,
    ahead = 0,
    behind = 0,
    clean = true,
    files = {},
    statusLine = "",
    inProgress = "", -- "rebase" | "merge" | ""
  },
  error = "",
  updatedAt = 0,
  revision = 0,
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local actionBusy = false
local dataSignature = ""

local function trim(v)
  return noctalia.string.trim(tostring(v or ""))
end

local function shellQuote(v)
  return "'" .. tostring(v):gsub("'", "'\\''") .. "'"
end

local function shellCommand(args)
  local q = {}
  for _, a in ipairs(args) do
    table.insert(q, shellQuote(a))
  end
  return table.concat(q, " ")
end

local function expand(path)
  return noctalia.expandPath(trim(path))
end

local function nowSec()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return math.floor(ms / 1000)
    end
  end
  return os.time()
end

local function refreshIntervalMs()
  local s = tonumber(noctalia.getConfig("refresh_interval")) or 20
  s = math.max(5, math.min(300, math.floor(s)))
  return s * 1000
end

local function shouldNotify()
  return noctalia.getConfig("notify_on_action") ~= false
end

local function vaultRoot()
  return expand(noctalia.getConfig("vault_path") or "")
end

local function vaultName()
  local n = trim(noctalia.getConfig("vault_name"))
  if n ~= "" then
    return n
  end
  local root = vaultRoot()
  return root:match("([^/]+)$") or "vault"
end

local function dailyFolder()
  return trim(noctalia.getConfig("daily_folder"))
end

local function dailyFormat()
  local f = trim(noctalia.getConfig("daily_format"))
  if f == "" then
    return "%Y-%m-%d"
  end
  return f
end

local function isVault(path)
  if path == "" or not noctalia.fileExists(path) then
    return false
  end
  return noctalia.fileExists(path .. "/.obsidian")
end

local function joinPath(a, b)
  a = tostring(a or ""):gsub("/+$", "")
  b = tostring(b or ""):gsub("^/+", "")
  if a == "" then return b end
  if b == "" then return a end
  return a .. "/" .. b
end

-- Strict relative path: no absolute paths, no ".." / ".", no backslashes/NUL.
-- Returns cleaned relative path, or nil if rejected.
local function normalizeRelPath(rel)
  rel = trim(rel):gsub("\\", "/")
  if rel == "" then
    return ""
  end
  if rel:find("\0", 1, true) then
    return nil
  end
  -- Absolute (Unix or Windows drive)
  if rel:sub(1, 1) == "/" or rel:match("^%a:[/\\]") then
    return nil
  end
  -- Collapse slashes and reject . / .. segments
  local parts = {}
  for seg in (rel .. "/"):gmatch("([^/]*)/") do
    if seg == "" then
      -- skip leading/duplicate slashes
    elseif seg == "." or seg == ".." then
      return nil
    else
      table.insert(parts, seg)
    end
  end
  return table.concat(parts, "/")
end
-- Join vault root + relative path; require result stays under root (string check).
-- Returns absPath, cleanRel or nil, errKey
local function pathUnderVault(root, rel)
  root = expand(root):gsub("/+$", "")
  if root == "" then
    return nil, nil, "empty vault"
  end
  local clean = normalizeRelPath(rel)
  if clean == nil then
    return nil, nil, "invalid path"
  end
  local abs = clean == "" and root or (root .. "/" .. clean)
  if abs == root or abs:sub(1, #root + 1) == root .. "/" then
    return abs, clean, nil
  end
  return nil, nil, "path outside vault"
end

-- Async: reject symlink path components and require realpath(target) under realpath(vault).
-- onDone(ok, errMsg). Uses realpath(1) + test -L (same pattern as other community plugins).
local function assertSafeVaultTarget(root, abs, rel, onDone)
  root = expand(root):gsub("/+$", "")
  abs = expand(abs)
  rel = normalizeRelPath(rel or "")
  if type(onDone) ~= "function" then
    return
  end
  if root == "" or abs == "" or rel == nil then
    onDone(false, "invalid path")
    return
  end
  -- Shell: canonicalize vault; walk each segment of rel and refuse -L; realpath -m must stay under vault.
  local cmd = "V=$(realpath -e "
    .. shellQuote(root)
    .. " 2>/dev/null) || exit 1; "
    .. "A="
    .. shellQuote(abs)
    .. "; "
    .. "R="
    .. shellQuote(rel)
    .. "; "
    .. "cur="
    .. shellQuote(root)
    .. "; "
    .. 'IFS=/; set -f; for s in $R; do '
    .. '[ -n "$s" ] || continue; '
    .. 'next="$cur/$s"; '
    .. 'if [ -L "$next" ]; then exit 2; fi; '
    .. 'cur="$next"; '
    .. "done; set +f; "
    .. 'T=$(realpath -m "$A" 2>/dev/null) || exit 1; '
    .. 'case "$T" in "$V"|"$V"/*) exit 0 ;; *) exit 3 ;; esac'

  local started = noctalia.runAsync(cmd, function(result)
    if result and result.exitCode == 0 and not result.timedOut then
      onDone(true, nil)
    elseif result and result.exitCode == 2 then
      onDone(false, "symlink in path")
    elseif result and result.exitCode == 3 then
      onDone(false, "path outside vault")
    else
      onDone(false, "path check failed")
    end
  end, 4000)
  if not started then
    onDone(false, "path check failed")
  end
end

-- Build today's daily note relative + absolute path with strict validation.
-- daily_format must expand to a single path segment (no / or ..).
-- Returns rel, abs, errMessageOrNil
local function dailyRelAndAbs()
  local fmt = dailyFormat()
  if fmt:find("[/\\]") or fmt:find("%.%.") then
    return nil, nil, "invalid daily_format"
  end
  local stem = noctalia.formatTime(fmt, nowSec())
  if type(stem) ~= "string" or trim(stem) == "" then
    return nil, nil, "invalid daily name"
  end
  stem = trim(stem)
  if stem:find("[/\\]") or stem:find("\0", 1, true) or stem == "." or stem == ".." then
    return nil, nil, "invalid daily name"
  end
  -- Single path segment only (format must not introduce directories)
  if stem:find("/") then
    return nil, nil, "invalid daily name"
  end
  local name = stem
  if not name:match("%.[Mm][Dd]$") then
    name = name .. ".md"
  end

  local folder = dailyFolder()
  local rel
  if folder == "" then
    rel = name
  else
    local folderClean = normalizeRelPath(folder)
    if folderClean == nil then
      return nil, nil, "invalid daily_folder"
    end
    if folderClean == "" then
      rel = name
    else
      rel = folderClean .. "/" .. name
    end
  end

  local abs, clean, err = pathUnderVault(vaultRoot(), rel)
  if not abs then
    return nil, nil, err or "invalid path"
  end
  return clean, abs, nil
end

-- Back-compat helpers used only when path is known-good; prefer dailyRelAndAbs.
local function dailyRelPath()
  local rel = dailyRelAndAbs()
  return rel or ""
end

local function dailyAbsPath()
  local _, abs = dailyRelAndAbs()
  return abs or ""
end

local function ensureParentDir(path)
  local parent = path:match("(.+)/[^/]+$")
  if parent and parent ~= "" and not noctalia.fileExists(parent) then
    -- Only create parents that still lie under the vault root (string + prior symlink check).
    local root = vaultRoot():gsub("/+$", "")
    if root ~= "" and (parent == root or parent:sub(1, #root + 1) == root .. "/") then
      noctalia.mkdirAll(parent)
    end
  end
end

local function updateRevision(sig)
  if sig ~= dataSignature then
    dataSignature = sig
    snapshot.revision += 1
  end
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  noctalia.state.set(STATE_KEY, snapshot)
end

local function actionResult(command, ok, message, extra)
  local r = {
    requestId = command and command.requestId or "",
    action = command and command.action or "",
    ok = ok,
    message = message or "",
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      r[k] = v
    end
  end
  noctalia.state.set(RESULT_KEY, r)
end

local function notifyOk(msg)
  if shouldNotify() then
    noctalia.notify(noctalia.tr("title"), msg)
  end
end

local function notifyErr(msg)
  noctalia.notifyError(noctalia.tr("title"), msg)
end

local function runGit(args, callback, timeoutMs)
  local root = vaultRoot()
  local cmd = "cd " .. shellQuote(root) .. " && " .. shellCommand(args)
  return noctalia.runAsync(cmd, callback, timeoutMs or 60000)
end

-- Detect stuck rebase/merge so we never leave the vault detached.
local function gitInProgressKind()
  local root = vaultRoot()
  if root == "" then
    return ""
  end
  if noctalia.fileExists(root .. "/.git/rebase-merge")
    or noctalia.fileExists(root .. "/.git/rebase-apply")
  then
    return "rebase"
  end
  if noctalia.fileExists(root .. "/.git/MERGE_HEAD") then
    return "merge"
  end
  -- worktree / .git file case: still check common paths via git
  return ""
end

local function refuseIfGitBusy(command)
  local kind = gitInProgressKind()
  if kind == "" then
    -- also check snapshot if refresh already saw it
    kind = (snapshot.git and snapshot.git.inProgress) or ""
  end
  if kind ~= "" then
    actionResult(
      command,
      false,
      noctalia.tr("result.git_in_progress", { kind = kind })
    )
    notifyErr(noctalia.tr("result.git_in_progress", { kind = kind }))
    return true
  end
  return false
end

local function urlEncode(s)
  return noctalia.string.urlEncode(tostring(s or ""))
end

local function openUri(uri)
  noctalia.runAsync("xdg-open " .. shellQuote(uri))
end

local function openNoteRel(rel)
  local vault = vaultName()
  -- file param is vault-relative path without leading slash (already confined)
  rel = tostring(rel or ""):gsub("^/+", "")
  local uri = "obsidian://open?vault=" .. urlEncode(vault) .. "&file=" .. urlEncode(rel)
  openUri(uri)
end

-- Ensure daily file exists under a validated vault path (string + realpath/symlink checks).
-- onReady(rel, abs) when safe and ready; actionResult already set on failure.
local function ensureDailyFile(command, onReady)
  local root = vaultRoot()
  if not isVault(root) then
    actionResult(command, false, noctalia.tr("result.missing_vault"))
    return
  end
  local rel, abs, err = dailyRelAndAbs()
  if not abs then
    actionResult(command, false, noctalia.tr("result.invalid_daily_path", { error = err or "invalid" }))
    return
  end
  assertSafeVaultTarget(root, abs, rel, function(ok, safeErr)
    if not ok then
      actionResult(command, false, noctalia.tr("result.invalid_daily_path", { error = safeErr or "unsafe" }))
      return
    end
    if not noctalia.fileExists(abs) then
      ensureParentDir(abs)
      local title = noctalia.formatTime(dailyFormat(), nowSec())
      title = tostring(title or ""):gsub("[/\\]", "-")
      local wOk, werr = noctalia.writeFile(abs, "# " .. title .. "\n")
      if not wOk then
        actionResult(command, false, noctalia.tr("result.failed", { error = werr or "write failed" }))
        return
      end
    end
    if type(onReady) == "function" then
      onReady(rel, abs)
    end
  end)
end
local function openVault()
  local vault = vaultName()
  openUri("obsidian://open?vault=" .. urlEncode(vault))
end

local function readPreview(path, maxBytes)
  local raw = noctalia.readFile(path)
  if not raw then
    return ""
  end
  raw = tostring(raw)
  if #raw > (maxBytes or 400) then
    raw = raw:sub(1, maxBytes or 400) .. "…"
  end
  return raw
end

local function parseGitStatus(stdout)
  local files = {}
  local dirty = 0
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      dirty += 1
      if #files < MAX_GIT_FILES then
        local xy = line:sub(1, 2)
        local path = trim(line:sub(4))
        -- rename: "R  old -> new"
        path = path:gsub("^.*%->%s*", "")
        table.insert(files, {
          id = path,
          path = path,
          code = xy,
        })
      end
    end
  end
  return dirty, files
end

local function parseBranchLine(stdout)
  -- ## main...origin/main [ahead 1, behind 2]
  local line = tostring(stdout or ""):match("([^\n]+)") or ""
  local branch = line:match("^##%s+([^%.%s]+)") or line:match("^##%s+(%S+)") or ""
  branch = branch:gsub("%.%.%..*$", "")
  local ahead = tonumber(line:match("ahead%s+(%d+)")) or 0
  local behind = tonumber(line:match("behind%s+(%d+)")) or 0
  return branch, ahead, behind, line
end

local function parseRecent(stdout)
  local recent = {}
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    local ts, rel = line:match("^([%d%.]+)\t(.+)$")
    if rel and rel ~= "" then
      -- Drop any path find might surface that fails strict relative rules
      -- (absolute, .., NUL, etc.). open_note also re-checks + assertSafeVaultTarget.
      local clean = normalizeRelPath(rel)
      if clean ~= nil and clean ~= "" then
        local name = clean:match("([^/]+)$") or clean
        table.insert(recent, {
          id = clean,
          rel = clean,
          name = name:gsub("%.md$", ""),
          mtime = math.floor(tonumber(ts) or 0),
        })
      end
    end
  end
  return recent
end

local refreshAll

local function finishAction(command, ok, message)
  actionBusy = false
  actionResult(command, ok, message)
  if ok then
    notifyOk(message)
  else
    notifyErr(message)
  end
  publishSnapshot()
  refreshAll()
end

refreshAll = function()
  if refreshPending then
    refreshAgain = true
    return
  end
  refreshPending = true
  refreshAgain = false
  refreshGeneration += 1
  local generation = refreshGeneration

  local root = vaultRoot()
  snapshot.vaultPath = root
  snapshot.vaultName = vaultName()

  local dailyRel, dailyAbs, dailyErr = dailyRelAndAbs()
  snapshot.dailyRel = dailyRel or ""
  snapshot.dailyPath = dailyAbs or ""

  if not isVault(root) then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("result.missing_vault")
    snapshot.recent = {}
    snapshot.dailyExists = false
    snapshot.dailyPreview = ""
    snapshot.git = {
      isRepo = false,
      branch = "",
      dirty = 0,
      ahead = 0,
      behind = 0,
      clean = true,
      files = {},
      statusLine = "",
      inProgress = "",
    }
    refreshPending = false
    updateRevision("no-vault")
    publishSnapshot()
    return
  end

  snapshot.available = true
  if dailyErr then
    snapshot.error = noctalia.tr("result.invalid_daily_path", { error = dailyErr })
  else
    snapshot.error = ""
  end
  if (snapshot.updatedAt or 0) == 0 then
    snapshot.loading = true
    publishSnapshot()
  end

  local pending = 3
  local bag = { recent = {}, gitPorcelain = "", gitBranch = "" }
  local finished = false

  local function finish()
    if generation ~= refreshGeneration then
      return
    end
    pending -= 1
    if pending > 0 or finished then
      return
    end
    finished = true

    local function applySnapshot(dailyExists, dailyPreview)
      local okP, errP = pcall(function()
        snapshot.dailyExists = dailyExists == true
        snapshot.dailyPreview = dailyPreview or ""
        snapshot.recent = parseRecent(bag.recent)
        local dirty, files = parseGitStatus(bag.gitPorcelain)
        local branch, ahead, behind, statusLine = parseBranchLine(bag.gitBranch)
        local isRepo = not bag.gitFailed and (branch ~= "" or statusLine:match("^##") ~= nil)

        snapshot.git = {
          isRepo = isRepo,
          branch = branch,
          dirty = dirty,
          ahead = ahead,
          behind = behind,
          clean = dirty == 0,
          files = files,
          statusLine = statusLine,
          inProgress = gitInProgressKind(),
        }
        snapshot.loading = false
        snapshot.updatedAt = nowSec()
        refreshPending = false
        updateRevision(table.concat({
          snapshot.dailyRel,
          tostring(snapshot.dailyExists),
          tostring(#snapshot.recent),
          branch,
          tostring(dirty),
          tostring(ahead),
          tostring(behind),
        }, "|"))
        publishSnapshot()
      end)

      if not okP then
        noctalia.log(`obsidian: apply failed: {tostring(errP)}`)
        snapshot.loading = false
        snapshot.error = tostring(errP)
        refreshPending = false
        publishSnapshot()
      end

      if refreshAgain then
        refreshAgain = false
        refreshAll()
      end
    end

    -- Only read daily preview after symlink/realpath confinement passes
    if snapshot.dailyPath ~= "" and snapshot.dailyRel ~= "" and noctalia.fileExists(snapshot.dailyPath) then
      assertSafeVaultTarget(root, snapshot.dailyPath, snapshot.dailyRel, function(ok, _err)
        if generation ~= refreshGeneration then
          return
        end
        if ok then
          applySnapshot(true, readPreview(snapshot.dailyPath, 500))
        else
          -- Exists but unsafe (symlink escape) — do not read through it
          applySnapshot(false, "")
        end
      end)
    else
      applySnapshot(false, "")
    end
  end

  -- recent files: -P never follows symlinks (GNU default, explicit for review/portability).
  -- -type f excludes symlink notes; symlink dirs are not descended into.
  local recentCmd = "find -P "
    .. shellQuote(root)
    .. " -type f -name '*.md'"
    .. " ! -path '*/.obsidian/*' ! -path '*/.git/*' ! -path '*/.claudian/*'"
    .. " -printf '%T@\\t%P\\n' 2>/dev/null | sort -nr | head -n "
    .. tostring(MAX_RECENT)
  noctalia.runAsync(recentCmd, function(result)
    if generation ~= refreshGeneration then return end
    bag.recent = (result and result.stdout) or ""
    finish()
  end, 20000)

  -- git porcelain
  runGit({ "git", "status", "--porcelain" }, function(result)
    if generation ~= refreshGeneration then return end
    if result and result.exitCode == 0 then
      bag.gitPorcelain = result.stdout or ""
    else
      bag.gitPorcelain = ""
      bag.gitFailed = true
    end
    finish()
  end, 15000)

  -- git branch / ahead behind
  runGit({ "git", "status", "-sb" }, function(result)
    if generation ~= refreshGeneration then return end
    if result and result.exitCode == 0 then
      bag.gitBranch = result.stdout or ""
    else
      bag.gitBranch = ""
      bag.gitFailed = true
    end
    finish()
  end, 15000)
end

local function appendDaily(command)
  local text = trim(command.text or command.line or "")
  if text == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "empty note" }))
    return
  end
  local root = vaultRoot()
  if not isVault(root) then
    actionResult(command, false, noctalia.tr("result.missing_vault"))
    return
  end

  local rel, path, pathErr = dailyRelAndAbs()
  if not path then
    actionResult(command, false, noctalia.tr("result.invalid_daily_path", { error = pathErr or "invalid" }))
    return
  end

  assertSafeVaultTarget(root, path, rel, function(ok, safeErr)
    if not ok then
      actionResult(command, false, noctalia.tr("result.invalid_daily_path", { error = safeErr or "unsafe" }))
      return
    end

    ensureParentDir(path)

    local ts = noctalia.formatTime("%H:%M", nowSec())
    local line = "- " .. ts .. " " .. text
    line = line:gsub("[\r\n]+", " ")

    local existing = ""
    if noctalia.fileExists(path) then
      existing = noctalia.readFile(path) or ""
    else
      local title = tostring(noctalia.formatTime(dailyFormat(), nowSec()) or ""):gsub("[/\\]", "-")
      existing = "# " .. title .. "\n"
    end

    if existing ~= "" and not existing:match("\n$") then
      existing = existing .. "\n"
    end
    local newBody = existing .. line .. "\n"
    local wOk, err = noctalia.writeFile(path, newBody)
    if not wOk then
      finishAction(command, false, noctalia.tr("result.failed", { error = err or "write failed" }))
      return
    end

    snapshot.dailyExists = true
    snapshot.dailyPath = path
    snapshot.dailyRel = rel or ""
    finishAction(command, true, noctalia.tr("result.captured", { name = snapshot.dailyRel }))
  end)
end
local function gitCommit(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  if refuseIfGitBusy(command) then
    return
  end
  local msg = trim(command.message or command.text)
  if msg == "" then
    msg = trim(noctalia.getConfig("git_commit_message"))
  end
  if msg == "" then
    msg = "vault: capture from Noctalia"
  end

  actionBusy = true
  publishSnapshot()

  -- add all + commit only if there is something to commit
  runGit({ "git", "status", "--porcelain" }, function(st)
    if not st or st.exitCode ~= 0 then
      finishAction(command, false, noctalia.tr("result.failed", { error = "git status failed" }))
      return
    end
    if trim(st.stdout) == "" then
      actionBusy = false
      actionResult(command, true, noctalia.tr("result.git_nothing"))
      notifyOk(noctalia.tr("result.git_nothing"))
      publishSnapshot()
      refreshAll()
      return
    end
    local n = 0
    for _ in (st.stdout .. "\n"):gmatch("(.-)\n") do
      if _ ~= "" then n += 1 end
    end

    runGit({ "git", "add", "-A" }, function(addRes)
      if not addRes or addRes.exitCode ~= 0 then
        local err = trim(addRes and (addRes.stderr ~= "" and addRes.stderr or addRes.stdout) or "git add failed")
        finishAction(command, false, noctalia.tr("result.failed", { error = err }))
        return
      end
      runGit({ "git", "commit", "-m", msg }, function(cRes)
        if cRes and cRes.exitCode == 0 then
          finishAction(command, true, noctalia.tr("result.git_committed", { n = n }))
        else
          local err = trim(cRes and (cRes.stderr ~= "" and cRes.stderr or cRes.stdout) or "commit failed")
          finishAction(command, false, noctalia.tr("result.failed", { error = err }))
        end
      end, 60000)
    end, 60000)
  end, 15000)
end

-- Merge pull (no rebase): never leaves the vault detached mid-rebase.
-- Autostash keeps uncommitted capture edits safe across the pull.
local PULL_ARGS = { "git", "pull", "--no-rebase", "--autostash" }

local function gitPull(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  if refuseIfGitBusy(command) then
    return
  end
  actionBusy = true
  publishSnapshot()
  runGit(PULL_ARGS, function(result)
    if result and result.exitCode == 0 then
      finishAction(command, true, noctalia.tr("result.git_pulled"))
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "pull failed")
      finishAction(command, false, noctalia.tr("result.failed", { error = err }))
    end
  end, 120000)
end

local function gitPush(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  if refuseIfGitBusy(command) then
    return
  end
  actionBusy = true
  publishSnapshot()
  runGit({ "git", "push" }, function(result)
    if result and result.exitCode == 0 then
      finishAction(command, true, noctalia.tr("result.git_pushed"))
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "push failed")
      finishAction(command, false, noctalia.tr("result.failed", { error = err }))
    end
  end, 120000)
end

local function gitSync(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  if refuseIfGitBusy(command) then
    return
  end
  actionBusy = true
  publishSnapshot()
  runGit(PULL_ARGS, function(pullRes)
    if not pullRes or pullRes.exitCode ~= 0 then
      local err = trim(pullRes and (pullRes.stderr ~= "" and pullRes.stderr or pullRes.stdout) or "pull failed")
      finishAction(command, false, noctalia.tr("result.failed", { error = err }))
      return
    end
    runGit({ "git", "push" }, function(pushRes)
      if pushRes and pushRes.exitCode == 0 then
        finishAction(command, true, noctalia.tr("result.git_synced"))
      else
        local err = trim(pushRes and (pushRes.stderr ~= "" and pushRes.stderr or pushRes.stdout) or "push failed")
        finishAction(command, false, noctalia.tr("result.failed", { error = err }))
      end
    end, 120000)
  end, 120000)
end

local function gitAbort(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local kind = gitInProgressKind()
  if kind == "" then
    actionResult(command, false, noctalia.tr("result.git_not_in_progress"))
    return
  end
  actionBusy = true
  publishSnapshot()
  local args
  if kind == "rebase" then
    args = { "git", "rebase", "--abort" }
  else
    args = { "git", "merge", "--abort" }
  end
  runGit(args, function(result)
    if result and result.exitCode == 0 then
      finishAction(command, true, noctalia.tr("result.git_aborted", { kind = kind }))
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "abort failed")
      finishAction(command, false, noctalia.tr("result.failed", { error = err }))
    end
  end, 30000)
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  local action = command.action

  if action == "refresh" then
    refreshAll()
    return
  end
  if action == "open_vault" then
    openVault()
    actionResult(command, true, noctalia.tr("result.opened"))
    return
  end
  if action == "open_daily" then
    ensureDailyFile(command, function(rel, _abs)
      openNoteRel(rel)
      actionResult(command, true, noctalia.tr("result.opened"))
      refreshAll()
    end)
    return
  end
  if action == "open_note" then
    local rel = trim(command.rel or command.path or command.id)
    if rel == "" then
      actionResult(command, false, noctalia.tr("result.failed", { error = "missing note" }))
      return
    end
    local root = vaultRoot()
    if not isVault(root) then
      actionResult(command, false, noctalia.tr("result.missing_vault"))
      return
    end
    local abs, clean, err = pathUnderVault(root, rel)
    if not abs then
      actionResult(command, false, noctalia.tr("result.invalid_note_path", { error = err or "invalid" }))
      return
    end
    -- URI open only (no filesystem write), still refuse symlink escape for consistency
    assertSafeVaultTarget(root, abs, clean, function(ok, safeErr)
      if not ok then
        actionResult(command, false, noctalia.tr("result.invalid_note_path", { error = safeErr or "unsafe" }))
        return
      end
      openNoteRel(clean)
      actionResult(command, true, noctalia.tr("result.opened"))
    end)
    return
  end
  if action == "capture" or action == "append_daily" then
    appendDaily(command)
    return
  end
  if action == "copy" then
    local text = trim(command.text or command.name)
    if text ~= "" then
      noctalia.copyToClipboard(text, "text/plain")
      actionResult(command, true, noctalia.tr("result.copied", { name = text }))
      notifyOk(noctalia.tr("result.copied", { name = text }))
    end
    return
  end
  if action == "git_commit" then
    gitCommit(command)
    return
  end
  if action == "git_pull" then
    gitPull(command)
    return
  end
  if action == "git_push" then
    gitPush(command)
    return
  end
  if action == "git_sync" then
    gitSync(command)
    return
  end
  if action == "git_abort" then
    gitAbort(command)
    return
  end
  if action == "git_status" then
    refreshAll()
    actionResult(command, true, noctalia.tr("result.success"))
    return
  end

  actionResult(command, false, "Unknown action: " .. action)
end

noctalia.state.watch(COMMAND_KEY, executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  refreshAll()
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())
  refreshPending = false
  refreshAll()
end

function onIpc(event, payload)
  if event == "refresh" then
    refreshPending = false
    refreshAll()
  elseif event == "daily" then
    executeAction({ action = "open_daily", requestId = "ipc-daily" })
  elseif event == "capture" and type(payload) == "table" then
    executeAction({
      action = "capture",
      text = payload.text or payload.line or "",
      requestId = "ipc-capture",
    })
  elseif event == "pull" then
    executeAction({ action = "git_pull", requestId = "ipc-pull" })
  elseif event == "push" then
    executeAction({ action = "git_push", requestId = "ipc-push" })
  elseif event == "sync" then
    executeAction({ action = "git_sync", requestId = "ipc-sync" })
  end
end
