--!nonstrict
-- Grid shape of the picker: three icons across. The manifest sizes this entry
-- for that shape, so the shape is fixed here rather than read from `list_mode`
-- -- otherwise the box and its contents could disagree.

local picker = require("./panel_body.luau").new(false)

function onOpen(context) picker.onOpen(context) end

-- The host calls these by name from the button `onClick` strings, so they have
-- to be real globals: one per slot the picker can show.
function onPick0() picker.pick(0) end
function onPick1() picker.pick(1) end
function onPick2() picker.pick(2) end
