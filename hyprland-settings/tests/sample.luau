-- Prints the sample file, for: luau tests/sample.luau | luac -p -
local text = assert(require("../lib/writer").render(require("./sample_state"), require("../lib/catalog"),
  { futurista = require("../lib/presets/futurista") }))
print(text)
