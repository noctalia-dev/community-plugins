-- Read-only GitHub CLI requests used by the dashboard service.
local GitHub = {}

GitHub.LIMIT = 20
GitHub.FOLLOW_LIMIT = 12
GitHub.EVENT_LIMIT = 30
GitHub.ACTION_REPO_LIMIT = 5
GitHub.RUN_LIMIT = 5

function GitHub.api(endpoint)
  return { "gh", "api", endpoint }
end

function GitHub.apiWithFields(endpoint, fields)
  local argv = GitHub.api(endpoint)
  for _, field in ipairs(fields) do
    table.insert(argv, "-f")
    table.insert(argv, field)
  end
  return argv
end

function GitHub.search(query)
  return GitHub.api("search/issues?q=" .. query .. "&sort=updated&order=desc&per_page=" .. tostring(GitHub.LIMIT))
end

function GitHub.commands()
  local gql = [[query { viewer { login name avatarUrl url bio company location followers { totalCount } following { totalCount } repositories(privacy: PUBLIC, first: 1) { totalCount } contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date contributionCount contributionLevel } } } } } }]]
  return {
    profile = GitHub.api("user"),
    contributions = { "gh", "api", "graphql", "-f", "query=" .. gql },
    notifications = GitHub.api("notifications?all=true&per_page=" .. tostring(GitHub.LIMIT)),
    following = GitHub.api("user/following?per_page=" .. tostring(GitHub.FOLLOW_LIMIT)),
    following_repos = GitHub.starredReleases(50),
    my_prs = GitHub.search("is:pr+author:@me"),
    review_prs = GitHub.search("is:pr+is:open+review-requested:@me"),
    authored_issues = GitHub.search("is:issue+author:@me"),
    issues = GitHub.search("is:issue+assignee:@me"),
    repositories = GitHub.api("user/repos?sort=updated&direction=desc&per_page=" .. tostring(GitHub.LIMIT)),
  }
end

function GitHub.events(login, limit)
  limit = math.clamp(tonumber(limit) or GitHub.EVENT_LIMIT, 1, GitHub.EVENT_LIMIT)
  return GitHub.api("users/" .. login .. "/events/public?per_page=" .. tostring(limit))
end

function GitHub.repoEvents(fullName)
  return GitHub.api("repos/" .. fullName .. "/events?per_page=" .. tostring(GitHub.EVENT_LIMIT))
end

function GitHub.actions(fullName)
  return GitHub.api("repos/" .. fullName .. "/actions/runs?per_page=" .. tostring(GitHub.RUN_LIMIT))
end

function GitHub.starredReleases(limit, after)
  limit = math.clamp(tonumber(limit) or 50, 1, 50)
  local query = [[query($count: Int!, $after: String) { viewer { starredRepositories(first: $count, after: $after, orderBy: {field: STARRED_AT, direction: DESC}) { nodes { nameWithOwner owner { login } releases(first: 1, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { name tagName url publishedAt isPrerelease } } } pageInfo { endCursor hasNextPage } } } }]]
  local argv = { "gh", "api", "graphql", "-f", "query=" .. query, "-F", "count=" .. tostring(limit) }
  if after and after ~= "" then
    argv[#argv + 1] = "-F"
    argv[#argv + 1] = "after=" .. after
  end
  return argv
end

return GitHub
