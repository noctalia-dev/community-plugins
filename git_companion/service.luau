-- Git Companion Service
-- Headless entry: fetches data from gh/glab and stores it in noctalia.state.

local platform = noctalia.getConfig("platform") or "github"
local repo = noctalia.getConfig("repo") or ""
local group = noctalia.getConfig("group") or ""
local refreshInterval = noctalia.getConfig("refresh_interval") or 60

local bin = platform == "gitlab" and "glab" or "gh"

local function tr(key, args) return noctalia.tr("service." .. key, args) end

-- Set the refresh interval
noctalia.setUpdateInterval(refreshInterval * 1000)

-- Determine scope flags
local function scopeArgs()
  if platform == "gitlab" then
    if group ~= "" then return {"--group", group} end
    if repo ~= "" then return {"--repo", repo} end
  else
    if group ~= "" then return {"--owner", group} end
    if repo ~= "" then return {"--repo", repo} end
  end
  return {}
end

local function buildCommand(kind)
  local parts = {}
  if platform == "gitlab" then
    local sub = kind == "pr" and "mr" or "issue"
    table.insert(parts, bin)
    table.insert(parts, sub)
    table.insert(parts, "list")
    for _, v in ipairs(scopeArgs()) do table.insert(parts, v) end
    table.insert(parts, "--assignee=@me")
    table.insert(parts, "--output")
    table.insert(parts, "json")
  else
    -- GitHub
    local sub = kind == "pr" and "prs" or "issues"
    local filter = kind == "pr" and "--author=@me" or "--assignee=@me"
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
    local prefix = kind == "pr" and "!" or "#"
    return {
      title = raw.title or "",
      url = raw.web_url or "",
      ref = (raw.references and raw.references.full) or (prefix .. (raw.iid or ""))
    }
  end
  -- GitHub
  local repoName = (raw.repository and (raw.repository.nameWithOwner or raw.repository.name)) or ""
  return {
    title = raw.title or "",
    url = raw.url or "",
    ref = repoName .. "#" .. (raw.number or "")
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

local function fetchList(kind)
  local cmd = buildCommand(kind)
  noctalia.log("[Git Companion] Running: " .. cmd)
  noctalia.runAsync(cmd, function(res)
    local list = processList(kind, res.stdout)
    noctalia.state.set(kind .. "s", list) -- "issues" or "prs"
    noctalia.state.set(kind .. "s_count", #list)
  end)
end

local function refresh()
  noctalia.log("[Git Companion] Refresh triggered.")
  if not noctalia.commandExists(bin) then
    noctalia.notifyError(tr("title"), tr("bin_missing", { bin = bin }))
    noctalia.log("[Git Companion] Error: " .. bin .. " not found.")
    return
  end

  if platform == "gitlab" and repo == "" and group == "" then
    noctalia.notifyError(tr("title"), tr("gitlab_scope_missing"))
    noctalia.log("[Git Companion] Error: GitLab scope missing.")
    return
  end

  noctalia.state.set("loading", true)
  fetchList("issue")
  fetchList("pr")
  noctalia.state.set("loading", false)
  noctalia.state.set("last_update", noctalia.formatTime("%H:%M:%S"))
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
