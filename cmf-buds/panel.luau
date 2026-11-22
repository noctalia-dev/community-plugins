--!nonstrict
-- Single control panel for the CMF Buds Pro 2. The sections are internal
-- tabs, so the panel position is kept when switching sections and there is
-- a single global position/layer option.

local C = require("./lib/common.luau")
local P = require("./lib/panel_ui.luau")

local PANEL = "faminec/cmf-buds:panel"

function onOpen(context)
  P.setup(C.last_tab(), PANEL, 965)
  P.onOpen(context)
end

function onClose()
  P.onClose()
end

function update()
  P.update()
end

function onConfigChanged()
  P.onConfigChanged()
end

function onIpc(event, payload)
  P.onIpc(event, payload)
end

function onFrameTick(deltaMs)
  P.onFrameTick(deltaMs)
end