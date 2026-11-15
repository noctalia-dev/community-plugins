--!nonstrict
-- Entry point: tests/run.sh generates _generated/sources.luau, then runs this.

local t = require("./support/t")

require("./lib_spec")
require("./providers_spec")
require("./service_spec")

local failed = t.run()
if failed > 0 then
  error(`{failed} test(s) failed`, 0)
end
