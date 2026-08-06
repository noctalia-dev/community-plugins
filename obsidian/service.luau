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

local function dailyRelPath()
  local folder = dailyFolder()
  local name = noctalia.formatTime(dailyFormat(), nowSec()) .. ".md"
  if folder == "" then
    return name
  end
  return joinPath(folder, name)
end

local function dailyAbsPath()
  return joinPath(vaultRoot(), dailyRelPath())
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
  -- file param is vault-relative path without leading slash
  rel = tostring(rel or ""):gsub("^/+", "")
  local uri = "obsidian://open?vault=" .. urlEncode(vault) .. "&file=" .. urlEncode(rel)
  openUri(uri)
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
      local name = rel:match("([^/]+)$") or rel
      table.insert(recent, {
        id = rel,
        rel = rel,
        name = name:gsub("%.md$", ""),
        mtime = math.floor(tonumber(ts) or 0),
      })
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
  snapshot.dailyRel = dailyRelPath()
  snapshot.dailyPath = dailyAbsPath()

  if not isVault(root) then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("result.missing_vault")
    snapshot.recent = {}
    snapshot.dailyExists = false
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
  snapshot.error = ""
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

    local okP, errP = pcall(function()
      snapshot.dailyExists = noctalia.fileExists(snapshot.dailyPath)
      if snapshot.dailyExists then
        snapshot.dailyPreview = readPreview(snapshot.dailyPath, 500)
      else
        snapshot.dailyPreview = ""
      end

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

  -- recent files
  local recentCmd = "find "
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

local function ensureParentDir(path)
  local parent = path:match("(.+)/[^/]+$")
  if parent and parent ~= "" and not noctalia.fileExists(parent) then
    noctalia.mkdirAll(parent)
  end
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

  local path = dailyAbsPath()
  ensureParentDir(path)

  local ts = noctalia.formatTime("%H:%M", nowSec())
  local line = "- " .. ts .. " " .. text
  -- normalize: single line (newlines → spaces)
  line = line:gsub("[\r\n]+", " ")

  local existing = ""
  if noctalia.fileExists(path) then
    existing = noctalia.readFile(path) or ""
  else
    -- new daily: simple header
    local title = noctalia.formatTime(dailyFormat(), nowSec())
    existing = "# " .. title .. "\n"
  end

  if existing ~= "" and not existing:match("\n$") then
    existing = existing .. "\n"
  end
  local newBody = existing .. line .. "\n"
  local ok, err = noctalia.writeFile(path, newBody)
  if not ok then
    finishAction(command, false, noctalia.tr("result.failed", { error = err or "write failed" }))
    return
  end

  snapshot.dailyExists = true
  snapshot.dailyPath = path
  snapshot.dailyRel = dailyRelPath()
  finishAction(command, true, noctalia.tr("result.captured", { name = snapshot.dailyRel }))
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
    -- ensure file exists so Obsidian has something to open
    local path = dailyAbsPath()
    if not noctalia.fileExists(path) then
      ensureParentDir(path)
      local title = noctalia.formatTime(dailyFormat(), nowSec())
      noctalia.writeFile(path, "# " .. title .. "\n")
    end
    openNoteRel(dailyRelPath())
    actionResult(command, true, noctalia.tr("result.opened"))
    refreshAll()
    return
  end
  if action == "open_note" then
    local rel = trim(command.rel or command.path or command.id)
    if rel == "" then
      actionResult(command, false, noctalia.tr("result.failed", { error = "missing note" }))
      return
    end
    openNoteRel(rel)
    actionResult(command, true, noctalia.tr("result.opened"))
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
