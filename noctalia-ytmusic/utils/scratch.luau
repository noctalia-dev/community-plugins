-- Shared scratch-file slots under /tmp/noctalia-ytmusic.
-- One mkdir at load, then a small rotating pool of reusable names: concurrent
-- requests get distinct slots, the next caller overwrites, nothing accumulates.

local Scratch = {}
Scratch.DIR = "/tmp/noctalia-ytmusic"

noctalia.mkdirAll(Scratch.DIR)

local counter = 0
local SLOTS = 8

function Scratch.path(prefix)
    counter = counter + 1
    return Scratch.DIR .. "/" .. prefix .. "-" .. ((counter % SLOTS) + 1)
end

return Scratch
