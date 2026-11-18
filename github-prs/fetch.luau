--!nonstrict
-- Headless [[service]] entry — the only place that talks to GitHub.
--
-- On every tick (and on manual refresh) it runs one `gh api graphql` search
-- per configured rule, merges the results (deduped by PR url, sorted by
-- updatedAt desc), and publishes them to the plugin's shared state for the
-- bar widget and panel to render. See the state contract below.
--
-- State keys published:
--   prs                array of { number, title, url, repo, author, isDraft,
--                      reviewDecision, ci, updatedAt } — nulls normalized to ""
--   counts             { total, failing, pending, approved, changes_requested, drafts }
--   error_message      "" when healthy; full-failure error or partial warning
--   last_updated_text  preformatted "HH:MM" of the last successful merge
--   rules_count        number of configured rules (panel empty-state hint)
--   overflow_count     sum of matches beyond the per-rule 50 cap
--   fetch_status       "loading" | "ok" | "error" — always set LAST so watchers
--                      observe a consistent snapshot
-- State keys consumed:
--   refresh_requested  monotonic nonce bumped by the panel's refresh button

local GH_TIMEOUT_MS = 30000
local DEFAULT_INTERVAL_S = 180
local MIN_INTERVAL_S = 30
local RESULTS_PER_RULE = 50

-- Single line and free of single quotes, so argument quoting stays trivial.
local GRAPHQL_QUERY =
  "query($q: String!) { search(query: $q, type: ISSUE, first: 50) { issueCount nodes { ... on PullRequest { number title url isDraft reviewDecision updatedAt repository { nameWithOwner } author { login } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }"

-- Projects the response down to plain PR records and normalizes the nullable
-- fields (ghost author, no review decision, no CI checks) to "" so Luau never
-- sees nil holes. select(.url != null) drops nodes that failed the inline
-- fragment spread. .count keeps the raw issueCount for the overflow note.
local JQ_PROJECTION =
  '{count: .data.search.issueCount, items: [.data.search.nodes[] | select(.url != null) | {number, title, url, isDraft, updatedAt, repo: .repository.nameWithOwner, author: (.author.login // ""), reviewDecision: (.reviewDecision // ""), ci: (.commits.nodes[0].commit.statusCheckRollup.state // "")}]}'

local fetching = false
local fetchGeneration = 0
local lastRefreshNonce = noctalia.state.get("refresh_requested") or 0

local function quoteShellArgument(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function readRules()
  local raw = noctalia.getConfig("rules")
  local rules = {}
  if type(raw) == "table" then
    for _, rule in ipairs(raw) do
      if type(rule) == "string" then
        local trimmed = noctalia.string.trim(rule)
        if trimmed ~= "" then
          table.insert(rules, trimmed)
        end
      end
    end
  end
  return rules
end

local function readExcludedRepositories()
  local raw = noctalia.getConfig("excluded_repositories")
  local patterns = {}
  if type(raw) == "table" then
    for _, pattern in ipairs(raw) do
      if type(pattern) == "string" then
        local trimmed = noctalia.string.trim(pattern)
        if trimmed ~= "" then
          table.insert(patterns, trimmed:lower())
        end
      end
    end
  end
  return patterns
end

-- Small glob matcher: '*' consumes zero or more characters. Patterns without
-- an owner match the repository basename; patterns containing '/' match the
-- full owner/name, without relying on GitHub search's exact-only repo:
-- qualifier.
local function globMatches(value, pattern)
  local valueIndex = 1
  local patternIndex = 1
  local starIndex = nil
  local starValueIndex = nil

  while valueIndex <= #value do
    local patternChar = pattern:sub(patternIndex, patternIndex)
    if patternChar == "*" then
      starIndex = patternIndex
      starValueIndex = valueIndex
      patternIndex += 1
    elseif patternIndex <= #pattern and patternChar == value:sub(valueIndex, valueIndex) then
      valueIndex += 1
      patternIndex += 1
    elseif starIndex ~= nil then
      starValueIndex += 1
      valueIndex = starValueIndex
      patternIndex = starIndex + 1
    else
      return false
    end
  end

  while pattern:sub(patternIndex, patternIndex) == "*" do
    patternIndex += 1
  end
  return patternIndex > #pattern
end

local function repositoryExcluded(repo, patterns)
  local fullName = repo:lower()
  local basename = fullName:match("[^/]+$") or fullName
  for _, pattern in ipairs(patterns) do
    local candidate = pattern:find("/", 1, true) and fullName or basename
    if globMatches(candidate, pattern) then
      return true
    end
  end
  return false
end

local function filterExcluded(prs, patterns)
  local filtered = {}
  for _, pr in ipairs(prs) do
    if not repositoryExcluded(pr.repo, patterns) then
      table.insert(filtered, pr)
    end
  end
  return filtered
end

local function readIntervalMs()
  local interval = tonumber(noctalia.getConfig("refresh_interval")) or DEFAULT_INTERVAL_S
  return math.max(MIN_INTERVAL_S, interval) * 1000
end

local function buildSearchQuery(rule)
  local q = "is:pr is:open"
  if not rule:find("archived:", 1, true) then
    q ..= " archived:false"
  end
  return q .. " " .. rule
end

local function buildCommand(rule)
  return "gh api graphql -f query="
    .. quoteShellArgument(GRAPHQL_QUERY)
    .. " -f q="
    .. quoteShellArgument(buildSearchQuery(rule))
    .. " --jq "
    .. quoteShellArgument(JQ_PROJECTION)
end

local function computeCounts(prs)
  local counts = { total = #prs, failing = 0, pending = 0, approved = 0, changes_requested = 0, drafts = 0 }
  for _, pr in ipairs(prs) do
    if pr.ci == "FAILURE" or pr.ci == "ERROR" then
      counts.failing += 1
    elseif pr.ci == "PENDING" or pr.ci == "EXPECTED" then
      counts.pending += 1
    end
    if pr.reviewDecision == "APPROVED" then
      counts.approved += 1
    elseif pr.reviewDecision == "CHANGES_REQUESTED" then
      counts.changes_requested += 1
    end
    if pr.isDraft then
      counts.drafts += 1
    end
  end
  return counts
end

-- fetch_status last: watchers triggering on it see prs/counts already updated.
local function publish(prs, status, errorMessage, overflow, rulesCount, updateTimestamp)
  noctalia.state.set("prs", prs)
  noctalia.state.set("counts", computeCounts(prs))
  noctalia.state.set("overflow_count", overflow)
  noctalia.state.set("rules_count", rulesCount)
  if updateTimestamp then
    noctalia.state.set("last_updated_text", noctalia.formatTime("%H:%M"))
  end
  noctalia.state.set("error_message", errorMessage)
  noctalia.state.set("fetch_status", status)
end

local function classifyResult(result)
  if result.timedOut then
    return nil, noctalia.tr("error.timeout")
  end
  if result.exitCode ~= 0 then
    local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]+")
    return nil, message or `gh exited with code {result.exitCode}`
  end
  if result.stdoutTruncated then
    return nil, noctalia.tr("error.truncated")
  end
  local decoded = noctalia.json.decode(result.stdout)
  if type(decoded) ~= "table" or type(decoded.items) ~= "table" then
    return nil, noctalia.tr("error.parse")
  end
  return decoded, nil
end

local function mergeAndPublish(ruleResults, ruleErrors, rulesCount, excludedRepositories)
  local prs = {}
  local seen = {}
  local overflow = 0
  for _, decoded in ipairs(ruleResults) do
    for _, pr in ipairs(decoded.items) do
      if not seen[pr.url] and not repositoryExcluded(pr.repo, excludedRepositories) then
        seen[pr.url] = true
        table.insert(prs, pr)
      end
    end
    local count = tonumber(decoded.count) or 0
    overflow += math.max(0, count - RESULTS_PER_RULE)
  end
  -- ISO-8601 UTC timestamps sort lexicographically; newest first.
  table.sort(prs, function(a, b)
    return a.updatedAt > b.updatedAt
  end)

  if #ruleErrors >= rulesCount then
    -- Every rule failed: keep the previous (still filtered) list visible.
    local previous = filterExcluded(noctalia.state.get("prs"), excludedRepositories)
    publish(previous, "error", ruleErrors[1], noctalia.state.get("overflow_count"), rulesCount, false)
  elseif #ruleErrors > 0 then
    local warning = noctalia.tr("panel.partial_warning", {
      failed = #ruleErrors,
      total = rulesCount,
      message = ruleErrors[1],
    })
    publish(prs, "ok", warning, overflow, rulesCount, true)
  else
    publish(prs, "ok", "", overflow, rulesCount, true)
  end
end

local function startFetch()
  if fetching then
    return
  end

  local rules = readRules()
  local excludedRepositories = readExcludedRepositories()
  if #rules == 0 then
    publish({}, "ok", "", 0, 0, true)
    return
  end

  if not noctalia.commandExists("gh") then
    local previous = filterExcluded(noctalia.state.get("prs"), excludedRepositories)
    publish(previous, "error", noctalia.tr("error.gh_missing"), 0, #rules, false)
    return
  end

  fetching = true
  fetchGeneration += 1
  local thisGeneration = fetchGeneration

  -- Flip to loading but keep the stale list so the UI never flashes empty.
  noctalia.state.set("error_message", "")
  noctalia.state.set("fetch_status", "loading")

  local pending = #rules
  local ruleResults = {}
  local ruleErrors = {}

  local function ruleDone()
    pending -= 1
    if pending == 0 then
      fetching = false
      mergeAndPublish(ruleResults, ruleErrors, #rules, excludedRepositories)
    end
  end

  for _, rule in ipairs(rules) do
    local started = noctalia.runAsync(buildCommand(rule), function(result)
      if thisGeneration ~= fetchGeneration then
        return -- config changed mid-flight; a newer fetch owns the state
      end
      local decoded, err = classifyResult(result)
      if decoded then
        table.insert(ruleResults, decoded)
      else
        table.insert(ruleErrors, `{rule}: {err}`)
        noctalia.log(`github-prs: rule "{rule}" failed: {err}`)
      end
      ruleDone()
    end, GH_TIMEOUT_MS)

    if not started then
      table.insert(ruleErrors, `{rule}: could not start gh`)
      ruleDone()
    end
  end
end

local function restartFetch()
  -- Existing gh processes cannot be cancelled, so invalidate their callbacks
  -- before starting the replacement fetch.
  if fetching then
    fetching = false
    fetchGeneration += 1
  end
  startFetch()
end

noctalia.setUpdateInterval(readIntervalMs())

if noctalia.state.get("fetch_status") == nil then
  noctalia.state.set("last_updated_text", "")
  publish({}, "loading", "", 0, #readRules(), false)
end

noctalia.state.watch("refresh_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce ~= lastRefreshNonce then
    lastRefreshNonce = nonce
    restartFetch()
  end
end)

startFetch()

function update()
  startFetch()
end

-- Defining this keeps the service alive across settings edits (no VM restart);
-- everything config-derived must be re-read here.
function onConfigChanged()
  noctalia.setUpdateInterval(readIntervalMs())
  restartFetch()
end

function onIpc(event, _payload)
  if event == "refresh" then
    restartFetch()
  elseif event == "dump" then
    local summary = {
      status = noctalia.state.get("fetch_status"),
      count = #noctalia.state.get("prs"),
      error = noctalia.state.get("error_message"),
      updated = noctalia.state.get("last_updated_text"),
    }
    noctalia.log("github-prs: " .. (noctalia.json.encode(summary) or "?"))
  end
end
