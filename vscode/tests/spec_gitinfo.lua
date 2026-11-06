local gitinfo = loadModule("gitinfo.luau")

-- ARGV
eq("argv", table.concat(gitinfo.argv("/home/user/my app"), "|"),
  "git|--no-optional-locks|-c|core.fsmonitor=false|-C|/home/user/my app|status|--porcelain=v2|--branch")

-- CLEAN
local clean = "# branch.oid abcdef0123456789abcdef0123456789abcdef01\n# branch.head main\n"
local r = gitinfo.parse(clean)
eq("clean branch", r.branch, "main")
eq("clean detached", r.detached, false)
eq("clean dirty", r.dirty, false)

-- DIRTY
local changed = clean .. "1 .M N... 100644 100644 100644 abc abc src/main.lua\n"
r = gitinfo.parse(changed)
eq("modified branch", r.branch, "main")
eq("modified dirty", r.dirty, true)

r = gitinfo.parse(clean .. "? notes.txt\n")
eq("untracked dirty", r.dirty, true)

r = gitinfo.parse(clean .. "2 R. N... 100644 100644 100644 a a R100 new old\n")
eq("renamed dirty", r.dirty, true)

r = gitinfo.parse(clean .. "u UU N... 100644 100644 100644 100644 a b c file\n")
eq("unmerged dirty", r.dirty, true)

r = gitinfo.parse(clean .. "! build/out.o\n")
eq("ignored not dirty", r.dirty, false)

-- DETACHED
r = gitinfo.parse("# branch.oid 0123456789abcdef\n# branch.head (detached)\n")
eq("detached branch", r.branch, "0123456")
eq("detached flag", r.detached, true)
eq("detached dirty", r.dirty, false)

-- INITIAL REPO
r = gitinfo.parse("# branch.oid (initial)\n# branch.head main\n")
eq("initial branch", r.branch, "main")
eq("initial detached", r.detached, false)

-- EMPTY
r = gitinfo.parse("")
eq("empty branch", r.branch, nil)
eq("empty dirty", r.dirty, false)
eq("empty detached", r.detached, false)

-- LINE ENDINGS
r = gitinfo.parse("# branch.oid abc\r\n# branch.head dev\r\n1 .M N... x\r\n")
eq("crlf branch", r.branch, "dev")
eq("crlf dirty", r.dirty, true)
r = gitinfo.parse("# branch.oid abc\r\n# branch.head dev\r\n")
eq("crlf clean", r.dirty, false)

-- NO TRAILING NEWLINE
r = gitinfo.parse("# branch.oid abc\n# branch.head dev")
eq("no trailing newline branch", r.branch, "dev")
eq("no trailing newline dirty", r.dirty, false)
r = gitinfo.parse("# branch.oid abc\n# branch.head dev\n? x")
eq("no trailing newline dirty change", r.dirty, true)

-- BLANK LINES
r = gitinfo.parse("\n# branch.oid abc\n\n# branch.head dev\n\n")
eq("blank lines dirty", r.dirty, false)
eq("blank lines branch", r.branch, "dev")
