--!nonstrict
-- Entry point: tests/run.sh copies the sources and runs this.

local t = require("./support/t")

require("./lib_spec")
require("./ui_lib_spec")
require("./service_spec")

local failed = t.run()
if failed > 0 then
  error(`{failed} test(s) failed`, 0)
end
