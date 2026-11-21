--!nonstrict
-- Noctalia panel: the shared shell in a single column (home with search, drill-down pages).
local shell = require("./lib/shell.luau")

local function layout(_, parts)
  return ui.column({ gap = 10, flexGrow = 1, padding = 4 }, parts.page)
end

local _, handlers = shell.create(layout, {})

function onOpen() handlers.onOpen() end
function onClose() handlers.onClose() end
function onFrameTick() handlers.onFrameTick() end
function onConfigChanged() handlers.onConfigChanged() end
function onKey(chord, pressed) handlers.onKey(chord, pressed) end
function onDrop(payload, value) handlers.onDrop(payload, value) end
