--!nonstrict
-- Standalone app entry (not listed in plugin.toml): the shared shell with a left sidebar.
-- The host defines the global APP = { isApp = true, appVersion, initialConfig, validateDefault, rebuildDefault }.
local shell = require("./lib/shell.luau")
local sidebar = require("./ui/sidebar.luau")

local options = APP or { isApp = true }
options.isApp = true

local function layout(ctx, parts)
  return ui.row({ gap = 12, flexGrow = 1, padding = 8 }, {
    sidebar.render(ctx),
    ui.column({ key = "page", gap = 10, flexGrow = 1 }, parts.page),
  })
end

local _, handlers = shell.create(layout, options)

function onOpen() handlers.onOpen() end
function onClose() handlers.onClose() end
function onFrameTick() handlers.onFrameTick() end
function onKey(chord, pressed) handlers.onKey(chord, pressed) end
function onDrop(payload, value) handlers.onDrop(payload, value) end
function onExternalChange(kind) handlers.onExternalChange(kind) end
function onRecover() handlers.onRecover() end
function onRelaunch(path) handlers.onRelaunch(path) end
