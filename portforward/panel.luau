--!nonstrict
local view = require("./view.luau").start(false)
function onOpen() view.onOpen() end
function onClose() view.onClose() end
function update() view.update() end
