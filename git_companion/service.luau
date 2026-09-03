-- Git Companion Service
-- Headless entry: fetches data from gh/glab/tea and stores it in noctalia.state.

local platform = noctalia.getConfig("platform") or "github"
local repo = noctalia.getConfig("repo") or ""
local group = noctalia.getConfig("group") or ""
local giteaLogin = noctalia.getConfig("gitea_login") or ""
local refreshInterval = noctalia.getConfig("refresh_interval") or 60

local PLATFORM_BIN = {
  github = "gh",
  gitlab = "glab",
  gitea = "tea",
}
local PLATFORM_GROUP = {
  gitlab = "--group",
  github = "--owner",
  gitea = "--owner",
}

local bin = PLATFORM_BIN[platform] or PLATFORM_BIN.github

local function tr(key, args) return noctalia.tr("service." .. key, args) end

-- Set the refresh interval
noctalia.setUpdateInterval(refreshInterval * 1000)

local function shellQuote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- Determine scope flags
local function scopeArgs()
  if group ~= "" then return {PLATFORM_GROUP[platform], shellQuote(group)} end
  if repo ~= "" then return {"--repo", shellQuote(repo)} end
  return {}
end

-- ── Gitea context ────────────────────────────────────────────
-- tea resolves its context with `git rev-parse --show-toplevel` before it even
-- looks at --login/--repo, so every repo-scoped command fails when the cwd is
-- not a git repository - and a service runs from an arbitrary cwd. Any
-- repository satisfies it, so the plugin keeps an empty one of its own and runs
-- tea from there. Created once; the path is cached for the rest of the session.

local teaContext = nil
local teaUser = ""

local function ensureTeaContext(cb)
  if teaContext then return cb(teaContext) end

  local dataDir = noctalia.pluginDataDir()
  if not dataDir then return cb(nil) end

  local dir = dataDir .. "/tea-ctx"
  if noctalia.fileExists(dir .. "/.git") then
    teaContext = dir
    return cb(dir)
  end

  if not noctalia.mkdirAll(dir) then
    noctalia.log("[Git Companion] Could not create " .. dir)
    return cb(nil)
  end

  noctalia.runAsync("git -C " .. shellQuote(dir) .. " init --quiet", function(res)
    if res.exitCode ~= 0 then
      noctalia.log("[Git Companion] git init failed: " .. (res.stderr or ""))
      return cb(nil)
    end
    teaContext = dir
    cb(dir)
  end)
end

-- Run a tea invocation from the context repository.
local function teaCommand(parts)
  return "cd " .. shellQuote(teaContext) .. " && " .. table.concat(parts, " ")
end

local function buildCommand(kind)
  local parts = {}
  if platform == "gitea" then
    -- `tea pulls list` demands a repo scope, so pull requests go through
    -- `tea issues list --kind pulls`, which tea documents as the way to apply
    -- the search filters to PRs. Gitea's global search rejects --assignee, so
    -- both lists are filtered by author. tea has no review-requested filter at
    -- all, so "review" never reaches this branch (see fetchEnabledLists).
    table.insert(parts, bin)
    table.insert(parts, "issues")
    table.insert(parts, "list")
    if giteaLogin ~= "" then
      table.insert(parts, "--login")
      table.insert(parts, shellQuote(giteaLogin))
    end
    table.insert(parts, "--kind")
    table.insert(parts, kind == "issue" and "issues" or "pulls")
    table.insert(parts, "--state")
    table.insert(parts, "open")
    table.insert(parts, "--author")
    table.insert(parts, shellQuote(teaUser))
    table.insert(parts, "--fields")
    table.insert(parts, "index,title,url,state,owner,repo")
    table.insert(parts, "--output")
    table.insert(parts, "json")
    table.insert(parts, "--limit")
    table.insert(parts, "15")
    for _, v in ipairs(scopeArgs()) do table.insert(parts, v) end
    return teaCommand(parts)
  end
  if platform == "gitlab" then
    local sub = kind == "issue" and "issue" or "mr"
    -- glab lists only open merge requests by default, so "unmerged" is free.
    local filter = kind == "review" and "--reviewer=@me" or "--author=@me"
    table.insert(parts, bin)
    table.insert(parts, sub)
    table.insert(parts, "list")
    for _, v in ipairs(scopeArgs()) do table.insert(parts, v) end
    table.insert(parts, filter)
    table.insert(parts, "--output")
    table.insert(parts, "json")
  else
    -- GitHub
    local sub = kind == "issue" and "issues" or "prs"
    local filter = "--assignee=@me"
    if kind == "pr" then
      filter = "--author=@me"
    elseif kind == "review" then
      filter = "--review-requested=@me"
    end
    table.insert(parts, bin)
    table.insert(parts, "search")
    table.insert(parts, sub)
    table.insert(parts, filter)
    table.insert(parts, "--state=open")
    table.insert(parts, "--json")
    table.insert(parts, "number,title,url,repository")
    table.insert(parts, "--limit")
    table.insert(parts, "15")
    for _, v in ipairs(scopeArgs()) do table.insert(parts, v) end
  end
  return table.concat(parts, " ")
end

local function normalizeItem(raw, kind)
  if platform == "gitlab" then
    local prefix = kind == "issue" and "#" or "!"
    return {
      title = raw.title or "",
      url = raw.web_url or "",
      ref = (raw.references and raw.references.full) or (prefix .. (raw.iid or "")),
      detailed_merge_status = raw.detailed_merge_status or "",
      targetBranch = raw.target_branch or "",
    }
  end
  if platform == "gitea" then
    return {
      title = raw.title or "",
      url = raw.url or "",
      ref = (raw.owner or "") .. "/" .. (raw.repo or "") .. "#" .. (raw.index or ""),
      targetBranch = "",
    }
  end
  -- GitHub
  local repoName = (raw.repository and (raw.repository.nameWithOwner or raw.repository.name)) or ""
  return {
    title = raw.title or "",
    url = raw.url or "",
    ref = repoName .. "#" .. (raw.number or ""),
    targetBranch = "",
  }
end

local function processList(kind, output)
  if not output or output == "" then return {} end
  local decoded = noctalia.json.decode(output)
  if type(decoded) ~= "table" then return {} end

  local list = {}
  for _, raw in ipairs(decoded) do
    table.insert(list, normalizeItem(raw, kind))
  end
  return list
end

-- A hidden tab is never fetched, so its state is emptied instead of keeping a
-- stale count the bar would still display.
local function clearList(kind)
  noctalia.state.set(kind .. "s", {})
  noctalia.state.set(kind .. "s_count", 0)
end

-- Reduce a CLI's stderr to the one line worth putting in front of the user.
-- The interesting line is rarely the first: tea prefixes a "NOTE: no gitea
-- login detected..." before the actual "Error: not found". So an explicit
-- Error line wins, otherwise the last line that is not a note or a warning.
local function errorLine(text)
  local fallback = ""
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local trimmed = noctalia.string.trim(line)
    if trimmed ~= "" then
      local lower = trimmed:lower()
      if lower:match("^error") then
        fallback = trimmed
        break
      end
      if not (lower:match("^note[:%s]") or lower:match("^warn")) then
        fallback = trimmed
      end
    end
  end
  if #fallback > 120 then return fallback:sub(1, 117) .. "..." end
  return fallback
end

local function fetchList(kind)
  local cmd = buildCommand(kind)
  noctalia.log("[Git Companion] Running: " .. cmd)
  noctalia.runAsync(cmd, function(res)
    -- The failure is reported next to the list rather than over it: the panel
    -- keeps showing what it last fetched. Carrying the CLI's own first line
    -- through is what makes it actionable - a mistyped repo reads as
    -- "Error: not found" instead of a silently empty tab.
    if res.exitCode ~= 0 then
      local stderr = res.stderr or ""
      noctalia.log("[Git Companion] " .. kind .. " fetch failed: " .. stderr)
      noctalia.state.set("error_detail", errorLine(stderr))
      return
    end
    local list = processList(kind, res.stdout)
    noctalia.state.set(kind .. "s", list) -- "issues" or "prs"
    noctalia.state.set(kind .. "s_count", #list)
    noctalia.state.set("last_update", noctalia.formatTime("%H:%M:%S"))
  end)
end

local lastAvatarUrl = ""

local function setAvatar(avatarUrl)
  if avatarUrl == "" or avatarUrl == lastAvatarUrl then return end
  lastAvatarUrl = avatarUrl
  local dir = noctalia.pluginDataDir()
  if not dir then return end
  local dest = dir .. "/avatar"
  noctalia.download(avatarUrl, dest, function(ok)
    if ok then noctalia.state.set("avatar_path", dest) end
  end)
end

local function fetchUser()
  noctalia.runAsync(bin .. " api user", function(res)
    if res.exitCode ~= 0 then
      noctalia.log("[Git Companion] User fetch failed: " .. (res.stderr or ""))
      return
    end
    local decoded = noctalia.json.decode(res.stdout or "")
    if type(decoded) ~= "table" then return end
    noctalia.state.set("username", decoded.username or decoded.login or "")
    noctalia.state.set("bio", decoded.bio or "")
    setAvatar(decoded.avatar_url or "")
  end)
end

-- Pick the login tea should use: the configured one, else tea's own default,
-- else the only sensible fallback - the first one it knows about.
local function pickTeaLogin(logins)
  if giteaLogin ~= "" then
    for _, entry in ipairs(logins) do
      if entry.name == giteaLogin then return entry end
    end
    return nil
  end
  for _, entry in ipairs(logins) do
    if tostring(entry.default) == "true" then return entry end
  end
  return logins[1]
end

-- tea has no `api user` equivalent, but `tea login list` already holds the
-- instance URL and the account name, and Gitea serves avatars publicly at
-- <instance>/<user>.png - so no token ever leaves tea's own config.
local function fetchTeaLogin(cb)
  noctalia.runAsync(teaCommand({bin, "login", "list", "--output", "json"}), function(res)
    if res.exitCode ~= 0 then
      noctalia.log("[Git Companion] tea login list failed: " .. (res.stderr or ""))
      return cb(false)
    end
    local decoded = noctalia.json.decode(res.stdout or "")
    if type(decoded) ~= "table" then return cb(false) end

    local entry = pickTeaLogin(decoded)
    if not entry or not entry.user or entry.user == "" then return cb(false) end

    teaUser = entry.user
    noctalia.state.set("username", teaUser)
    noctalia.state.set("bio", "")
    if entry.url and entry.url ~= "" then
      setAvatar((entry.url:gsub("/+$", "")) .. "/" .. teaUser .. ".png")
    end
    cb(true)
  end)
end

-- tea exposes no review-requested filter, so Gitea cannot fill the Code Review
-- tab. The panel hides that tab on Gitea and the state is emptied to match.
local function supportsKind(kind)
  return not (platform == "gitea" and kind == "review")
end

local function fetchEnabledLists()
  -- All preconditions met: the panel can render the lists. Individual fetch
  -- failures are logged per-list (see fetchList) and leave the previous list
  -- in place, so they don't flip this back.
  noctalia.state.set("status", "ok")
  noctalia.state.set("error_detail", "")

  -- Settings are read here rather than at module scope so toggling a tab takes
  -- effect on the next tick. show_reviews is the master switch for the Code
  -- Review feature: off means no fetch, and count_reviews_with_prs is ignored.
  for _, entry in ipairs({
    { kind = "pr", setting = "show_prs" },
    { kind = "issue", setting = "show_issues" },
    { kind = "review", setting = "show_reviews" },
  }) do
    if supportsKind(entry.kind) and noctalia.getConfig(entry.setting) ~= false then
      fetchList(entry.kind)
    else
      clearList(entry.kind)
    end
  end
end

local function fail(status, args)
  noctalia.state.set("status", status)
  noctalia.notifyError(tr("title"), tr(status, args))
  noctalia.log("[Git Companion] Error: " .. status)
end

local function refresh()
  noctalia.log("[Git Companion] Refresh triggered.")
  if not noctalia.commandExists(bin) then
    return fail("bin_missing", { bin = bin })
  end

  -- Gitea needs two async steps first: a git context for tea to run in, and the
  -- account name that --author filters on. Gitea's global search works without
  -- a repo or owner scope, so it has no equivalent of the GitLab check below.
  if platform == "gitea" then
    ensureTeaContext(function(dir)
      if not dir then return fail("gitea_ctx_failed") end
      fetchTeaLogin(function(ok)
        if not ok then return fail("gitea_login_missing") end
        fetchEnabledLists()
      end)
    end)
    return
  end

  if platform == "gitlab" and repo == "" and group == "" then
    return fail("gitlab_scope_missing")
  end

  fetchUser()
  fetchEnabledLists()
end

-- Initial fetch
refresh()

function update()
  refresh()
end

function onIpc(event, payload)
  if event == "refresh" then
    refresh()
  end
end
