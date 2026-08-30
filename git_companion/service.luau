-- Git Companion Service
-- Headless entry: fetches data from gh/glab and stores it in noctalia.state.

local platform = noctalia.getConfig("platform") or "github"
local repo = noctalia.getConfig("repo") or ""
local group = noctalia.getConfig("group") or ""
local refreshInterval = noctalia.getConfig("refresh_interval") or 60

local bin = platform == "gitlab" and "glab" or "gh"
local PLATFORM_GROUP = {
  gitlab = "--group",
  github = "--owner",
}

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

local function buildCommand(kind)
  local parts = {}
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

local function fetchList(kind)
  local cmd = buildCommand(kind)
  noctalia.log("[Git Companion] Running: " .. cmd)
  noctalia.runAsync(cmd, function(res)
    if res.exitCode ~= 0 then
      noctalia.log("[Git Companion] " .. kind .. " fetch failed: " .. (res.stderr or ""))
      return
    end
    local list = processList(kind, res.stdout)
    noctalia.state.set(kind .. "s", list) -- "issues" or "prs"
    noctalia.state.set(kind .. "s_count", #list)
    noctalia.state.set("last_update", noctalia.formatTime("%H:%M:%S"))
  end)
end

local lastAvatarUrl = ""

local function fetchUser()
  noctalia.runAsync(bin .. " api user", function(res)
    if res.exitCode ~= 0 then
      noctalia.log("[Git Companion] User fetch failed: " .. (res.stderr or ""))
      return
    end
    local decoded = noctalia.json.decode(res.stdout or "")
    if type(decoded) ~= "table" then return end
    local username = decoded.username or decoded.login or ""
    local bio = decoded.bio or ""
    local avatarUrl = decoded.avatar_url or ""
    noctalia.state.set("username", username)
    noctalia.state.set("bio", bio)
    if avatarUrl ~= "" and avatarUrl ~= lastAvatarUrl then
      lastAvatarUrl = avatarUrl
      local dir = noctalia.pluginDataDir()
      if not dir then return end
      local dest = dir .. "/avatar"
      noctalia.download(avatarUrl, dest, function(ok)
        if ok then noctalia.state.set("avatar_path", dest) end
      end)
    end
  end)
end

local function refresh()
  noctalia.log("[Git Companion] Refresh triggered.")
  if not noctalia.commandExists(bin) then
    noctalia.state.set("status", "bin_missing")
    noctalia.notifyError(tr("title"), tr("bin_missing", { bin = bin }))
    noctalia.log("[Git Companion] Error: " .. bin .. " not found.")
    return
  end

  if platform == "gitlab" and repo == "" and group == "" then
    noctalia.state.set("status", "gitlab_scope_missing")
    noctalia.notifyError(tr("title"), tr("gitlab_scope_missing"))
    noctalia.log("[Git Companion] Error: GitLab scope missing.")
    return
  end

  -- All preconditions met: the panel can render the lists. Individual fetch
  -- failures are logged per-list (see fetchList) and leave the previous list
  -- in place, so they don't flip this back.
  noctalia.state.set("status", "ok")
  fetchUser()

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
