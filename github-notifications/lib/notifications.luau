--!nonstrict

local Time = require("./time.luau")

local Notifications = {}

local REASON_MAP = {
  mention = "Mentioned",
  team_mention = "Team mention",
  review_requested = "Review requested",
  assign = "Assigned",
  assigned = "Assigned",
  author = "Author",
  comment = "Comment",
  ci_activity = "CI activity",
  security_alert = "Security alert",
  subscribed = "Subscribed",
  state_change = "State changed",
  approval_requested = "Approval requested",
  member_feature_requested = "Feature requested",
  invitation = "Invitation",
  manual = "Manual",
}

local TYPE_ICONS = {
  PullRequest = "git-pull-request",
  Issue = "circle-dot",
  Discussion = "messages",
  Release = "tag",
  Commit = "git-commit",
  CheckSuite = "checklist",
  WorkflowRun = "cpu",
  RepositoryInvitation = "mail",
  RepositoryVulnerabilityAlert = "shield-alert",
}

local TYPE_COLORS = {
  PullRequest = "primary",
  Issue = "secondary",
  Discussion = "secondary",
  Release = "primary",
  Commit = "on_surface_variant",
  CheckSuite = "on_surface_variant",
  WorkflowRun = "on_surface_variant",
  RepositoryInvitation = "primary",
  RepositoryVulnerabilityAlert = "error",
}

function Notifications.resolveVisuals(subjectType, reason, title)
  local lowerTitle = string.lower(title or "")
  local isFailure = string.find(lowerTitle, "fail") ~= nil or string.find(lowerTitle, "error") ~= nil

  if subjectType == "RepositoryVulnerabilityAlert" or reason == "security_alert" then
    return "shield-alert", "error", true
  end

  if reason == "ci_activity" or subjectType == "CheckSuite" or subjectType == "WorkflowRun" then
    if isFailure then
      return "circle-x", "error", true
    else
      local icon = (subjectType == "WorkflowRun") and "cpu" or "checklist"
      return icon, "on_surface_variant", false
    end
  end

  local icon = TYPE_ICONS[subjectType] or "bell"
  local color = TYPE_COLORS[subjectType] or "on_surface_variant"
  return icon, color, false
end

function Notifications.formatReason(reason)
  if type(reason) ~= "string" or reason == "" then
    return "Notification"
  end
  local mapped = REASON_MAP[reason]
  if mapped then
    return mapped
  end

  -- Fallback: capitalize words and replace underscores
  local words = {}
  for w in string.gmatch(reason, "[^_]+") do
    local first = string.upper(string.sub(w, 1, 1))
    local rest = string.lower(string.sub(w, 2))
    table.insert(words, first .. rest)
  end
  return table.concat(words, " ")
end

function Notifications.typeIcon(subjectType)
  if type(subjectType) ~= "string" then
    return "bell"
  end
  return TYPE_ICONS[subjectType] or "bell"
end

function Notifications.typeColor(subjectType)
  if type(subjectType) ~= "string" then
    return "on_surface"
  end
  return TYPE_COLORS[subjectType] or "on_surface"
end

function Notifications.resolveHtmlUrl(item)
  local subject = item.subject or {}
  local repo = item.repository or {}
  local subjectUrl = subject.url
  local subjectType = subject.type
  local repoHtmlUrl = repo.html_url

  if type(subjectUrl) == "string" and subjectUrl ~= "" then
    local owner, repoName, pullNum = string.match(subjectUrl, "^https://api%.github%.com/repos/([%w%-%_%.]+)/([%w%-%_%.]+)/pulls/(%d+)$")
    if owner and repoName and pullNum then
      return string.format("https://github.com/%s/%s/pull/%s", owner, repoName, pullNum)
    end
    local owner, repoName, issueNum = string.match(subjectUrl, "^https://api%.github%.com/repos/([%w%-%_%.]+)/([%w%-%_%.]+)/issues/(%d+)$")
    if owner and repoName and issueNum then
      return string.format("https://github.com/%s/%s/issues/%s", owner, repoName, issueNum)
    end
    local owner, repoName, discNum = string.match(subjectUrl, "^https://api%.github%.com/repos/([%w%-%_%.]+)/([%w%-%_%.]+)/discussions/(%d+)$")
    if owner and repoName and discNum then
      return string.format("https://github.com/%s/%s/discussions/%s", owner, repoName, discNum)
    end
    local owner, repoName, commitSha = string.match(subjectUrl, "^https://api%.github%.com/repos/([%w%-%_%.]+)/([%w%-%_%.]+)/commits/([0-9a-fA-F]+)$")
    if owner and repoName and commitSha then
      return string.format("https://github.com/%s/%s/commit/%s", owner, repoName, commitSha)
    end
    local owner, repoName, relId = string.match(subjectUrl, "^https://api%.github%.com/repos/([%w%-%_%.]+)/([%w%-%_%.]+)/releases/(%d+)$")
    if owner and repoName and relId then
      return string.format("https://github.com/%s/%s/releases", owner, repoName)
    end
  end

  if type(repoHtmlUrl) == "string" and repoHtmlUrl ~= "" then
    local owner, repoName = string.match(repoHtmlUrl, "^https://github%.com/([%w%-%_%.]+)/([%w%-%_%.]+)$")
    if owner and repoName then
      if subjectType == "CheckSuite" then
        return string.format("https://github.com/%s/%s/actions", owner, repoName)
      end
      return string.format("https://github.com/%s/%s", owner, repoName)
    end
  end

  return "https://github.com/notifications"
end

function Notifications.isValidGithubUrl(url)
  if type(url) ~= "string" or url == "" then
    return false
  end
  -- Strict scheme and host check: must start with https://github.com/
  -- Reject any credentials in authority (e.g. https://user@github.com) or alternative schemes
  if not string.match(url, "^https://github%.com/[%w%-%_%.%/%?%=%&%#]*$") then
    return false
  end
  -- Reject traversal / control patterns
  if string.find(url, " ", 1, true) or string.find(url, "\\", 1, true) or string.find(url, "\r", 1, true) or string.find(url, "\n", 1, true) then
    return false
  end
  return true
end

function Notifications.isValidThreadId(threadId)
  if type(threadId) == "number" then
    return threadId > 0 and threadId == math.floor(threadId)
  end
  if type(threadId) == "string" then
    return string.match(threadId, "^[0-9]+$") ~= nil
  end
  return false
end

function Notifications.normalizeItem(item)
  if type(item) ~= "table" then
    return nil
  end

  local idStr = tostring(item.id or "")
  if not Notifications.isValidThreadId(idStr) then
    return nil
  end

  local subject = item.subject or {}
  local repo = item.repository or {}

  local title = subject.title or "Untitled notification"
  local subjectType = subject.type or "Unknown"
  local reason = item.reason or "subscribed"

  local icon, iconColor, isFailure = Notifications.resolveVisuals(subjectType, reason, title)

  return {
    id = tostring(item.id or ""),
    unread = item.unread == true,
    reason = reason,
    reasonLabel = Notifications.formatReason(reason),
    updatedAt = item.updated_at or "",
    relativeTime = Time.formatRelative(item.updated_at),
    title = title,
    type = subjectType,
    icon = icon,
    iconColor = iconColor,
    isFailure = isFailure,
    repo = repo.full_name or (repo.name or "GitHub"),
    repoUrl = repo.html_url or "",
    url = Notifications.resolveHtmlUrl(item),
  }
end

function Notifications.normalizeList(rawList)
  if type(rawList) ~= "table" then
    return {}
  end
  local result = {}
  for _, item in ipairs(rawList) do
    local normalized = Notifications.normalizeItem(item)
    if normalized and normalized.id ~= "" then
      table.insert(result, normalized)
    end
  end
  return result
end

return Notifications
