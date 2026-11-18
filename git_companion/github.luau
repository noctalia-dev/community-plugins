--!nonstrict
-- GitHub pull requests through one GraphQL search per list.
--
-- `gh search prs` returns no merge state at all, while the GraphQL search
-- returns everything the panel needs in the same single call, across every
-- repository: draft, base branch, conflicts, review decision and the checks
-- of the head commit.

local M = {}

local QUERY = [[
query($q: String!) {
  search(query: $q, type: ISSUE, first: 15) {
    nodes {
      ... on PullRequest {
        number title url isDraft baseRefName mergeable mergeStateStatus reviewDecision
        repository { nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}]]

-- kind is "pr" (authored by you) or "review" (your review is requested).
-- scope: { repo = "owner/name" } or { group = "owner" }; `user:` matches an
-- organization as well as a user.
function M.command(kind, scope)
  local q = "is:pr is:open archived:false "
    .. (kind == "review" and "review-requested:@me" or "author:@me")
  if scope.group ~= "" then
    q = q .. " user:" .. scope.group
  elseif scope.repo ~= "" then
    q = q .. " repo:" .. scope.repo
  end
  return {"gh", "api", "graphql", "-f", "q=" .. q, "-f", "query=" .. QUERY}
end

-- The nodes of the search, or nil when the output is not a search answer.
function M.nodes(decoded)
  local search = type(decoded) == "table" and decoded.data and decoded.data.search
  if type(search) ~= "table" or type(search.nodes) ~= "table" then return nil end
  return search.nodes
end

local function checksState(node)
  local commits = node.commits and node.commits.nodes
  local last = type(commits) == "table" and commits[1]
  local rollup = last and last.commit and last.commit.statusCheckRollup
  return type(rollup) == "table" and rollup.state or nil
end

-- GitHub's fields mapped onto the shared status keys (status.luau), first
-- match wins: what blocks the author outranks what only waits on others.
local function mergeStatus(node)
  local checks = checksState(node)
  local merge = node.mergeStateStatus
  if node.isDraft then return "draft_status" end
  if node.mergeable == "CONFLICTING" or merge == "DIRTY" then return "conflict" end
  if checks == "FAILURE" or checks == "ERROR" then return "ci_must_pass" end
  if node.reviewDecision == "CHANGES_REQUESTED" then return "requested_changes" end
  if merge == "BEHIND" then return "need_rebase" end
  if checks == "PENDING" or checks == "EXPECTED" then return "ci_still_running" end
  if node.reviewDecision == "REVIEW_REQUIRED" then return "not_approved" end
  if merge == "BLOCKED" then return "merge_request_blocked" end
  if merge == "CLEAN" or merge == "HAS_HOOKS" or merge == "UNSTABLE" then return "mergeable" end
  -- UNKNOWN: GitHub computes mergeability lazily; the next refresh will know.
  return ""
end

function M.normalize(node)
  local repoName = (node.repository and node.repository.nameWithOwner) or ""
  return {
    title = node.title or "",
    url = node.url or "",
    ref = repoName .. "#" .. tostring(node.number or ""),
    targetBranch = node.baseRefName or "",
    mergeStatus = mergeStatus(node),
  }
end

return M
