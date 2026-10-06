--!nonstrict
local M = {}

-- Native panel sizes are manifest-owned. Choose once at opening; never resize
-- for polling, collapse, copy feedback or an error arriving during interaction.
function M.panelId(snapshot)
  local profiles = snapshot.profiles or {}
  local small = not snapshot.error and (#profiles == 0 or (#profiles == 1
    and #profiles[1].mappings <= 2 and profiles[1].state ~= "error"
    and profiles[1].state ~= "reconnecting" and (profiles[1].error or "") == ""))
  return "ghillb/portforward:" .. (small and "compact" or "panel")
end

return M
