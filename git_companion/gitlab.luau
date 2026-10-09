--!nonstrict
-- GitLab-only helpers.

local M = {}

-- GitLab detailed_merge_status -> trailing glyph. Every status the API
-- documents is listed, so an unmapped one means GitLab added it since.
-- Names are checked against the Tabler font Noctalia ships, which trails
-- upstream: it has no git-pull-request-conflict, pipeline or brand-jira.
-- https://docs.gitlab.com/api/merge_requests/#merge-status
local MERGE_STATUS_GLYPHS = {
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
  -- Held by something outside the MR.
  merge_request_blocked = "barrier-block",
  locked_paths = "lock",
  locked_lfs_files = "lock",
  merge_time = "clock-pause",
  title_regex = "regex",
  jira_association_missing = "link-off",
}

function M.mergeStatusGlyph(status)
  if not status or status == "" then return nil end
  return MERGE_STATUS_GLYPHS[status] or nil
end

-- ── Merge status notifications ───────────────────────────────
-- The status comes with every `glab mr list`, so watching it costs no extra
-- call. Only the statuses that ask something of you are notified, each behind
-- its own setting; every other status is just recorded. knownStatus maps each
-- of your open MRs to the status last seen; nil until the first list, which
-- only records the baseline.

local NOTIFY_SETTINGS = {
  mergeable = "notify_mr_mergeable",
  ci_must_pass = "notify_mr_pipeline_failed",
  conflict = "notify_mr_conflict",
  need_rebase = "notify_mr_conflict",
  requested_changes = "notify_mr_changes_requested",
}

local knownStatus = nil

-- Forget the baseline, so the next list is recorded silently.
function M.resetMergeStatus()
  knownStatus = nil
end

-- Notify the MRs that entered a watched status since the previous list.
function M.notifyMergeStatusChanges(list)
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
    -- A ref missing from the baseline is a new MR: it becomes the baseline.
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
