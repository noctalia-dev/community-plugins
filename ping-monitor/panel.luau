--!nonstrict
-- Compact panel: the height follows the content (used while every card fits).
local view = require("./view.luau")
view.setTall(false)
view.watch()

function onOpen()
  view.onOpen()
end
