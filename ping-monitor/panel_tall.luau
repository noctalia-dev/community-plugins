--!nonstrict
-- Tall panel: fixed height with a scrolling list (used when the cards do not fit the compact panel).
local view = require("./view.luau")
view.setTall(true)
view.watch()

function onOpen()
  view.onOpen()
end
