--!nonstrict
-- theme.luau
-- Shared color palette and visual tokens for the panel UI.
local M = {}

M.PCOLOR = {
	[1] = "#e5484d", -- p1 / very urgent
	[2] = "#f5a524", -- p2
	[3] = "#3b82f6", -- p3
	[4] = "#8b8d98", -- p4 / natural
}
M.MUTED = "#8b8d98"
M.DANGER = "#e5484d"

-- Row outline while the action pair is open, then the hovered action's tint.
M.ACTION_OPEN = "outline_variant/0.7"
M.ACTION_DO = "#16A34A"
M.ACTION_DISMISS = "#6B7280"

return M
