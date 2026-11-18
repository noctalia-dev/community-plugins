local on = noctalia.state.get("performance") == true
local core = require("./core.luau")

local function render()
  shortcut.setLabel(on and "Performance" or "Disabled")
  shortcut.setIcon(on and "rocket" or "rocket-off")
  shortcut.setActive(on)
end
render()

function onClick()
  on = not on
  noctalia.state.set("performance", on)
  render()
  core.toggle(on)
end

noctalia.state.watch("performance", function(val)
  if val ~= nil and val ~= on then
    on = val == true
    render()
  end
end)


