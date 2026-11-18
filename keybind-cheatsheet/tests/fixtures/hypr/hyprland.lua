-- 1. Applications
Hyprland.config.bind("SUPER, T", launch_terminal, { description = "Terminal" })

-- 2. Workspaces
for i = 1, 9 do
  Hyprland.config.bind("SUPER, " .. i, workspace, { description = "Workspace " .. i })
end

require("parts.media")
