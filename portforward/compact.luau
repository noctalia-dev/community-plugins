--!nonstrict
local view = require("./view.luau").start(true)
function onOpen() view.onOpen() end
function onClose() view.onClose() end
function update() view.update() end
