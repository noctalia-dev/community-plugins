local flavors = loadModule("flavors.luau")

local function ids(list)
  local out = {}
  for i, f in ipairs(list) do out[i] = f.id end
  return table.concat(out, ",")
end

-- LIST
eq("list count", #flavors.LIST, 6)
eq("list first", flavors.LIST[1].id, "code")
eq("list code icon", flavors.LIST[1].iconIds[1], "vscode")
local byId = {}
for _, f in ipairs(flavors.LIST) do byId[f.id] = f end
eq("codium icon", byId.codium.iconIds[1], "vscodium")
eq("codium cmd", byId.codium.cmd[1], "codium")
eq("flatpak cmd", table.concat(byId.flatpak.cmd, " "), "flatpak run com.visualstudio.code")
eq("flatpak dir", byId.flatpak.configDir, "~/.var/app/com.visualstudio.code/config/Code")

-- installed
local have = { code = true, codium = true, flatpak = true, cursor = true }
local dirs = {
  ["~/.config/Code"] = true,
  ["~/.config/VSCodium"] = true,
  ["~/.config/Cursor"] = false,
  ["~/.var/app/com.visualstudio.code/config/Code"] = true,
}
local inst = flavors.installed(function(c) return have[c] == true end, function(d) return dirs[d] == true end)
eq("installed", ids(inst), "code,codium,flatpak")
local none = flavors.installed(function() return true end, function() return false end)
eq("installed none", #none, 0)
local noFlatpakCmd = flavors.installed(function(c) return c ~= "flatpak" end, function() return true end)
eq("flatpak needs flatpak cmd", ids(noFlatpakCmd):find("flatpak"), nil)

-- choose
local list = { byId.code, byId.codium, byId.cursor }
local function mt(map) return function(f) return map[f.id] end end
eq("choose newest", flavors.choose("auto", list, mt({ code = 5, codium = 9, cursor = 7 })).id, "codium")
eq("choose tie -> order", flavors.choose("auto", list, mt({ code = 5, codium = 5 })).id, "code")
eq("choose nils -> order", flavors.choose("auto", list, mt({})).id, "code")
eq("choose nil loses", flavors.choose("auto", list, mt({ cursor = 1 })).id, "cursor")
eq("choose explicit", flavors.choose("cursor", list, mt({ code = 9 })).id, "cursor")
eq("choose explicit not installed", flavors.choose("flatpak", list, mt({ codium = 9 })).id, "codium")
eq("choose unknown setting", flavors.choose("bogus", list, mt({})).id, "code")
eq("choose empty", flavors.choose("auto", {}, mt({})), nil)
eq("choose explicit empty", flavors.choose("code", {}, mt({})), nil)
-- hasHistory: under auto, only flavors with workspaceStorage history compete
local function hist(set) return function(f) return set[f.id] == true end end
eq("choose history wins over newer", flavors.choose("auto", list, mt({ code = 5, codium = 9 }), hist({ code = true })).id, "code")
eq("choose newest among history", flavors.choose("auto", list, mt({ code = 5, codium = 9, cursor = 7 }), hist({ code = true, cursor = true })).id, "cursor")
eq("choose no history falls back", flavors.choose("auto", list, mt({ code = 5, codium = 9 }), hist({})).id, "codium")
eq("choose explicit ignores history", flavors.choose("codium", list, mt({}), hist({ code = true })).id, "codium")
eq("choose unknown setting uses history", flavors.choose("bogus", list, mt({ codium = 9 }), hist({ code = true })).id, "code")
eq("choose nil hasHistory unchanged", flavors.choose("auto", list, mt({ code = 5, codium = 9 }), nil).id, "codium")
eq("choose nil setting", flavors.choose(nil, list, mt({ codium = 2 })).id, "codium")

-- openArgv
local function argv(f, e) return table.concat(flavors.openArgv(f, e), "|") end
local code = byId.code
eq("argv local folder", argv(code, { kind = "folder", uri = "file:///home/user/my%20app", path = "/home/user/my app" }), "code|/home/user/my app")
eq("argv local ws", argv(code, { kind = "workspace", uri = "file:///home/user/x.code-workspace", path = "/home/user/x.code-workspace" }), "code|/home/user/x.code-workspace")
eq("argv ssh folder", argv(code, { kind = "folder", remote = "ssh", uri = "vscode-remote://ssh-remote+box/home/me/a", path = "/home/me/a" }), "code|--folder-uri|vscode-remote://ssh-remote+box/home/me/a")
eq("argv remote ws", argv(code, { kind = "workspace", remote = "ssh", uri = "vscode-remote://ssh-remote+box/home/me/a.code-workspace", path = "/home/me/a.code-workspace" }), "code|--file-uri|vscode-remote://ssh-remote+box/home/me/a.code-workspace")
eq("argv non-file scheme no remote", argv(code, { kind = "folder", uri = "vscode-vfs://github/a/b", path = "/a/b" }), "code|--folder-uri|vscode-vfs://github/a/b")
eq("argv flatpak", argv(byId.flatpak, { kind = "folder", uri = "file:///p", path = "/p" }), "flatpak|run|com.visualstudio.code|/p")
eq("argv path starting dash", argv(code, { kind = "folder", uri = "file:///-x", path = "/-x" }), "code|/-x")
for _, f in ipairs(flavors.LIST) do
  for _, e in ipairs({
    { kind = "folder", uri = "file:///p", path = "/p" },
    { kind = "folder", remote = "ssh", uri = "vscode-remote://ssh-remote+b/p", path = "/p" },
  }) do
    for _, a in ipairs(flavors.openArgv(f, e)) do
      check("no window flags " .. f.id, a ~= "--new-window" and a ~= "--reuse-window")
    end
  end
end

-- parsePathInput
local home = "/home/user"
local present = {
  ["/home/user/my app"] = { isDir = true },
  ["/home/user/proj"] = { isDir = true },
  ["/home/user/x.code-workspace"] = { isDir = false },
  ["/home/user/notes.txt"] = { isDir = false },
  ["/"] = { isDir = true },
}
local function info(p) return present[p] end
local function parse(t) return flavors.parsePathInput(t, home, info) end
local cases = {
  { "'/home/user/my app'", "/home/user/my app", "folder" },
  { '"/home/user/my app"', "/home/user/my app", "folder" },
  { "/home/user/my app\n", "/home/user/my app", "folder" },
  { "  ~/proj/  ", "/home/user/proj", "folder" },
  { "file:///home/user/my%20app", "/home/user/my app", "folder" },
  { "/home/user/x.code-workspace", "/home/user/x.code-workspace", "workspace" },
  { "/", "/", "folder" },
  { "//", "/", "folder" },
  { "'  /home/user/my app '", nil, nil },
}
for _, c in ipairs(cases) do
  local r = parse(c[1])
  if c[2] then
    check("parse ok " .. c[1], r.ok == true)
    eq("parse path " .. c[1], r.path, c[2])
    eq("parse kind " .. c[1], r.kind, c[3])
  else
    check("parse inner-space not trimmed " .. c[1], r.ok == false and r.err == "path.missing")
  end
end
eq("parse tilde alone", flavors.parsePathInput("~", home, function(p) return p == "/home/user" and { isDir = true } or nil end).path, "/home/user")
local f = parse("/home/user/notes.txt")
check("not project", f.ok == false and f.err == "path.not_project")
f = parse("/home/user/nope")
check("missing", f.ok == false and f.err == "path.missing")
f = parse("   ")
check("empty", f.ok == false and f.err == "path.empty")
f = parse("")
check("empty string", f.ok == false and f.err == "path.empty")
f = parse(nil)
check("nil input", f.ok == false and f.err == "path.empty")
f = parse("''")
check("empty quotes", f.ok == false and f.err == "path.empty")
f = parse("file://")
check("empty file uri", f.ok == false and f.err == "path.empty")
f = parse("relative/dir")
check("relative is missing", f.ok == false and f.err == "path.missing")

-- Icon names from the real desktop entries (checked on Arch: cursor-bin, visual-studio-code-insiders-bin).
local function hasIcon(id, name)
  for _, n in ipairs(byId[id].iconIds) do
    if n == name then return true end
  end
  return false
end
check("cursor icon from cursor.desktop", hasIcon("cursor", "co.anysphere.cursor"))
check("insiders icon from its desktop entry", hasIcon("insiders", "vscode-insiders"))
-- Noctalia's appIconPath("vscode-insiders") resolves to the plain vscode.png (it
-- fuzzy-matches the name), while the desktop entry id resolves to the green Insiders
-- icon (checked live on 2026-11-06), so the desktop entry id must come first.
eq("insiders tries its desktop entry id first", byId.insiders.iconIds[1], "com.microsoft.VSCodeInsiders")

-- Flatpak's sandbox hides some host folders even with filesystem=host (checked live:
-- its /tmp is private; /var/tmp, /usr and /etc are hidden; home, /opt, /srv, /mnt,
-- /run/media and other top-level folders are visible).
local fp = byId.flatpak
for _, p in ipairs({ "/tmp", "/tmp/demo-proj", "/var/tmp/x", "/usr/share/x", "/etc/x", "/proc/1", "/sys/x", "/dev/x", "/run/user/1000/x", "/app/x", "/bin", "/lib/x", "/lib64/x", "/sbin/x" }) do
  eq("flatpak hides " .. p, flavors.sandboxHides(fp, p), true)
end
for _, p in ipairs({ "/home/user/x", "/work/x", "/opt/x", "/srv/x", "/mnt/x", "/run/media/user/disk", "/tmpfoo/x", "/usrlocal" }) do
  eq("flatpak sees " .. p, flavors.sandboxHides(fp, p), false)
end
eq("native editors hide nothing", flavors.sandboxHides(byId.code, "/tmp/demo-proj"), false)
