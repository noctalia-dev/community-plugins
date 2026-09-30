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
  return { "gh", "api", "search/issues?q=" .. query .. "&sort=updated&order=desc&per_page=" .. tostring(GitHub.LIMIT), "--jq", GitHub.SEARCH_JQ }
end

function GitHub.commands()
  local gql = [[query { viewer { login name avatarUrl url bio company location followers { totalCount } following { totalCount } repositories(privacy: PUBLIC, first: 1) { totalCount } contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date contributionCount contributionLevel } } } } } }]]
  return {
    profile = GitHub.api("user"),
    contributions = { "gh", "api", "graphql", "-f", "query=" .. gql },
    notifications = { "gh", "api", "notifications?all=true&per_page=" .. tostring(GitHub.LIMIT), "--jq", GitHub.NOTIF_JQ },
    following = GitHub.api("user/following?per_page=" .. tostring(GitHub.FOLLOW_LIMIT)),
    following_repos = GitHub.starredReleases(50),
    my_prs = GitHub.search("is:pr+author:@me"),
    review_prs = GitHub.search("is:pr+is:open+review-requested:@me"),
    authored_issues = GitHub.search("is:issue+author:@me"),
    issues = GitHub.search("is:issue+assignee:@me"),
    repositories = { "gh", "api", "user/repos?sort=updated&direction=desc&per_page=" .. tostring(GitHub.LIMIT), "--jq", GitHub.REPO_JQ },
  }
end

-- Projections keep only fields Data.* consumes, preserving envelope shapes.
-- Small/query-controlled endpoints (profile, contributions, following, starred
-- GraphQL) need no projection.
GitHub.SEARCH_JQ = "{items: [.items[] | {number: .number, title: .title, html_url: .html_url, repository_url: .repository_url, pull_request: (if .pull_request == null then null else {html_url: .pull_request.html_url} end), state: .state, updated_at: .updated_at, user: {login: .user.login}}]}"
GitHub.NOTIF_JQ = "[.[] | {id: .id, reason: .reason, unread: .unread, updated_at: .updated_at, subject: {title: .subject.title, url: .subject.url, type: .subject.type}, repository: {full_name: .repository.full_name}}]"
GitHub.REPO_JQ = "[.[] | {name: .name, full_name: .full_name, description: .description, html_url: .html_url, updated_at: .updated_at, language: .language, stargazers_count: .stargazers_count, forks_count: .forks_count, owner: {login: .owner.login, avatar_url: .owner.avatar_url}}]"
GitHub.RUNS_JQ = "{workflow_runs: [.workflow_runs[] | {id: .id, name: .name, display_title: .display_title, status: .status, conclusion: .conclusion, head_branch: .head_branch, event: .event, html_url: .html_url, created_at: .created_at, updated_at: .updated_at}]}"
GitHub.EVENT_JQ = "[.[] | {id: .id, type: .type, repo: {name: .repo.name}, actor: {login: .actor.login, type: .actor.type, avatar_url: .actor.avatar_url}, payload: {action: .payload.action, ref: .payload.ref, ref_type: .payload.ref_type, before: .payload.before, head: .payload.head, comment: {body: .payload.comment.body, html_url: .payload.comment.html_url}, pull_request: {title: .payload.pull_request.title, html_url: .payload.pull_request.html_url}, issue: {title: .payload.issue.title, html_url: .payload.issue.html_url}, release: {name: .payload.release.name, tag_name: .payload.release.tag_name, html_url: .payload.release.html_url}, forkee: {full_name: .payload.forkee.full_name, html_url: .payload.forkee.html_url}, member: {login: .payload.member.login, html_url: .payload.member.html_url}, pages: [.payload.pages[0] | {title: .title, html_url: .html_url}], commits: [.payload.commits[0] | {message: .message}]}, created_at: .created_at}]"

function GitHub.events(login, limit)
  limit = math.clamp(tonumber(limit) or GitHub.EVENT_LIMIT, 1, GitHub.EVENT_LIMIT)
  return { "gh", "api", "users/" .. login .. "/events/public?per_page=" .. tostring(limit), "--jq", GitHub.EVENT_JQ }
end

function GitHub.repoEvents(fullName)
  return GitHub.api("repos/" .. fullName .. "/events?per_page=" .. tostring(GitHub.EVENT_LIMIT))
end

function GitHub.actions(fullName)
  return { "gh", "api", "repos/" .. fullName .. "/actions/runs?per_page=" .. tostring(GitHub.RUN_LIMIT), "--jq", GitHub.RUNS_JQ }
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
