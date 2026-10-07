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

return M
