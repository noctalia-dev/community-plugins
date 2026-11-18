local closureDiff = require("../lib/closure_diff")
local t = require("./testlib")

t.test("closure clean removes ANSI formatting and surrounding whitespace", function()
    local output = closureDiff.clean("\n  \27[31mhello\27[0m  \n")
    t.expectEqual(output, "hello")
end)

t.test("closure parse detects an explicit increase", function()
    local output, lines = closureDiff.parse("Closure size: +12.5 MiB")

    t.expectEqual(output, "Closure size: +12.5 MiB")
    t.expectEqual(#lines, 1)
    t.expectEqual(lines[1].prefix, "Closure size: ")
    t.expectEqual(lines[1].amount, "+12.5 MiB")
    t.expectEqual(lines[1].change, "increase")
end)

t.test("closure parse detects an explicit decrease", function()
    local _, lines = closureDiff.parse("Closure size: -8 MiB")

    t.expectEqual(lines[1].amount, "-8 MiB")
    t.expectEqual(lines[1].change, "decrease")
end)

t.test("closure parse infers increases from bright red ANSI output", function()
    local _, lines = closureDiff.parse("Closure size: \27[91m12.5 MiB\27[0m")

    t.expectEqual(lines[1].amount, "+12.5 MiB")
    t.expectEqual(lines[1].change, "increase")
end)

t.test("closure parse infers decreases from green ANSI output", function()
    local _, lines = closureDiff.parse("Closure size: \27[32m8 MiB\27[0m")

    t.expectEqual(lines[1].amount, "-8 MiB")
    t.expectEqual(lines[1].change, "decrease")
end)

t.test("closure parse preserves plain lines and removes ANSI codes", function()
    local _, lines = closureDiff.parse("\27[1mfoo: 1.0 → 1.1\27[0m")

    t.expectEqual(#lines, 1)
    t.expectEqual(lines[1].text, "foo: 1.0 → 1.1")
    t.expectNil(lines[1].amount)
end)

t.test("closure parse handles CRLF and multiple lines", function()
    local _, lines = closureDiff.parse("foo: 1 → 2\r\nClosure size: +1 KiB\r\n")

    t.expectEqual(#lines, 2)
    t.expectEqual(lines[1].text, "foo: 1 → 2")
    t.expectEqual(lines[2].amount, "+1 KiB")
end)

t.test("closure parse handles empty output", function()
    local output, lines = closureDiff.parse("")

    t.expectEqual(output, "")
    t.expectEqual(#lines, 0)
end)

return true
