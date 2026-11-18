local shell = loadModule("shell.luau")

for _, s in ipairs({ "a b", "it's", "$HOME", "`x`", "a\nb", '"q"' }) do
  local f = io.popen("printf %s " .. shell.quote(s))
  local out = f:read("*a")
  f:close()
  check("quote round trip " .. string.format("%q", s), out == s)
end

eq("terminalCommand", shell.terminalCommand("/home/user/it's"), "cd -- '/home/user/it'\\''s' && exec \"${SHELL:-sh}\"")

check("clone script ends with a no-op so sh cannot exec the mv", shell.CLONE_SCRIPT:match(":\n$") ~= nil)
local a = shell.cloneArgv("u", "d", "j")
local want = { "setsid", "sh", "-c", shell.CLONE_SCRIPT, "vscode-clone", "u", "d", "j" }
eq("cloneArgv length", #a, #want)
for i = 1, #want do eq("cloneArgv " .. i, a[i], want[i]) end
local pk = shell.pickArgv("o", "T")
local pw = { "setsid", "sh", "-c", shell.PICK_SCRIPT, "vscode-pick", "o", "T" }
for i = 1, #pw do eq("pickArgv " .. i, pk[i], pw[i]) end
local k = shell.cancelArgv(123)
eq("cancelArgv", table.concat(k, " "), "kill -TERM -- -123")
eq("cancelArgv n", #k, 4)

local j = shell.parseJob("123\n", "0\n")
eq("parseJob pid", j.pid, 123)
eq("parseJob exit", j.exit, 0)
j = shell.parseJob("123", nil)
eq("parseJob pid only", j.pid, 123)
eq("parseJob no exit", j.exit, nil)
j = shell.parseJob(nil, nil)
eq("parseJob empty", next(j), nil)
eq("parseJob garbage", shell.parseJob("x", "y").pid, nil)

-- git --progress rewrites its line with \r many times a second, so a long clone's log
-- holds thousands of segments. Only the tail may be parsed (the host's Luau is ~40x
-- slower than this runner and a callback has ~25 ms).
local function bigLog(n, last)
  local parts = { "Cloning into 'x'...\n" }
  for i = 1, n do
    parts[#parts + 1] = string.format("Receiving objects:  %d%% (%d/99999)\r", i % 100, i)
  end
  parts[#parts + 1] = last
  return table.concat(parts)
end
eq("cloneProgress last segment", shell.cloneProgress(bigLog(10, "Resolving deltas: 100% (5/5), done.\n")), "Resolving deltas: 100% (5/5), done.")
eq("cloneProgress empty", shell.cloneProgress(""), nil)
eq("cloneProgress nil", shell.cloneProgress(nil), nil)
eq("cloneProgress one partial segment", shell.cloneProgress("Receiving objects:  1%"), "Receiving objects:  1%")
eq("cloneProgress caps length", #shell.cloneProgress(string.rep("a", 500)), 120)
local cut = shell.cloneProgress(string.rep("é", 100))
check("cloneProgress keeps whole UTF-8 chars", cut ~= nil and not cut:match("[\192-\255]$") and utf8.len(cut) ~= nil)
eq("cloneError finds fatal", shell.cloneError(bigLog(10, "fatal: repository 'u' not found\n")), "fatal: repository 'u' not found")
eq("cloneError none", shell.cloneError(bigLog(10, "done.\n")), nil)
local huge = bigLog(200000, "Receiving objects: 100% (99999/99999), done.\n")
local t0 = os.clock()
for _ = 1, 10 do
  shell.cloneProgress(huge)
  shell.cloneError(huge)
end
local per = (os.clock() - t0) / 10
check(string.format("cloneProgress/cloneError on a %d KB log stay bounded (%.3f ms)", #huge // 1024, per * 1000), per < 0.02)
