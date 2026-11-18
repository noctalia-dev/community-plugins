--!nonstrict
-- Every provider Headroom knows about, in display order.
-- Adding one: create providers/<id>/init.luau + logo.svg, then add a line here.
-- See CONTRIBUTING.md for the full checklist.

return {
  require("./claude/init.luau"),
  require("./codex/init.luau"),
  require("./antigravity/init.luau"),
}
