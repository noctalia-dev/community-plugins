--!nonstrict
-- Last successful deployment of each environment, for the Deploys tab.
--
-- Same result on both platforms that have deployments: per repository, its
-- environments with at least one successful deployment, each with the version
-- (tag or branch) and its time. Gitea has no deployments API, so no tab.
--   GitLab: one GraphQL call per project; GitLab answers "last successful
--           deployment" per environment itself, but only for one project per
--           query.
--   GitHub: two GraphQL calls per repository: the environment names, then the
--           recent deployments of each (one alias per environment), keeping the
--           newest that succeeded.

local M = {}

local GITLAB_QUERY = [[
query($path: ID!) {
  project(fullPath: $path) {
    environments(states: ["available"]) {
      nodes { name tier lastDeployment(status: SUCCESS) { ref tag createdAt } }
    }
  }
}]]

local GITHUB_ENVIRONMENTS = [[
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) { environments(first: 50) { nodes { name } } }
}]]

-- Promotion order of GitLab's environment tiers; unknown tiers go last.
local TIER_ORDER = { TESTING = 1, DEVELOPMENT = 2, STAGING = 3, PRODUCTION = 4, OTHER = 5 }

-- ── Settings ─────────────────────────────────────────────────

-- The repositories the tab follows: deploy_repos, else the repo setting,
-- else none (and the tab is not shown).
function M.repos()
  local list = {}
  local configured = noctalia.getConfig("deploy_repos")
  if type(configured) == "table" then
    for _, entry in ipairs(configured) do
      if type(entry) == "string" then
        local trimmed = noctalia.string.trim(entry)
        if trimmed ~= "" then table.insert(list, trimmed) end
      end
    end
  end
  if #list > 0 then return list end
  local repo = noctalia.string.trim(noctalia.getConfig("repo") or "")
  if repo ~= "" then return { repo } end
  return {}
end

-- The tab exists on GitLab and GitHub, when it is not turned off and there is
-- a repository to follow.
function M.enabled(platform)
  return (platform == "gitlab" or platform == "github")
    and noctalia.getConfig("show_deploys") ~= false
    and #M.repos() > 0
end

-- ── Helpers ──────────────────────────────────────────────────

-- "2026-11-13T11:16:00Z" (fraction optional) -> epoch seconds, read as UTC.
function M.isoToEpoch(iso)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local asLocal = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  local now = os.time()
  local utcOffset = now - os.time(os.date("!*t", now))
  return asLocal + utcOffset
end

-- glab may follow the JSON with a "glab: …" line on errors: read the first.
local function decodeFirstLine(output)
  local first = tostring(output or ""):match("^[^\n]*")
  return noctalia.json.decode(first or "")
end

local function firstLine(text)
  return noctalia.string.trim(tostring(text or ""):match("[^\r\n]+") or "")
end

-- ── GitLab ───────────────────────────────────────────────────

local function fetchGitlab(path, done)
  noctalia.runAsync({"glab", "api", "graphql", "-f", "path=" .. path, "-f", "query=" .. GITLAB_QUERY}, function(res)
    local decoded = decodeFirstLine(res.stdout)
    local project = type(decoded) == "table" and decoded.data and decoded.data.project
    if res.exitCode ~= 0 or type(project) ~= "table" then
      local message = (type(decoded) == "table" and decoded.errors and decoded.errors[1] and decoded.errors[1].message)
        or firstLine(res.stderr)
      if message == "" then message = path .. ": project not found" end
      return done(nil, message)
    end

    local envs = {}
    for _, env in ipairs(project.environments and project.environments.nodes or {}) do
      local last = env.lastDeployment
      if type(last) == "table" and last.ref then
        table.insert(envs, {
          name = env.name or "",
          version = last.ref,
          isTag = last.tag == true,
          at = M.isoToEpoch(last.createdAt),
          rank = TIER_ORDER[env.tier] or 9,
        })
      end
    end
    table.sort(envs, function(a, b)
      if a.rank ~= b.rank then return a.rank < b.rank end
      return a.name < b.name
    end)
    done(envs, nil)
  end)
end

-- ── GitHub ───────────────────────────────────────────────────

local function githubDeploymentsQuery(count)
  local vars, fields = { "$owner: String!", "$name: String!" }, {}
  for i = 1, count do
    table.insert(vars, "$env" .. i .. ": String!")
    table.insert(fields, "e" .. i .. ": deployments(environments: [$env" .. i .. "], first: 10, "
      .. "orderBy: {field: CREATED_AT, direction: DESC}) "
      .. "{ nodes { createdAt commitOid ref { name prefix } latestStatus { state } } }")
  end
  return "query(" .. table.concat(vars, ", ") .. ") { repository(owner: $owner, name: $name) { "
    .. table.concat(fields, " ") .. " } }"
end

local function githubError(res, decoded, fallback)
  local message = (type(decoded) == "table" and decoded.errors and decoded.errors[1] and decoded.errors[1].message)
    or firstLine(res.stderr)
  return message ~= "" and message or fallback
end

local function fetchGithub(fullName, done)
  local owner, name = fullName:match("^([^/]+)/([^/]+)$")
  if not owner then return done(nil, fullName .. ": expected owner/repo") end

  noctalia.runAsync({"gh", "api", "graphql", "-f", "owner=" .. owner, "-f", "name=" .. name,
    "-f", "query=" .. GITHUB_ENVIRONMENTS}, function(res)
    local decoded = noctalia.json.decode(res.stdout or "")
    local repository = type(decoded) == "table" and decoded.data and decoded.data.repository
    if res.exitCode ~= 0 or type(repository) ~= "table" then
      return done(nil, githubError(res, decoded, fullName .. ": repository not found"))
    end

    local names = {}
    for _, env in ipairs(repository.environments and repository.environments.nodes or {}) do
      if env.name then table.insert(names, env.name) end
    end
    if #names == 0 then return done({}, nil) end

    -- Environment names travel as variables, never inside the query text.
    local argv = {"gh", "api", "graphql", "-f", "owner=" .. owner, "-f", "name=" .. name}
    for i, envName in ipairs(names) do
      table.insert(argv, "-f")
      table.insert(argv, "env" .. i .. "=" .. envName)
    end
    table.insert(argv, "-f")
    table.insert(argv, "query=" .. githubDeploymentsQuery(#names))

    noctalia.runAsync(argv, function(res2)
      local decoded2 = noctalia.json.decode(res2.stdout or "")
      local repo2 = type(decoded2) == "table" and decoded2.data and decoded2.data.repository
      if res2.exitCode ~= 0 or type(repo2) ~= "table" then
        return done(nil, githubError(res2, decoded2, fullName .. ": deployments unavailable"))
      end

      local envs = {}
      for i, envName in ipairs(names) do
        local nodes = repo2["e" .. i] and repo2["e" .. i].nodes or {}
        for _, node in ipairs(nodes) do
          if node.latestStatus and node.latestStatus.state == "SUCCESS" then
            local ref = node.ref
            table.insert(envs, {
              name = envName,
              version = (ref and ref.name) or tostring(node.commitOid or ""):sub(1, 7),
              isTag = ref ~= nil and ref.prefix == "refs/tags/",
              at = M.isoToEpoch(node.createdAt),
            })
            break
          end
        end
      end
      done(envs, nil)
    end)
  end)
end

-- ── Entry point ──────────────────────────────────────────────

-- done(cards, errorLine): cards in the order of M.repos(), each
-- { repo, environments = { { name, version, isTag, at } } }. A repository
-- that failed is left out; the first failure's message is returned.
function M.fetch(platform, done)
  local repos = M.repos()
  local results, pending, firstError = {}, #repos, nil
  if pending == 0 then return done({}, nil) end

  local fetchOne = platform == "github" and fetchGithub or fetchGitlab
  for index, repoName in ipairs(repos) do
    fetchOne(repoName, function(envs, err)
      if envs then
        results[index] = { repo = repoName, environments = envs }
      elseif not firstError then
        firstError = err
      end
      pending -= 1
      if pending > 0 then return end
      local cards = {}
      for i = 1, #repos do
        if results[i] then table.insert(cards, results[i]) end
      end
      done(cards, firstError)
    end)
  end
end

return M
