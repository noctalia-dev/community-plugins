local recents = loadModule("recents.luau")
local decode = json.decode

-- parseDb
local db = recents.parseDb(fixture("state-vscdb-recents.json"), decode)
eq("parseDb count", #db, 4)
eq("parseDb 1", db[1].uri.key, "file:///home/user/projects/demo-api")
eq("parseDb 1 kind", db[1].kind, "folder")
eq("parseDb 2 kind", db[2].kind, "workspace")
eq("parseDb 2 key", db[2].uri.key, "file:///home/user/work/team.code-workspace")
eq("parseDb 3 remote", db[3].uri.remote, "ssh")
eq("parseDb 4 path decoded", db[4].uri.path, "/home/user/work/my app")
eq("parseDb bad json", recents.parseDb("{", decode), nil)
eq("parseDb empty entries", #recents.parseDb('{"entries":[]}', decode), 0)
eq("parseDb throwing decoder", recents.parseDb("{", function() error("boom") end), nil)

-- parseMenu
local menu = recents.parseMenu(fixture("storage-menubar.json"), decode)
eq("parseMenu count", #menu, 3)
eq("parseMenu 1", menu[1].uri.key, "file:///home/user/projects/demo-api")
eq("parseMenu 2 kind", menu[2].kind, "workspace")
eq("parseMenu 3 built from fields", menu[3].uri.key, "vscode-remote://ssh-remote+mybox/home/me/api")
eq("parseMenu 3 host", menu[3].uri.host, "mybox")
eq("parseMenu empty obj", #recents.parseMenu("{}", decode), 0)
eq("parseMenu truncated", recents.parseMenu(fixture("storage-truncated.json"), decode), nil)

-- VS Code 1.140 writes storage.json pretty-printed; older ones compact. Both parse.
local function menuItem(id, external)
  return '{\n      "id": "' .. id .. '",\n      "uri": {\n        "$mid": 1,\n        "external": "' .. external .. '",\n        "path": "/x",\n        "scheme": "file"\n      },\n      "enabled": true,\n      "label": "x"\n    }'
end
local function prettyStorage(items, filler)
  return '{\n  "theme": "dark",\n  "lastKnownMenubarData": {\n    "menus": {\n      "File": {\n        "items": [\n          {\n            "id": "submenuitem.MenubarRecentMenu",\n            "submenu": {\n              "items": [\n' .. table.concat(items, ",\n") .. '\n              ]\n            }\n          }\n        ]\n      }\n    }\n  },\n  "profileAssociations": {\n' .. (filler or "") .. '  "z": 1\n  }\n}\n'
end
local pretty = recents.parseMenu(prettyStorage({
  menuItem("openRecentFolder", "file:///home/user/projects/demo-api"),
  menuItem("openRecentFile", "file:///home/user/notes.txt"),
  menuItem("openRecentWorkspace", "file:///home/user/work/team.code-workspace"),
  menuItem("openRecentFolder", "file:///home/user/work/my%20app"),
}), decode)
eq("parseMenu pretty count (files skipped)", pretty and #pretty, 3)
eq("parseMenu pretty order 1", pretty and pretty[1].uri.path, "/home/user/projects/demo-api")
eq("parseMenu pretty workspace", pretty and pretty[2].kind, "workspace")
eq("parseMenu pretty decodes path", pretty and pretty[3].uri.path, "/home/user/work/my app")
eq("parseMenu pretty truncated is nil", recents.parseMenu(prettyStorage({ menuItem("openRecentFolder", "file:///home/user/a") }):sub(1, -40), decode), nil)

-- Field order other than id-then-uri still parses (fallback walk).
local swapped = '{"lastKnownMenubarData":{"menus":{"File":{"items":[{"submenu":{"items":[{"uri":{"external":"file:///home/user/projects/demo-api","scheme":"file","path":"/home/user/projects/demo-api"},"id":"openRecentFolder"}]}}]}}}}'
local sw = recents.parseMenu(swapped, decode)
eq("parseMenu other field order", sw and #sw, 1)
eq("parseMenu other field order path", sw and sw[1].uri.path, "/home/user/projects/demo-api")

-- A brace inside a path cannot derail the fast scan: falls back and stays correct.
local braced = recents.parseMenu(prettyStorage({
  '{\n      "id": "openRecentFolder",\n      "uri": {\n        "external": "file:///home/user/a%7Bb",\n        "path": "/home/user/a{b",\n        "scheme": "file"\n      }\n    }',
  menuItem("openRecentFolder", "file:///home/user/projects/demo-api"),
}), decode)
eq("parseMenu brace in path count", braced and #braced, 2)
eq("parseMenu brace in path decoded", braced and braced[1].uri.path, "/home/user/a{b")

-- Cost: a ~120 KB storage.json with a large menu cache must stay cheap (the host runs
-- Luau ~40x slower than this runner and a callback gets ~25 ms).
do
  local items = {}
  for i = 1, 10 do items[#items + 1] = menuItem("openRecentFolder", "file:///home/user/p" .. i) end
  for i = 1, 400 do items[#items + 1] = '{\n      "id": "workbench.action.x' .. i .. '",\n      "label": "&&Item ' .. i .. '",\n      "keybinding": { "label": "Ctrl+' .. i .. '", "userSettingsLabel": "ctrl+' .. i .. '" }\n    }' end
  local filler = {}
  for i = 1, 900 do filler[#filler + 1] = '    "file:///home/user/w' .. i .. '": "__default__profile__",\n' end
  local big = prettyStorage(items, table.concat(filler))
  check("cost fixture is large (" .. (#big // 1024) .. " KB)", #big > 100 * 1024)
  local best = math.huge
  local got
  for _ = 1, 5 do
    local t0 = os.clock()
    got = recents.parseMenu(big, decode)
    best = math.min(best, os.clock() - t0)
  end
  eq("parseMenu big file finds the recents", got and #got, 10)
  check(string.format("parseMenu big file is cheap (%.3f ms)", best * 1000), best < 0.003) -- the old full walk took ~18 ms
end

-- parseWorkspaceJson
local wf = recents.parseWorkspaceJson('{"folder":"file:///home/user/a"}', decode)
eq("ws folder", wf.kind, "folder")
eq("ws folder key", wf.uri.key, "file:///home/user/a")
local ww = recents.parseWorkspaceJson('{"workspace":"file:///home/user/x.code-workspace"}', decode)
eq("ws workspace", ww.kind, "workspace")
eq("ws bad", recents.parseWorkspaceJson("{", decode), nil)
eq("ws none", recents.parseWorkspaceJson("{}", decode), nil)

-- merge
local uris = loadModule("uris.luau")
local function it(raw, kind, mtime) return { uri = uris.parse(raw), kind = kind or "folder", mtime = mtime } end
local opts = { home = "/home/user", hidden = {}, showRemote = true }
local head = { it("file:///home/user/b"), it("file:///home/user/a"), it("file:///home/user/c") }
local ws = {
  it("file:///home/user/old", "folder", 10),
  it("file:///home/user/a/", "folder", 99),
  it("file:///home/user/new", "folder", 50),
  it("vscode-remote://ssh-remote%2Bmybox/home/me/api", "folder", 70),
}
local m = recents.merge(head, ws, opts)
eq("merge count", #m, 6)
eq("merge head 1", m[1].path, "/home/user/b")
eq("merge head 2 stays", m[2].path, "/home/user/a")
eq("merge head 2 mtime", m[2].mtime, 99)
eq("merge head 3", m[3].path, "/home/user/c")
eq("merge tail 1 (mtime desc)", m[4].host, "mybox")
eq("merge tail 2", m[5].path, "/home/user/new")
eq("merge tail 3", m[6].path, "/home/user/old")

-- VS Code's menu list (the head) can be stale while VS Code runs: a project used more
-- recently than every head entry goes on top, newest first; the head keeps its order.
local staleHead = { it("file:///home/user/h1"), it("file:///home/user/h2"), it("file:///home/user/h3") }
local staleWs = {
  it("file:///home/user/h1", "folder", 50),
  it("file:///home/user/h2", "folder", 40),
  it("file:///home/user/fresh", "folder", 60),
  it("file:///home/user/fresher", "folder", 70),
  it("file:///home/user/older", "folder", 30),
}
local sm = recents.merge(staleHead, staleWs, opts)
eq("stale head: count", #sm, 6)
eq("stale head: newest used first", sm[1].path, "/home/user/fresher")
eq("stale head: then next newest", sm[2].path, "/home/user/fresh")
eq("stale head: head order kept 1", sm[3].path, "/home/user/h1")
eq("stale head: head order kept 2", sm[4].path, "/home/user/h2")
eq("stale head: head entry without mtime stays", sm[5].path, "/home/user/h3")
eq("stale head: older history after head", sm[6].path, "/home/user/older")
-- With no mtime on any head entry there is nothing to compare: nothing is promoted.
local nm = recents.merge({ it("file:///home/user/x") }, { it("file:///home/user/y", "folder", 5) }, opts)
eq("no head mtimes: head first", nm[1].path, "/home/user/x")
eq("no head mtimes: history after", nm[2].path, "/home/user/y")
eq("entry title", m[1].title, "b")
eq("entry subtitle", m[1].subtitle, "~/b")
eq("entry subtitle remote", m[4].subtitle, "mybox:/home/me/api")
eq("entry key", m[1].key, "file:///home/user/b")
eq("entry uri raw", m[1].uri, "file:///home/user/b")
eq("entry kind", m[1].kind, "folder")
eq("entry pinned false", m[1].pinned, false)
eq("entry missing false", m[1].missing, false)
local hid = recents.merge(head, ws, { home = "/home/user", hidden = { ["file:///home/user/a"] = true }, showRemote = true })
eq("hidden removed", #hid, 5)
local nor = recents.merge(head, ws, { home = "/home/user", hidden = {}, showRemote = false })
eq("showRemote false", #nor, 5)
for _, e in ipairs(nor) do check("no remote " .. e.path, e.remote == nil) end
local dup = recents.merge({ it("file:///home/user/a"), it("file:///home/user/a/") }, {}, opts)
eq("head dedup", #dup, 1)
eq("recents: fresh profile", #recents.merge({}, {}, opts), 0)

-- split
local function entries()
  return recents.merge({ it("file:///home/user/b"), it("file:///home/user/a"), it("file:///home/user/gone") },
    { it("vscode-remote://ssh-remote%2Bmybox/home/me/api", "folder", 70) }, opts)
end
local calls = {}
local function missing(e) calls[#calls + 1] = e.key; return e.path == "/home/user/gone" end
local pinned, recent = recents.split(entries(), { "file:///home/user/a", "file:///home/user/zzz", "file:///home/user/gone" }, missing, false)
eq("pinned count", #pinned, 3)
eq("pinned order 1", pinned[1].key, "file:///home/user/a")
eq("pinned flag", pinned[1].pinned, true)
eq("pinned absent built", pinned[2].path, "/home/user/zzz")
eq("pinned absent title", pinned[2].title, "zzz")
eq("pinned absent not missing", pinned[2].missing, false)
eq("pinned present+missing", pinned[3].missing, true)
eq("recent count", #recent, 2)
eq("recent 1", recent[1].path, "/home/user/b")
eq("recent not pinned", recent[1].pinned, false)
for _, c in ipairs(calls) do check("remote never checked " .. c, not c:find("vscode%-remote")) end
local ph = recents.split(entries(), { "file:///home/user/zzz" }, missing, false, "/home/user")
eq("pinned absent subtitle ~-shortened", ph[1].subtitle, "~/zzz")
local pn = recents.split(entries(), { "file:///home/user/zzz" }, missing, false)
check("pinned absent subtitle without home is the full path", pn[1].subtitle ~= "~/zzz")
local _, r2 = recents.split(entries(), {}, missing, false)
eq("missing kept w/o hide", #r2, 4)
local _, r3 = recents.split(entries(), {}, missing, true)
eq("hideMissing drops", #r3, 3)
local p4, r4 = recents.split(entries(), { "file:///home/user/gone" }, missing, true)
eq("hideMissing keeps pinned", #p4, 1)
eq("pinned marked missing", p4[1].missing, true)
local spy = 0
local winEntries = recents.merge({ it("file:///c%3A/Users/x") }, {}, opts)
recents.split(winEntries, {}, function() spy = spy + 1; return false end, true)
eq("c: path never reaches isMissing", spy, 0)
eq("no isMissing ok", #select(2, recents.split(entries(), {}, nil, true)), 4)

-- entry / merge opts.make (the service caches entries: building one costs ~0.2 ms in the host)
local built = recents.entry(it("file:///home/user/x").uri, "folder", 7, "/home/user")
eq("entry title", built.title, "x")
eq("entry subtitle", built.subtitle, "~/x")
eq("entry mtime", built.mtime, 7)
local makes = 0
local viaMake = recents.merge(head, ws, {
  home = "/home/user",
  make = function(uri, kind, mtime, home)
    makes = makes + 1
    return recents.entry(uri, kind, mtime, home)
  end,
})
eq("merge opts.make called per entry", makes, #viaMake)
eq("merge opts.make same result", viaMake[1].path, m[1].path)
