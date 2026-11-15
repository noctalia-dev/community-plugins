-- Git Companion Service
-- Headless entry: fetches data from gh/glab/gt and stores it in noctalia.state.

local platform = noctalia.getConfig("platform") or "github"
local repo = noctalia.getConfig("repo") or ""
local group = noctalia.getConfig("group") or ""
local refreshInterval = noctalia.getConfig("refresh_interval") or 60

local PLATFORM_BIN = {
  github = "gh",
  gitlab = "glab",
  gitea = "gt",
}
local PLATFORM_GROUP = {
  gitlab = "--group",
  github = "--owner",
  gitea = "--owner",
}

local gitlab = require("./gitlab.luau")

local bin = PLATFORM_BIN[platform] or PLATFORM_BIN.github

local function tr(key, args) return noctalia.tr("service." .. key, args) end

-- Set the refresh interval
noctalia.setUpdateInterval(refreshInterval * 1000)

-- Determine scope flags
local function scopeArgs()
  if group ~= "" then return {PLATFORM_GROUP[platform], group} end
  if repo ~= "" then return {"--repo", repo} end
  return {}
end

-- gt's --review-requested only runs as an instance-wide search and refuses
-- --repo, so with a repo set the review list searches the repo's owner and
-- processList keeps that repo's pull requests only.
local function giteaScopeArgs(kind)
  if kind == "review" and group == "" and repo ~= "" then
    local owner = repo:match("^([^/]+)/")
    if owner then return {"--owner", owner} end
    return {}
  end
  return scopeArgs()
end

local function buildCommand(kind)
  local parts = {}
  if platform == "gitea" then
    -- gt works from any directory and picks the instance itself, like glab:
    -- the only one with an account, else its default_host.
    local filter = "--assigned"
    if kind == "pr" then
      filter = "--authored"
    elseif kind == "review" then
      filter = "--review-requested"
    end
    table.insert(parts, bin)
    table.insert(parts, "search")
    table.insert(parts, kind == "issue" and "issue" or "pr")
    table.insert(parts, filter)
    table.insert(parts, "--state")
    table.insert(parts, "open")
    table.insert(parts, "--json")
    table.insert(parts, "number,title,url,repository")
    table.insert(parts, "--limit")
    table.insert(parts, "15")
    for _, v in ipairs(giteaScopeArgs(kind)) do table.insert(parts, v) end
    return parts
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
  return parts
end

-- Every item carries `mergeStatus`. Only GitLab fills it so far, from the
-- detailed_merge_status that `glab mr list` already returns, so no extra call
-- is needed. gh and gt searches return no such field; until one is mapped the
-- other platforms report an empty string.
local function normalizeItem(raw, kind)
  if platform == "gitlab" then
    local prefix = kind == "issue" and "#" or "!"
    local isMr = kind ~= "issue"
    return {
      title = raw.title or "",
      url = raw.web_url or "",
      ref = (raw.references and raw.references.full) or (prefix .. (raw.iid or "")),
      targetBranch = raw.target_branch or "",
      mergeStatus = isMr and (raw.detailed_merge_status or "") or "",
    }
  end
  if platform == "gitea" then
    -- gt reports the repository as a plain "owner/repo" string.
    return {
      title = raw.title or "",
      url = raw.url or "",
      ref = tostring(raw.repository or "") .. "#" .. tostring(raw.number or ""),
      targetBranch = "",
      mergeStatus = "",
    }
  end
  -- GitHub
  local repoName = (raw.repository and (raw.repository.nameWithOwner or raw.repository.name)) or ""
  return {
    title = raw.title or "",
    url = raw.url or "",
    ref = repoName .. "#" .. (raw.number or ""),
    targetBranch = "",
    mergeStatus = "",
  }
end

local function processList(kind, output)
  if not output or output == "" then return {} end
  local decoded = noctalia.json.decode(output)
  if type(decoded) ~= "table" then return {} end

  -- The Gitea review search ran on the repo's owner (see giteaScopeArgs), so
  -- it may bring pull requests of that owner's other repositories.
  local onlyRepo = platform == "gitea" and kind == "review" and group == "" and repo ~= ""

  local list = {}
  for _, raw in ipairs(decoded) do
    if not onlyRepo or raw.repository == repo then
      table.insert(list, normalizeItem(raw, kind))
    end
  end
  return list
end

-- A hidden tab is never fetched, so its state is emptied instead of keeping a
-- stale count the bar would still display.
local function clearList(kind)
  -- Re-enabling the tab then starts from a fresh, silent baseline.
  if kind == "pr" then gitlab.resetMergeStatus() end
  noctalia.state.set(kind .. "s", {})
  noctalia.state.set(kind .. "s_count", 0)
end

-- Reduce a CLI's stderr to the one line worth putting in front of the user.
-- The interesting line is rarely the first: a CLI may print notes or warnings
-- before the actual "Error: not found". So an explicit Error line wins,
-- otherwise the last line that is not a note or a warning.
-- glab draws a box instead, whose header is the bare word "ERROR" and whose
-- message follows on the next line, wrapped. That header must not win, or the
-- panel just says "ERROR"; the line after it is the message, and the first of
-- those lines is the one that carries the point.
local function errorLine(text)
  local fallback = ""
  local boxed = false
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local trimmed = noctalia.string.trim(line)
    if trimmed ~= "" then
      local lower = trimmed:lower()
      if lower:match("^error[%s:]*$") then
        boxed = true
      elseif boxed or lower:match("^error") then
        fallback = trimmed
        break
      elseif not (lower:match("^note[:%s]") or lower:match("^warn")) then
        fallback = trimmed
      end
    end
  end
  if #fallback > 120 then return fallback:sub(1, 117) .. "..." end
  return fallback
end

local function fetchList(kind)
  local cmd = buildCommand(kind)
  noctalia.log("[Git Companion] Running: " .. table.concat(cmd, " "))
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
    if platform == "gitlab" and kind == "pr" then gitlab.notifyMergeStatusChanges(list) end
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

-- gh, glab and gt all answer `api user`; the account name is `username` on
-- GitLab and `login` elsewhere, the bio is `description` on Gitea. The
-- optional callback receives the exit code, which gt sets to 4 when it has no
-- account or its credential was rejected.
local function fetchUser(cb)
  noctalia.runAsync({bin, "api", "user"}, function(res)
    if res.exitCode ~= 0 then
      noctalia.log("[Git Companion] User fetch failed: " .. (res.stderr or ""))
      if cb then cb(false, res.exitCode) end
      return
    end
    local decoded = noctalia.json.decode(res.stdout or "")
    if type(decoded) == "table" then
      noctalia.state.set("username", decoded.username or decoded.login or "")
      noctalia.state.set("bio", decoded.bio or decoded.description or "")
      setAvatar(decoded.avatar_url or "")
    end
    if cb then cb(true, 0) end
  end)
end

-- The last precondition failure that was notified. refresh() runs every tick,
-- so a lasting failure would otherwise raise the same notification each time.
local lastFailStatus = nil

local function fetchEnabledLists()
  -- All preconditions met: the panel can render the lists. Individual fetch
  -- failures are logged per-list (see fetchList) and leave the previous list
  -- in place, so they don't flip this back.
  lastFailStatus = nil
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
    if noctalia.getConfig(entry.setting) ~= false then
      fetchList(entry.kind)
    else
      clearList(entry.kind)
    end
  end
end

local function fail(status, args)
  noctalia.state.set("status", status)
  if status ~= lastFailStatus then
    lastFailStatus = status
    noctalia.notifyError(tr("title"), tr(status, args))
  end
  noctalia.log("[Git Companion] Error: " .. status)
end

local function refresh()
  noctalia.log("[Git Companion] Refresh triggered.")
  if not noctalia.commandExists(bin) then
    return fail("bin_missing", { bin = bin })
  end

  -- On Gitea the user call doubles as the sign-in check: gt exits with 4 when
  -- it has no account on the instance it picked, and every search would fail
  -- the same way. Gitea's search works without a repo or owner scope, so it
  -- has no equivalent of the GitLab check below.
  if platform == "gitea" then
    fetchUser(function(_, exitCode)
      if exitCode == 4 then return fail("gitea_auth_missing") end
      fetchEnabledLists()
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
