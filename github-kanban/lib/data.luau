-- Normalise GitHub REST and GraphQL responses into stable panel data.
local Data = {}

local function list(value)
  return type(value) == "table" and value or {}
end

local function repoName(value)
  return type(value) == "table" and (value.full_name or value.nameWithOwner or "") or ""
end

function Data.profile(raw)
  if type(raw) ~= "table" then return nil end
  local login = raw.login or ""
  local name = raw.name
  if not name or name == "" then name = login end
  return {
    login = login,
    name = name,
    bio = raw.bio or "",
    avatarUrl = raw.avatar_url or "",
    avatarPath = nil,
    url = raw.html_url or (raw.login and "https://github.com/" .. raw.login) or "https://github.com",
    followers = tonumber(raw.followers) or 0,
    following = tonumber(raw.following) or 0,
    publicRepos = tonumber(raw.public_repos) or 0,
  }
end

function Data.contributions(raw)
  local viewer = raw and raw.data and raw.data.viewer
  local calendar = viewer and viewer.contributionsCollection and viewer.contributionsCollection.contributionCalendar
  if type(calendar) ~= "table" or type(calendar.weeks) ~= "table" then return nil end
  local symbols = { NONE = "·", FIRST_QUARTILE = "░", SECOND_QUARTILE = "▒", THIRD_QUARTILE = "▓", FOURTH_QUARTILE = "█" }
  local rows, details, days = { "", "", "", "", "", "", "" }, { "", "", "", "", "", "", "" }, {}
  for _, week in ipairs(calendar.weeks) do
    for row = 1, 7 do
      local day = week.contributionDays and week.contributionDays[row]
      if day then
        rows[row] ..= symbols[day.contributionLevel] or "·"
        details[row] ..= (details[row] == "" and "" or "\t") .. tostring(day.date or "") .. "|" .. tostring(day.contributionCount or 0)
        table.insert(days, { date = day.date or "", count = tonumber(day.contributionCount) or 0 })
      end
    end
  end
  local today = os.date("!%Y-%m-%d")
  local todayCount, currentStreak, bestStreak = 0, 0, 0
  local endAt
  for i, day in ipairs(days) do
    if day.date == today then todayCount, endAt = day.count, i end
    if day.count > 0 then currentStreak += 1; bestStreak = math.max(bestStreak, currentStreak) else currentStreak = 0 end
  end
  local streak = 0
  local i = endAt or #days
  if endAt and days[endAt].count == 0 then i -= 1 end
  while i > 0 and days[i].count > 0 do streak += 1; i -= 1 end
  return {
    login = viewer.login or "",
    total = tonumber(calendar.totalContributions) or 0,
    rows = rows,
    details = details,
    today = todayCount,
    todayDate = today,
    currentStreak = streak,
    bestStreak = bestStreak,
    fetchedAt = os.time(),
  }
end

function Data.repository(raw, source)
  return {
    name = raw.name or "",
    fullName = raw.full_name or "",
    description = raw.description or "",
    url = raw.html_url or "",
    updatedAt = raw.updated_at or "",
    language = raw.language or "",
    stars = tonumber(raw.stargazers_count) or 0,
    forks = tonumber(raw.forks_count) or 0,
    ownerLogin = raw.owner and raw.owner.login or "",
    ownerAvatarUrl = raw.owner and raw.owner.avatar_url or "",
    source = source,
  }
end

function Data.repositories(raw, source)
  local out = {}
  for _, item in ipairs(list(raw)) do table.insert(out, Data.repository(item, source)) end
  return out
end

Data.RELEASE_FEED_LIMIT = 20

local function collapseWhitespace(value, maxInput)
  -- Cap input before collapsing; callers truncate output to ~140-180 chars.
  value = tostring(value or ""):match("^%s*(.*)$") or ""
  if #value > maxInput then value = value:sub(1, maxInput) end
  return value:gsub("[%s\r\n]+", " "):match("^%s*(.-)%s*$") or ""
end

function Data.starredReleaseFeed(raw)
  local connection = raw and raw.data and raw.data.viewer and raw.data.viewer.starredRepositories
  local repositories, events = {}, {}
  for _, item in ipairs(connection and connection.nodes or {}) do
    local owner = item.owner or {}
    local release = item.releases and item.releases.nodes and item.releases.nodes[1]
    if type(release) == "table" and release.url then
      local description = collapseWhitespace(release.description, 2000)
      local releaseName = release.name or release.tagName or ""
      local summary = description ~= "" and (releaseName .. " — " .. description) or releaseName
      if #summary > 180 then summary = summary:sub(1, 177) .. "..." end
      repositories[#repositories + 1] = {
        name = tostring(item.nameWithOwner or ""):match("/([^/]+)$") or "",
        fullName = item.nameWithOwner or "",
        url = item.nameWithOwner and ("https://github.com/" .. item.nameWithOwner) or "",
        ownerLogin = owner.login or "",
        ownerAvatarUrl = owner.login and ("https://github.com/" .. owner.login .. ".png?size=64") or "",
        source = "repository",
      }
      events[#events + 1] = {
        id = (item.nameWithOwner or "") .. ":" .. (release.tagName or release.url),
        type = "ReleaseEvent",
        titleKey = "events.release",
        subtitle = summary,
        name = item.nameWithOwner or "",
        repo = item.nameWithOwner or "",
        repository = item.nameWithOwner or "",
        url = release.url,
        createdAt = release.publishedAt or "",
        prerelease = release.isPrerelease == true,
        source = "repository",
        sourceName = item.nameWithOwner or "",
      }
    end
  end
  table.sort(events, function(a, b) return a.createdAt > b.createdAt end)
  while #events > Data.RELEASE_FEED_LIMIT do table.remove(events) end
  local repositoriesByName, selectedRepositories = {}, {}
  for _, repository in ipairs(repositories) do repositoriesByName[repository.fullName] = repository end
  for _, event in ipairs(events) do selectedRepositories[#selectedRepositories + 1] = repositoriesByName[event.repository] end
  return { repositories = selectedRepositories, events = events }
end

function Data.issue(raw, source)
  local repo = repoName(raw.repository)
  if repo == "" then repo = tostring(raw.repository_url or ""):match("/repos/(.+)$") or "" end
  return {
    number = tonumber(raw.number) or 0,
    title = raw.title or "",
    url = raw.html_url or "",
    repository = repo,
    kind = raw.pull_request and "pull_request" or "issue",
    state = raw.state or "open",
    updatedAt = raw.updated_at or "",
    user = raw.user and raw.user.login or "",
    source = source,
  }
end

function Data.issues(raw, source)
  local out = {}
  for _, item in ipairs(raw and raw.items or {}) do table.insert(out, Data.issue(item, source)) end
  return out
end

function Data.notification(raw)
  local subject = raw.subject or {}
  local repo = raw.repository or {}
  local subjectUrl = tostring(subject.url or "")
  local number = subjectUrl:match("/issues/(%d+)$")
  local isPullRequest = subjectUrl:match("/pulls/(%d+)$") ~= nil
  if isPullRequest then number = subjectUrl:match("/pulls/(%d+)$") end
  local path = isPullRequest and "pull" or "issues"
  local url = number and ("https://github.com/" .. (repo.full_name or "") .. "/" .. path .. "/" .. number) or "https://github.com/notifications"
  return {
    id = tostring(raw.id or ""),
    title = subject.title or "",
    reason = raw.reason or "",
    type = subject.type or "",
    repository = repo.full_name or "",
    url = url,
    updatedAt = raw.updated_at or "",
    unread = raw.unread == true,
  }
end

function Data.notifications(raw)
  local out = {}
  for _, item in ipairs(list(raw)) do table.insert(out, Data.notification(item)) end
  return out
end

local function eventUrl(raw, repo)
  local payload = raw.payload or {}
  local comment = payload.comment or {}
  local pullRequest = payload.pull_request or {}
  local issue = payload.issue or {}
  local release = payload.release or {}
  local fork = payload.forkee or {}
  local member = payload.member or {}
  local page = type(payload.pages) == "table" and payload.pages[1] or {}

  -- Prefer the most precise canonical page exposed by the event payload.
  if comment.html_url then return comment.html_url end
  if pullRequest.html_url then return pullRequest.html_url end
  if issue.html_url then return issue.html_url end
  if release.html_url then return release.html_url end
  if page.html_url then return page.html_url end
  if fork.html_url then return fork.html_url end

  if raw.type == "PushEvent" and repo ~= "" and payload.head then
    local before = tostring(payload.before or "")
    local head = tostring(payload.head)
    if before ~= "" and not before:match("^0+$") then
      return "https://github.com/" .. repo .. "/compare/" .. before .. "..." .. head
    end
    return "https://github.com/" .. repo .. "/commit/" .. head
  end

  local ref = tostring(payload.ref or "")
  if raw.type == "CreateEvent" and repo ~= "" and payload.ref_type == "branch" and ref:match("^[%w%._%-%/]+$") then
    return "https://github.com/" .. repo .. "/tree/" .. ref
  end

  if member.html_url then return member.html_url end
  return repo ~= "" and ("https://github.com/" .. repo) or "https://github.com"
end

local eventTypeKeys = {
  CommitCommentEvent = "events.commit_comment",
  CreateEvent = "events.created",
  DeleteEvent = "events.deleted",
  ForkEvent = "events.forked",
  GollumEvent = "events.wiki_updated",
  IssueCommentEvent = "events.issue_comment",
  IssuesEvent = "events.issue_updated",
  MemberEvent = "events.collaborators_updated",
  PublicEvent = "events.made_public",
  PullRequestEvent = "events.pull_request_updated",
  PullRequestReviewEvent = "events.pull_request_reviewed",
  PullRequestReviewCommentEvent = "events.review_comment",
  PushEvent = "events.pushed",
  ReleaseEvent = "events.release_published",
  WatchEvent = "events.starred",
}

local function eventTypeKey(raw)
  local payload = raw.payload or {}
  if raw.type == "CreateEvent" then
    return payload.ref_type == "branch" and "events.branch_created"
      or payload.ref_type == "tag" and "events.tag_created" or "events.repository_created"
  end
  if raw.type == "DeleteEvent" then
    return payload.ref_type == "branch" and "events.branch_deleted"
      or payload.ref_type == "tag" and "events.tag_deleted" or "events.deleted"
  end
  return eventTypeKeys[raw.type] or "events.activity"
end

local function eventSummary(raw)
  local payload = raw.payload or {}
  local comment = payload.comment or {}
  local pullRequest = payload.pull_request or {}
  local issue = payload.issue or {}
  local release = payload.release or {}
  local fork = payload.forkee or {}
  local member = payload.member or {}
  local page = type(payload.pages) == "table" and payload.pages[1] or {}
  local commit = type(payload.commits) == "table" and payload.commits[1] or {}

  local ref = tostring(payload.ref or ""):gsub("^refs/heads/", ""):gsub("^refs/tags/", "")
  local summary, summaryKey, summaryArgs
  if raw.type == "WatchEvent" then
    summaryKey = "events.summary.starred_repository"
  elseif raw.type == "PushEvent" and not commit.message then
    summaryKey = ref ~= "" and "events.summary.updated_branch" or "events.summary.pushed_commits"
    summaryArgs = { ref = ref }
  elseif raw.type == "CreateEvent" or raw.type == "DeleteEvent" then
    if ref ~= "" then
      local kind = payload.ref_type == "branch" and "branch" or (payload.ref_type == "tag" and "tag" or "reference")
      summaryKey = "events.summary." .. (raw.type == "CreateEvent" and "created_" or "deleted_") .. kind
      summaryArgs = { ref = ref }
    else
      summaryKey = raw.type == "CreateEvent" and "events.summary.created_repository" or "events.summary.deleted_repository"
    end
  end
  summary = summary or comment.body or pullRequest.title or issue.title or release.name or release.tag_name
    or page.title or commit.message or fork.full_name or member.login or payload.ref or payload.action or ""
  summary = collapseWhitespace(summary, 2000)
  if #summary > 140 then summary = summary:sub(1, 137) .. "..." end
  return summary, summaryKey, summaryArgs
end

function Data.event(raw, source, sourceName)
  local repo = raw.repo or {}
  local actor = raw.actor or {}
  local payload = raw.payload or {}
  local summary, summaryKey, summaryArgs = eventSummary(raw)
  return {
    id = tostring(raw.id or ""),
    type = raw.type or "",
    action = payload.action or "",
    titleKey = eventTypeKey(raw),
    name = repo.name or "",
    repo = repo.name or "",
    subtitle = summary,
    subtitleKey = summaryKey,
    subtitleArgs = summaryArgs,
    actor = actor.login or "",
    actorType = actor.type or "",
    actorAvatarUrl = actor.avatar_url or "",
    repository = repo.name or "",
    url = eventUrl(raw, repo.name or ""),
    createdAt = raw.created_at or "",
    source = source,
    sourceName = sourceName or "",
  }
end

function Data.events(raw, source, sourceName)
  local out = {}
  for _, item in ipairs(list(raw)) do table.insert(out, Data.event(item, source, sourceName)) end
  return out
end

function Data.runs(raw, repository)
  local out = {}
  for _, item in ipairs(raw and raw.workflow_runs or {}) do
    table.insert(out, {
      id = tostring(item.id or ""),
      name = item.name or item.display_title or "",
      status = item.status or "",
      conclusion = item.conclusion and item.conclusion ~= "" and item.conclusion or item.status or "",
      branch = item.head_branch or "",
      event = item.event or "",
      url = item.html_url or ("https://github.com/" .. repository .. "/actions"),
      repository = repository,
      createdAt = item.created_at or "",
      updatedAt = item.updated_at or "",
      source = "repository",
    })
  end
  return out
end

return Data
