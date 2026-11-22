--!nonstrict
-- When Noctalia disables or uninstalls the plugin (onExit reason "disable"/"uninstall", API 17), title bars stop
-- following Noctalia: helper `titlebar-cleanup` removes the user template entry, the template, the rendered
-- colors, titlebar_apply.py and its backups, so palette changes no longer touch any Umbriel config. The configs
-- keep their last colors. Both the panel and the bar widget call it (whichever Noctalia has loaded); it is
-- idempotent. Nothing waits for the answer: the plugin is going away. On uninstall this is best effort: the
-- helper runs from the plugin folder, which Noctalia may remove before python3 has loaded it (the README says
-- to disable first and lists the files to remove by hand).
local helper = require("./helper.luau")

local M = {}

function M.onExit(reason)
  if reason == "disable" or reason == "uninstall" then
    helper.call("titlebar-cleanup", {}, function() end, { always = true })
  end
end

return M
