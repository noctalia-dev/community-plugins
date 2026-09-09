local nix = require("../lib/nix")
local t = require("./testlib")

local function expectChange(change, expected)
    t.expectEqual(change.name, expected.name)
    t.expectEqual(change.kind, expected.kind)
    t.expectEqual(change.oldRev, expected.oldRev)
    t.expectEqual(change.newRev, expected.newRev)
    t.expectEqual(change.oldDate, expected.oldDate)
    t.expectEqual(change.newDate, expected.newDate)
end

t.test("nix update output parses updated input old and arrow-new details", function()
    local changes = nix.parseUpdateOutput([[
• Updated input 'nixpkgs':
    'github:NixOS/nixpkgs/0123456789abcdef?narHash=sha256-old' (2025-01-02)
  → 'git+https://example.com/nixpkgs.git?narHash=sha256-new&rev=fedcba9876543210' (2025-02-03)
]])

    t.expectEqual(#changes, 1)
    expectChange(changes[1], {
        name = "nixpkgs",
        kind = "updated",
        oldRev = "01234567",
        newRev = "fedcba98",
        oldDate = "2025-01-02",
        newDate = "2025-02-03",
    })
end)

t.test("nix update output parses added inputs", function()
    local changes = nix.parseUpdateOutput([[
• Added input "home-manager":
    "github:nix-community/home-manager/aabbccddeeff0011?narHash=sha256-value" (2025-03-04)
]])

    t.expectEqual(#changes, 1)
    expectChange(changes[1], {
        name = "home-manager",
        kind = "added",
        oldRev = "—",
        newRev = "aabbccdd",
        oldDate = "—",
        newDate = "2025-03-04",
    })
end)

t.test("nix update output parses removed input without colon or details", function()
    local changes = nix.parseUpdateOutput("• Removed input 'obsolete'\n")

    t.expectEqual(#changes, 1)
    expectChange(changes[1], {
        name = "obsolete",
        kind = "removed",
        oldRev = "?",
        newRev = "—",
        oldDate = "?",
        newDate = "—",
    })
end)

t.test("nix update output parses removed input details with curly quotes", function()
    local changes = nix.parseUpdateOutput([[
• Removed input ‘obsolete’:
    “gitlab:group/project/1122334455667788?narHash=sha256-value” (2024-12-31)
]])

    t.expectEqual(#changes, 1)
    expectChange(changes[1], {
        name = "obsolete",
        kind = "removed",
        oldRev = "11223344",
        newRev = "—",
        oldDate = "2024-12-31",
        newDate = "—",
    })
end)

t.test("nix update output preserves multiple mixed changes in output order", function()
    local changes = nix.parseUpdateOutput([[
• Added input 'alpha':
    'github:owner/alpha/aaaaaaaa11111111' (2025-01-01)
notice: unrelated output (should be ignored)
• Updated input “middle”:
    'github:owner/middle/bbbbbbbb22222222' (2025-01-02)
  → 'github:owner/middle/cccccccc33333333' (2025-01-03)
• Removed input "zeta":
    'github:owner/zeta/dddddddd44444444' (2025-01-04)
]])

    t.expectEqual(#changes, 3)
    t.expectEqual(changes[1].name, "alpha")
    t.expectEqual(changes[1].kind, "added")
    t.expectEqual(changes[1].newRev, "aaaaaaaa")
    t.expectEqual(changes[1].newDate, "2025-01-01")
    t.expectEqual(changes[2].name, "middle")
    t.expectEqual(changes[2].oldRev, "bbbbbbbb")
    t.expectEqual(changes[2].newRev, "cccccccc")
    t.expectEqual(changes[3].name, "zeta")
    t.expectEqual(changes[3].kind, "removed")
end)

t.test("nix update output reports no changes for empty and unrelated output", function()
    t.expectEqual(#nix.parseUpdateOutput(""), 0)
    t.expectEqual(#nix.parseUpdateOutput("Finished without changing the lock file\n"), 0)
end)

t.test("nix update output ignores warnings", function()
    local changes = nix.parseUpdateOutput([[
warning: Git tree '/etc/nixos' is dirty
warning: updating lock file did not produce a recognized change block
error: • Updated input 'not-a-header':
warning: 'github:owner/repo/aaaaaaaa' (2025-01-01)
]])

    t.expectEqual(#changes, 0)
end)

t.test("nix update output tolerates ANSI formatting and CRLF", function()
    local output = "\27[1;34m• Updated input 'nixpkgs':\27[0m\r\n"
        .. "    \27[31m'github:NixOS/nixpkgs/1234567890abcdef' (2025-04-05)\27[0m\r\n"
        .. "  \27[32m→ 'github:NixOS/nixpkgs/abcdef1234567890' (2025-05-06)\27[0m\r\n"
    local changes = nix.parseUpdateOutput(output)

    t.expectEqual(#changes, 1)
    t.expectEqual(changes[1].oldRev, "12345678")
    t.expectEqual(changes[1].newRev, "abcdef12")
    t.expectEqual(changes[1].oldDate, "2025-04-05")
    t.expectEqual(changes[1].newDate, "2025-05-06")
end)

t.test("nix update output uses placeholders for absent details", function()
    local changes = nix.parseUpdateOutput([[
• Updated input 'unknown':
    follows 'nixpkgs'
• Added input 'missing':
• Removed input 'also-missing':
]])

    t.expectEqual(#changes, 3)
    expectChange(changes[1], {
        name = "unknown",
        kind = "updated",
        oldRev = "?",
        newRev = "?",
        oldDate = "?",
        newDate = "?",
    })
    t.expectEqual(changes[2].oldRev, "—")
    t.expectEqual(changes[2].newRev, "?")
    t.expectEqual(changes[2].oldDate, "—")
    t.expectEqual(changes[2].newDate, "?")
    t.expectEqual(changes[3].oldRev, "?")
    t.expectEqual(changes[3].newRev, "—")
    t.expectEqual(changes[3].oldDate, "?")
    t.expectEqual(changes[3].newDate, "—")
end)

t.test("nix update output keeps dates when revision metadata is unrecognized", function()
    local changes = nix.parseUpdateOutput([[
• Added input 'custom':
    'indirect:nixpkgs' (unknown date)
]])

    t.expectEqual(#changes, 1)
    t.expectEqual(changes[1].newRev, "?")
    t.expectEqual(changes[1].newDate, "unknown date")
end)

return true
