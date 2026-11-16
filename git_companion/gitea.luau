--!nonstrict
-- Gitea merge state for the pull requests `gt search pr` found.
--
-- The search returns no merge state, and gt has no cross-repository call that
-- does. `gt pr list` does, one repository at a time, so the state costs one
-- call per repository in the results, not one per pull request. CI status
-- would cost one call per pull request and is left out on purpose.

local M = {}

local FIELDS = "number,base,draft,mergeable,review_decision"

-- Gitea's fields mapped onto the shared status keys (status.luau), first match
-- wins, in the same order as github.luau.
local function mergeStatus(pr)
  if pr.draft == true then return "draft_status" end
  if pr.mergeable == false then return "conflict" end
  if pr.review_decision == "changes_requested" then return "requested_changes" end
  if pr.review_decision == "review_required" then return "not_approved" end
  if pr.mergeable == true then return "mergeable" end
  return ""
end

-- Fill targetBranch and mergeStatus on every item, then call done(list).
-- Items carry `repository` ("owner/name") and `number` from the search. A
-- repository whose call fails leaves its items without a status.
function M.enrich(bin, list, done)
  local repos, pending = {}, 0
  for _, item in ipairs(list) do
    if item.repository ~= "" and not repos[item.repository] then
      repos[item.repository] = true
      pending += 1
    end
  end
  if pending == 0 then return done(list) end

  local byRepo = {}
  local function finish()
    pending -= 1
    if pending > 0 then return end
    for _, item in ipairs(list) do
      local pr = byRepo[item.repository] and byRepo[item.repository][item.number]
      if pr then
        item.targetBranch = pr.base or ""
        item.mergeStatus = mergeStatus(pr)
      end
    end
    done(list)
  end

  for repoName in pairs(repos) do
    noctalia.runAsync({bin, "pr", "list", "-R", repoName, "--state", "open",
      "--limit", "100", "--json", FIELDS}, function(res)
      if res.exitCode ~= 0 then
        noctalia.log("[Git Companion] gt pr list " .. repoName .. " failed: " .. (res.stderr or ""))
      else
        local decoded = noctalia.json.decode(res.stdout or "")
        if type(decoded) == "table" then
          local index = {}
          for _, pr in ipairs(decoded) do
            if pr.number then index[tostring(pr.number)] = pr end
          end
          byRepo[repoName] = index
        end
      end
      finish()
    end)
  end
end

return M
