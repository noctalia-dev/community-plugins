--!nonstrict
-- Merge status of a pull/merge request, shared by every platform.
--
-- GitLab's detailed_merge_status values are the vocabulary: glab returns them
-- as is, and github.luau / gitea.luau map their own fields onto the same keys,
-- so glyphs, groups, labels and notifications are written once.
-- https://docs.gitlab.com/api/merge_requests/#merge-status

local M = {}

-- Status -> glyph. Names are checked against the Tabler font Noctalia ships,
-- which trails upstream: it has no git-pull-request-conflict, pipeline or
-- brand-jira.
local GLYPHS = {
  mergeable = "circle-check",
  discussions_not_resolved = "message-report",
  requested_changes = "eye-exclamation",
  not_approved = "user-exclamation",
  approvals_syncing = "user-cog",
  ci_must_pass = "circle-x",
  ci_still_running = "loader",
  status_checks_must_pass = "notes-off",
  security_policy_pipeline_check = "shield-exclamation",
  security_policy_violations = "shield-x",
  conflict = "arrows-split",
  need_rebase = "git-cherry-pick",
  commits_status = "git-branch-deleted",
  draft_status = "git-pull-request-draft",
  not_open = "git-pull-request-closed",
  -- Held by something outside the request.
  merge_request_blocked = "barrier-block",
  locked_paths = "lock",
  locked_lfs_files = "lock",
  merge_time = "clock-pause",
  title_regex = "regex",
  jira_association_missing = "link-off",
}

function M.glyph(status)
  if not status or status == "" then return nil end
  return GLYPHS[status]
end

-- ── Groups ───────────────────────────────────────────────────
-- What a status asks of the author: act now, merge, or wait for someone else.
-- Any status not listed here, including one GitLab adds later, waits.

local NEEDS_YOU = {
  ci_must_pass = true,
  conflict = true,
  need_rebase = true,
  requested_changes = true,
  discussions_not_resolved = true,
  title_regex = true,
  jira_association_missing = true,
  commits_status = true,
  security_policy_violations = true,
}

M.GROUP_ORDER = { "needs_you", "ready", "waiting" }
M.GROUP_COLOR = { needs_you = "error", ready = "primary", waiting = "on_surface_variant" }

-- nil for an empty status: the platform could not tell (GitHub computes
-- mergeability lazily) or the item is an issue.
function M.group(status)
  if not status or status == "" then return nil end
  if status == "mergeable" then return "ready" end
  if NEEDS_YOU[status] then return "needs_you" end
  return "waiting"
end

-- ── Notifications ────────────────────────────────────────────
-- The status comes with every list, so watching it costs no extra call. Only
-- the statuses that ask something of you are notified, each behind its own
-- setting; every other status is just recorded. knownStatus maps each of your
-- open requests to the status last seen; nil until the first list, which only
-- records the baseline.

local NOTIFY_SETTINGS = {
  mergeable = "notify_mr_mergeable",
  ci_must_pass = "notify_mr_pipeline_failed",
  conflict = "notify_mr_conflict",
  need_rebase = "notify_mr_conflict",
  requested_changes = "notify_mr_changes_requested",
}

local knownStatus = nil

-- Forget the baseline, so the next list is recorded silently.
function M.resetBaseline()
  knownStatus = nil
end

-- Notify the requests that entered a watched status since the previous list.
function M.notifyChanges(list)
  local previous = knownStatus
  knownStatus = {}
  for _, item in ipairs(list) do
    knownStatus[item.ref] = item.mergeStatus
  end
  if previous == nil then return end

  local changes = {}
  for _, item in ipairs(list) do
    local before = previous[item.ref]
    local setting = NOTIFY_SETTINGS[item.mergeStatus]
    -- A ref missing from the baseline is a new request: it becomes the baseline.
    if before ~= nil and item.mergeStatus ~= before and setting
      and noctalia.getConfig(setting) ~= false then
      table.insert(changes, item)
    end
  end

  if #changes >= 3 then
    noctalia.notify(noctalia.tr("service.mr_status_many", { count = #changes }))
    return
  end
  for _, item in ipairs(changes) do
    noctalia.notify(
      noctalia.tr("service.merge_status." .. item.mergeStatus, { ref = item.ref }),
      item.title
    )
  end
end

return M
