--!nonstrict
-- Entry shim for the `compact` [[panel]] (480 logical): the shared picker
-- cannot see which entry the host instantiated (the plugin API exposes no
-- size or entry id), so the shim IS the size signal. Keep in step with the
-- manifest's width for this entry (tests/build_test.py checks the pair).
local picker = require("./picker.luau")

function onOpen(_context)
  picker.onOpen(480)
end

function onKey(chord, pressed)
  picker.onKey(chord, pressed)
end
