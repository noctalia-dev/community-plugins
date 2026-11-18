--!nonstrict
-- Entry point for the whole suite. Run: luau tests/run.luau
local h = require("./harness")

h.describe("harness self-check", function()
  h.eq(1 + 1, 2, "arithmetic works")
  h.ok(true, "ok accepts truthy")
  h.throws(function()
    error("boom")
  end, "throws catches errors")
end)

require("./jalali_spec")()

require("./fmt_spec")()

require("./hijri_spec")()

require("./holidays_spec")()

require("./calendar_spec")()

local code = h.report()
if code ~= 0 then
  error("test suite failed", 0)
end
