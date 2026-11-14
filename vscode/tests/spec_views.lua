-- view_panel.build on stubs.ui. All paths are made up.
local previousUi = _G.ui
_G.ui = stubs.ui
local view = loadModule("view_panel.luau")

-- Shows what would be substituted: "key{k=v,...}", or the bare key.
local function tr(key, subst)
  if subst == nil or next(subst) == nil then return key end
  local parts = {}
  for k, v in pairs(subst) do parts[#parts + 1] = k .. "=" .. tostring(v) end
  table.sort(parts)
  return key .. "{" .. table.concat(parts, ",") .. "}"
end

local function entry(name, over)
  local path = "/home/user/projects/" .. name
  local e = {
    key = "file://" .. path, uri = "file://" .. path, kind = "folder", path = path,
    title = name, subtitle = "~/projects/" .. name, pinned = false, missing = false,
  }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

local function recents(n)
  local out = {}
  for i = 1, n do out[i] = entry("demo-" .. i) end
  return out
end

local function snap(over)
  local s = {
    seq = 1, requestSeq = 0, serviceBootId = "boot",
    flavor = { id = "code", name = "VS Code" }, flavorsInstalled = { "code" },
    loading = false, pinned = {}, recent = recents(3), git = {},
    hasGit = true, hasPicker = true, clone = { state = "idle" },
  }
  for k, v in pairs(over or {}) do s[k] = v end
  if s.flavor == false then s.flavor = nil end -- pairs() cannot carry a nil
  return s
end

local function uiState(over)
  local u = { shown = 5, input = "", inputSeq = 0, cloneDir = "~/Projects" }
  for k, v in pairs(over or {}) do u[k] = v end
  return u
end

local calls
local function handlers()
  calls = {}
  local h = {}
  for _, name in ipairs({ "open", "openPath", "clone", "pickFolder", "cancelClone", "openExisting",
    "dismiss", "loadMore", "setInput", "menu", "toggleActions", "action", "close", "unhide", "openSettings",
    "setMode", "setQuery" }) do
    h[name] = function(...) calls[#calls + 1] = { name, ... } end
  end
  return h
end

local function build(s, u)
  return view.build(s, u or uiState(), tr, handlers())
end

local function walk(tree, fn)
  if type(tree) ~= "table" then return end
  fn(tree)
  for _, child in ipairs(tree.children or {}) do walk(child, fn) end
end

local function findKey(tree, key)
  local found
  walk(tree, function(n) if found == nil and n.props.key == key then found = n end end)
  return found
end

local function findText(tree, text)
  local found
  walk(tree, function(n) if found == nil and n.props.text == text then found = n end end)
  return found
end

local function collect(tree, pred)
  local out = {}
  walk(tree, function(n) if pred(n) then out[#out + 1] = n end end)
  return out
end

local function rows(tree, prefix)
  prefix = prefix or "row."
  return collect(tree, function(n)
    local k = n.props.key
    return n.type == "row" and type(k) == "string" and k:sub(1, #prefix) == prefix and n.props.onClick ~= nil
  end)
end

local function primaries(tree)
  return collect(tree, function(n) return n.type == "button" and n.props.variant == "primary" end)
end

-- ── views: settings gear and hidden rows ─────────────────────────────────────

do
  local gear = findKey(findKey(build(snap()), "hdr"), "btn.settings")
  check("views: settings gear in the header", gear ~= nil)
  eq("views: gear glyph", gear and gear.props.glyph, "settings")
  eq("views: gear is icon-only", gear and gear.props.text, nil)
  eq("views: gear tooltip", gear and gear.props.tooltip, "panel.settings")
  eq("views: gear is ghost", gear and gear.props.variant, "ghost")
  gear.props.onClick()
  eq("views: gear opens settings", calls[#calls][1], "openSettings")
  check("views: no eye toggle any more", findKey(build(snap()), "btn.hidden") == nil)

  local list = recents(2)
  list[1].hidden = true
  list[2].hidden = false
  local ht = build(snap({ recent = list }))
  local k1, k2 = "row.rec." .. list[1].key, "row.rec." .. list[2].key
  eq("views: hidden row dimmed", findKey(ht, k1).props.opacity, 0.5)
  eq("views: visible row full opacity", findKey(ht, k2).props.opacity, 1)
  check("views: hidden row has the Hidden tag", findKey(ht, k1 .. ".hidden") ~= nil and findText(ht, "tag.hidden") ~= nil)
  check("views: visible row has no Hidden tag", findKey(ht, k2 .. ".hidden") == nil)
  local ub = findKey(ht, k1 .. ".unhide")
  check("views: hidden row has Unhide", ub ~= nil)
  eq("views: Unhide is icon-only", ub and ub.props.text, nil)
  eq("views: Unhide glyph", ub and ub.props.glyph, "eye")
  eq("views: Unhide tooltip", ub and ub.props.tooltip, "panel.unhide")
  eq("views: Unhide is ghost", ub and ub.props.variant, "ghost")
  ub.props.onClick()
  eq("views: Unhide calls h.unhide", calls[#calls][1], "unhide")
  eq("views: Unhide sends the key", calls[#calls][2], list[1].key)
  check("views: visible row has no Unhide", findKey(ht, k2 .. ".unhide") == nil)
  local menuIds = {}
  for _, it in ipairs(view.menuItems(list[1], tr)) do
    if it.id then menuIds[#menuIds + 1] = it.id end
  end
  check("views: hidden row menu offers unhide, not hide", table.concat(menuIds, ","):match("unhide") ~= nil and not table.concat(menuIds, ","):match("%f[%w]hide"))
  eq("views: unhide is a menu action", view.menuRequest("unhide", list[1].key).action, "unhide")
end

-- ── views: editor fallback notice ────────────────────────────────────────────

do
  local ft = build(snap({ flavorFallback = { wanted = "VS Code Insiders", reason = "not_set_up" } }))
  local n = findKey(ft, "lbl.fallback")
  check("views: fallback notice shown", n ~= nil)
  check("views: fallback notice text", findText(ft, "panel.fallback_not_set_up{using=VS Code,wanted=VS Code Insiders}") ~= nil)
  ft = build(snap({ flavorFallback = { wanted = "Cursor", reason = "not_installed" } }))
  check("views: not-installed text", findText(ft, "panel.fallback_not_installed{using=VS Code,wanted=Cursor}") ~= nil)
  check("views: no notice without fallback", findKey(build(snap()), "lbl.fallback") == nil)
end

-- ── views: cloned chip ───────────────────────────────────────────────────────

do
  local list = recents(2)
  local s1 = snap({ recent = list })
  s1.cloned = { [list[1].key] = true }
  local ct = build(s1)
  local chip = findKey(ct, "row.rec." .. list[1].key .. ".cloned")
  check("views: cloned project has the Cloned chip", chip ~= nil)
  check("views: Cloned chip has its glyph", findKey(ct, "row.rec." .. list[1].key .. ".cloned.glyph") ~= nil)
  check("views: Cloned chip text", findText(ct, "tag.cloned") ~= nil)
  check("views: other project has no chip", findKey(ct, "row.rec." .. list[2].key .. ".cloned") == nil)
  check("views: no cloned map, no chip", findKey(build(snap({ recent = list })), "row.rec." .. list[1].key .. ".cloned") == nil)
end

-- ── views: 5 rows then load more ─────────────────────────────────────────────

local t = build(snap({ recent = recents(12) }))
eq("views: 5 rows then load more (rows)", #rows(t, "row.rec."), 5)
check("views: 5 rows then load more (button)", findKey(t, "btn.more") ~= nil)
findKey(t, "btn.more").props.onClick()
eq("views: load more calls h.loadMore", calls[1] and calls[1][1], "loadMore")
t = build(snap({ recent = recents(12) }), uiState({ shown = 15 }))
eq("views: shown=15 gives 12 rows", #rows(t, "row.rec."), 12)
check("views: no load more when all shown", findKey(t, "btn.more") == nil)
t = build(snap({ recent = recents(5) }))
check("views: no load more at exactly shown", findKey(t, "btn.more") == nil)

-- ── views: pinned above recent ───────────────────────────────────────────────

local pin = entry("pinned-api", { pinned = true })
t = build(snap({ pinned = { pin }, recent = recents(2) }))
local order = {}
walk(t, function(n)
  if n.props.key == "sec.pinned" or n.props.key == "sec.recent" then order[#order + 1] = n.props.key end
end)
eq("views: pinned above recent (first)", order[1], "sec.pinned")
eq("views: pinned above recent (second)", order[2], "sec.recent")
check("views: pinned row has the pin glyph", findKey(t, "row.pin." .. pin.key .. ".pin") ~= nil)
eq("views: one pinned row", #rows(t, "row.pin."), 1)
t = build(snap({ pinned = {}, recent = recents(2) }))
check("views: no pinned section without pins", findKey(t, "sec.pinned") == nil)

-- rows open on click
t = build(snap())
local first = rows(t, "row.rec.")[1]
first.props.onClick()
eq("views: row click opens", calls[1] and calls[1][1], "open")
eq("views: row click sends the key", calls[1] and calls[1][2], "file:///home/user/projects/demo-1")
local menuBtn = findKey(t, "row.rec.file:///home/user/projects/demo-1.menu")
check("views: row menu button has onRightClick", menuBtn and menuBtn.props.onRightClick ~= nil)
menuBtn.props.onRightClick()
eq("views: right click calls h.menu", calls[2] and calls[2][1], "menu")
eq("views: row menu button is ghost", menuBtn.props.variant, "ghost")
menuBtn.props.onClick()
eq("views: left click on the menu button toggles actions", calls[3] and calls[3][1], "toggleActions")
eq("views: toggle passes the key", calls[3] and calls[3][2], "file:///home/user/projects/demo-1")
eq("views: menu button tooltip", menuBtn.props.tooltip, "panel.actions")

-- ── views: git url swaps button to clone ─────────────────────────────────────

t = build(snap(), uiState({ mode = "open", input = "/home/user/projects/demo-1" }))
check("views: a typed path has no button (Enter opens it)", findKey(t, "btn.go") == nil)
local url = "https://example.com/acme/demo-api.git"
t = build(snap(), uiState({ mode = "open", input = url }))
eq("views: git url swaps button to clone", findKey(t, "btn.go").props.text, "panel.clone")
check("views: clone shows the target folder", findText(t, "clone.dest{dest=~/Projects/demo-api}") ~= nil)
local change = findKey(t, "btn.clone_settings")
check("views: clone line offers Change", change ~= nil and change.props.text == "clone.change")
eq("views: Change is a ghost button", change and change.props.variant, "ghost")
change.props.onClick()
eq("views: Change opens the plugin settings", calls[1] and calls[1][1], "openSettings")
calls = {}
findKey(t, "btn.go").props.onClick()
eq("views: Clone calls h.clone", calls[1] and calls[1][1], "clone")
eq("views: Clone passes the url", calls[1] and calls[1][2], url)
local input = collect(t, function(n) return n.type == "input" end)[1]
input.props.onSubmit(url .. "\n")
eq("views: Enter on a git url clones", calls[2] and calls[2][1], "clone")
input.props.onSubmit("  ~/projects/demo-1  ")
eq("views: Enter on a path opens", calls[3] and calls[3][1], "openPath")
input.props.onSubmit("   ")
eq("views: Enter on blank does nothing", calls[4], nil)
t = build(snap({ hasGit = false }), uiState({ mode = "open", input = url }))
check("views: no git hides the clone button", findKey(t, "btn.go") == nil)
check("views: no git shows clone.no_git", findText(t, "clone.no_git") ~= nil)
input = collect(t, function(n) return n.type == "input" end)[1]
input.props.onSubmit(url)
eq("views: Enter on a git url without git does nothing", calls[1], nil)
t = build(snap({ pathError = "path.missing" }), uiState({ mode = "open", input = "/nope" }))
check("views: pathError shows under the box", findText(t, "path.missing") ~= nil)
t = build(snap({ pathError = "path.flatpak_hidden" }))
check("views: pathError shows with the box closed too", findText(t, "path.flatpak_hidden") ~= nil)
eq("views: input key carries the seq", collect(build(snap(), uiState({ mode = "open", inputSeq = 4 })), function(n) return n.type == "input" end)[1].props.key, "input.path#4")

-- ── views: no picker shows paste hint ────────────────────────────────────────

t = build(snap({ hasPicker = false }), uiState({ mode = "open" }))
check("views: no picker hides Open folder", findKey(t, "btn.pick") == nil)
check("views: no picker shows paste hint", findText(t, "panel.pick_hint") ~= nil)
t = build(snap(), uiState({ mode = "open" }))
check("views: picker shows Open folder", findKey(t, "btn.pick") ~= nil)
eq("views: Open folder is an icon", findKey(t, "btn.pick").props.glyph, "folder-open")
eq("views: Open folder icon has no text", findKey(t, "btn.pick").props.text, nil)
eq("views: Open folder icon tooltip", findKey(t, "btn.pick").props.tooltip, "panel.open_folder")
check("views: picker has no hint", findText(t, "panel.pick_hint") == nil)
findKey(t, "btn.pick").props.onClick()
eq("views: Open folder calls h.pickFolder", calls[1] and calls[1][1], "pickFolder")

-- ── views: empty states ──────────────────────────────────────────────────────

t = build(snap({ flavor = false, flavorsInstalled = {}, recent = {} }))
check("views: empty states no flavor", findText(t, "panel.no_flavor") ~= nil)
local looked = findKey(t, "lbl.looked_for")
check("views: no flavor lists the editors", looked ~= nil and looked.props.text:find("VSCodium", 1, true) ~= nil
  and looked.props.text:find("VS Code Insiders", 1, true) ~= nil and looked.props.text:find("VS Code (Flatpak)", 1, true) ~= nil)
check("views: no flavor names no commands", looked ~= nil and not looked.props.text:find("flatpak,", 1, true)
  and not looked.props.text:find("codium", 1, true))
t = build(snap({ loading = true, recent = {} }))
check("views: empty states loading", findText(t, "panel.loading") ~= nil)
check("views: loading has no empty text", findText(t, "panel.empty") == nil)
t = build(snap({ recent = {}, pinned = {} }))
check("views: empty states no recents", findText(t, "panel.empty") ~= nil)
t = build(nil)
check("views: no snapshot is loading", findText(t, "panel.loading") ~= nil)

-- ── views: remote row has tag and no terminal action ─────────────────────────

local remote = entry("srv-app", {
  key = "vscode-remote://ssh-remote+box/srv/app", uri = "vscode-remote://ssh-remote+box/srv/app",
  remote = "ssh", host = "box", path = "/srv/app", subtitle = "box:/srv/app",
})
local ws = entry("team.code-workspace", { kind = "workspace", title = "team" })
t = build(snap({ recent = { remote, ws } }))
check("views: remote row has tag", findText(t, "tag.ssh") ~= nil)
check("views: workspace row has tag", findText(t, "tag.workspace") ~= nil)
local function ids(items)
  local out = {}
  for _, it in ipairs(items) do if it.id then out[it.id] = true end end
  return out
end
local m = ids(view.menuItems(remote, tr))
check("views: remote menu has no terminal action", not m.open_terminal)
check("views: remote menu has no file manager action", not m.open_files)
check("views: remote menu has copy path and hide", m.copy_path and m.hide and m.pin)
m = ids(view.menuItems(entry("demo-1"), tr))
check("views: local menu has terminal and file manager", m.open_terminal and m.open_files and m.pin and m.hide and m.copy_path)
m = ids(view.menuItems(pin, tr))
check("views: pinned menu offers unpin", m.unpin and not m.pin)
eq("views: menu action names a request", view.menuRequest("open_terminal", "k").action, "open_terminal")
eq("views: menu action carries the key", view.menuRequest("hide", "k").key, "k")
eq("views: unknown menu action is ignored", view.menuRequest("rm", "k"), nil)
for _, kind in ipairs({ "container", "wsl", "tunnel", "other" }) do
  local e = entry("r-" .. kind, { key = "vscode-remote://x/" .. kind, uri = "vscode-remote://x/" .. kind, remote = kind })
  local want = ({ container = "tag.container", wsl = "tag.wsl", tunnel = "tag.tunnel", other = "tag.remote" })[kind]
  check("views: remote tag " .. kind, findText(build(snap({ recent = { e } })), want) ~= nil)
end

-- git badge and dirty dot; git keys only for visible local rows
local key1 = "file:///home/user/projects/demo-1"
t = build(snap({ git = { [key1] = { branch = "main", detached = false, dirty = true } } }))
check("views: git branch shown", findText(t, "main") ~= nil)
local dot = findKey(t, "row.rec." .. key1 .. ".dirty")
check("views: dirty dot shown", dot ~= nil)
eq("views: dirty dot colour", dot and dot.props.fill, "tertiary")
t = build(snap({ git = { [key1] = { branch = "main", detached = false, dirty = false } } }))
check("views: clean has no dot", findKey(t, "row.rec." .. key1 .. ".dirty") == nil)
local keys = view.gitKeys(snap({ pinned = { pin }, recent = { remote, entry("demo-1"), entry("gone", { missing = true }) } }), uiState())
eq("views: git keys count", #keys, 2)
eq("views: git keys pinned first", keys[1], pin.key)
eq("views: git keys skip remote and missing", keys[2], key1)
eq("views: git keys follow shown", #view.gitKeys(snap({ recent = recents(12) }), uiState()), 5)

-- ── views: missing dimmed and back ───────────────────────────────────────────

local function rowProps(tree, key)
  local n = findKey(tree, key)
  return n and n.props or {}
end
local gone = entry("demo-1", { missing = true, pinned = true })
t = build(snap({ pinned = { gone }, recent = {} }))
local rp = rowProps(t, "row.pin." .. key1)
eq("views: missing row dimmed", rp.opacity, 0.5)
check("views: missing row says missing", findText(t, "panel.missing") ~= nil)
t = build(snap({ pinned = { entry("demo-1", { pinned = true }) }, recent = {} }))
rp = rowProps(t, "row.pin." .. key1)
eq("views: row back from missing has opacity 1", rp.opacity, 1)

-- ── views: every state sets every visual prop ────────────────────────────────

local STATES = {
  { "idle", snap() },
  { "open box", snap(), uiState({ mode = "open" }) },
  { "typed path", snap(), uiState({ mode = "open", input = "/home/user/projects/demo-1" }) },
  { "typed url", snap(), uiState({ mode = "open", input = url }) },
  { "search", snap(), uiState({ mode = "search" }) },
  { "search typed", snap({ recent = recents(12), pinned = { pin } }), uiState({ mode = "search", query = "demo-1" }) },
  { "search no match", snap(), uiState({ mode = "search", query = "zzz" }) },
  { "loading", snap({ loading = true, recent = {} }) },
  { "no snapshot", nil },
  { "no flavor", snap({ flavor = false, recent = {} }) },
  { "empty", snap({ recent = {} }) },
  { "clone running", snap({ clone = { state = "running", name = "demo-api", dest = "/home/user/Projects/demo-api", progress = "Receiving objects:  42%" } }), uiState({ mode = "open", input = url }) },
  { "clone exists", snap({ clone = { state = "exists", name = "demo-api", dest = "/home/user/Projects/demo-api" } }), uiState({ input = url }) },
  { "clone done", snap({ clone = { state = "done", name = "demo-api", dest = "/home/user/Projects/demo-api" } }) },
  { "clone failed", snap({ clone = { state = "failed", name = "demo-api", error = "fatal: repository not found" } }) },
  { "clone cancelled", snap({ clone = { state = "cancelled", name = "demo-api" } }) },
  { "last error", snap({ lastError = { key = "error.busy_clone" } }) },
  { "missing pin", snap({ pinned = { gone } }) },
  { "expanded local", snap(), uiState({ expandedKey = key1 }) },
  { "expanded remote", snap({ recent = { remote } }), uiState({ expandedKey = remote.key }) },
  { "expanded missing", snap({ pinned = { gone } }), uiState({ expandedKey = key1 }) },
  { "many", snap({ recent = recents(12), pinned = { pin } }) },
}

local WANT_PRIMARY = {
  ["typed url"] = "btn.go", ["clone exists"] = "btn.open_existing",
}

for _, st in ipairs(STATES) do
  local name, s, u = st[1], st[2], st[3]
  local tree = build(s, u)
  local p = primaries(tree)
  check("views: exactly one primary button per state " .. name, #p <= 1)
  eq("views: primary in " .. name, p[1] and p[1].props.key, WANT_PRIMARY[name])
  local bad = collect(tree, function(n)
    return n.type == "button" and (n.props.selected ~= nil
      or (n.props.variant ~= "primary" and n.props.variant ~= "outline" and n.props.variant ~= "ghost" and n.props.variant ~= "destructive"))
  end)
  eq("views: no selected or filled secondary buttons in " .. name, #bad, 0)
  local noKey = collect(tree, function(n) return n.props.key == nil end)
  eq("views: every node keyed in " .. name, #noKey, 0)
  local retired = collect(tree, function(n)
    for _, prop in ipairs({ "border", "fill", "color" }) do
      local v = n.props[prop]
      if v == "outline" or v == "surface_variant" or (type(v) == "string" and (v:find("^outline/") or v:find("^surface_variant/"))) then
        return true
      end
    end
    return false
  end)
  eq("views: no retired colour roles in " .. name, #retired, 0)
  -- rows and the clone box carry border, borderWidth and opacity on every render
  local styled = collect(tree, function(n)
    local k = n.props.key
    return (n.type == "row" or n.type == "column") and type(k) == "string" and (k == "box.clone" or k == "box.error"
      or (k:sub(1, 4) == "row." and k:match("%.actions$") ~= nil) or ((k:sub(1, 8) == "row.rec." or k:sub(1, 8) == "row.pin.") and n.props.onClick ~= nil))
  end)
  for _, n in ipairs(styled) do
    local ok = n.props.border ~= nil and n.props.borderWidth ~= nil and n.props.opacity ~= nil and n.props.fill ~= nil
    check("views: " .. name .. " " .. n.props.key .. " sets border/opacity/fill", ok)
  end
  local labels = collect(tree, function(n) return n.type == "label" and n.props.color == nil end)
  eq("views: every label sets a colour in " .. name, #labels, 0)
end

-- clone status line
t = build(snap({ clone = { state = "running", name = "demo-api", dest = "/x", progress = "Receiving objects:  42%" } }), uiState({ mode = "open", input = url }))
check("views: running shows progress", findText(t, "Receiving objects:  42%") ~= nil)
local cancel = findKey(t, "btn.cancel_clone")
check("views: running offers cancel", cancel ~= nil)
cancel.props.onClick()
eq("views: cancel calls h.cancelClone", calls[1] and calls[1][1], "cancelClone")
eq("views: clone button disabled while running", findKey(t, "btn.go").props.enabled, false)
t = build(snap({ clone = { state = "exists", name = "demo-api", dest = "/home/user/Projects/demo-api" } }))
findKey(t, "btn.open_existing").props.onClick()
eq("views: open existing calls h.openExisting", calls[1] and calls[1][1], "openExisting")
eq("views: open existing passes the dest", calls[1] and calls[1][2], "/home/user/Projects/demo-api")
check("views: exists can be dismissed", findKey(t, "btn.dismiss_clone") ~= nil)
findKey(t, "btn.dismiss_clone").props.onClick()
eq("views: exists dismiss calls h.dismiss", calls[2] and calls[2][1], "dismiss")
t = build(snap({ clone = { state = "running", name = "demo-api", dest = "/x" } }), uiState({ mode = "open", input = url }))
collect(t, function(n) return n.type == "input" end)[1].props.onSubmit(url)
eq("views: Enter on a git url while cloning does nothing", calls[1], nil)
collect(t, function(n) return n.type == "input" end)[1].props.onSubmit("/home/user/projects/demo-1")
eq("views: Enter on a path while cloning still opens", calls[1] and calls[1][1], "openPath")
t = build(snap(), uiState({ mode = "open", input = url }))
local pathRow = findKey(t, "box.path.row")
check("views: Open folder sits on the path row", pathRow ~= nil and findKey(pathRow, "btn.pick") ~= nil)
t = build(snap({ clone = { state = "failed", name = "demo-api", error = "fatal: repository not found" } }))
check("views: failed shows the error as is", findText(t, "fatal: repository not found") ~= nil)
eq("views: failed box tinted", findKey(t, "box.clone").props.fill, "error/0.12")
findKey(t, "btn.dismiss_clone").props.onClick()
eq("views: dismiss clone calls h.dismiss", calls[1] and calls[1][1], "dismiss")
t = build(snap({ clone = { state = "running", name = "demo-api", dest = "/x" } }))
eq("views: running box untinted after failed", findKey(t, "box.clone").props.fill ~= "error/0.12", true)
t = build(snap({ clone = { state = "idle" } }))
check("views: idle has no clone box", findKey(t, "box.clone") == nil)

-- last error
t = build(snap({ lastError = { key = "error.busy_clone" } }))
check("views: last error shown", findText(t, "error.busy_clone{detail=}") ~= nil or findText(t, "error.busy_clone") ~= nil)
findKey(t, "btn.dismiss_error").props.onClick()
eq("views: dismiss error calls h.dismiss", calls[1] and calls[1][1], "dismiss")

-- header: icon image when the flavor has one, else the glyph
t = build(snap({ flavor = { id = "code", name = "VS Code", iconPath = "/usr/share/icons/x.svg" } }))
check("views: header image", findKey(t, "hdr.image") ~= nil and findKey(t, "hdr.glyph") == nil)
check("views: header names the flavor", findText(t, "VS Code") ~= nil)
t = build(snap({ flavor = { id = "codium", name = "VSCodium" } }))
check("views: header glyph without icon", findKey(t, "hdr.glyph") ~= nil and findKey(t, "hdr.image") == nil)
check("views: header names VSCodium", findText(t, "VSCodium") ~= nil)

-- typing reports through h.setInput
t = build(snap(), uiState({ mode = "open" }))
collect(t, function(n) return n.type == "input" end)[1].props.onChange("abc")
eq("views: typing calls h.setInput", calls[1] and calls[1][1], "setInput")
eq("views: typing passes the text", calls[1] and calls[1][2], "abc")

-- ── views: header search and + icons ─────────────────────────────────────────

t = build(snap())
eq("views: at rest no text fields", #collect(t, function(n) return n.type == "input" end), 0)
check("views: at rest no path row", findKey(t, "box.path") == nil)
local sb, ab = findKey(t, "btn.search"), findKey(t, "btn.add")
check("views: header has search and + icons", sb ~= nil and ab ~= nil)
eq("views: search icon glyph", sb.props.glyph, "search")
eq("views: + icon glyph", ab.props.glyph, "plus")
eq("views: search icon tooltip", sb.props.tooltip, "panel.search")
eq("views: + icon tooltip", ab.props.tooltip, "panel.add")
eq("views: idle search icon is ghost", sb.props.variant, "ghost")
sb.props.onClick()
eq("views: search icon opens search", calls[1] and calls[1][2], "search")
eq("views: search icon calls setMode", calls[1] and calls[1][1], "setMode")
ab.props.onClick()
eq("views: + icon opens the path box", calls[2] and calls[2][2], "open")
t = build(snap(), uiState({ mode = "search" }))
eq("views: active search icon is outline", findKey(t, "btn.search").props.variant, "outline")
eq("views: other icon stays ghost", findKey(t, "btn.add").props.variant, "ghost")
findKey(t, "btn.search").props.onClick()
check("views: search icon again closes search", calls[1] and calls[1][1] == "setMode" and calls[1][2] == nil and #calls[1] == 1)
t = build(snap(), uiState({ mode = "open" }))
findKey(t, "btn.add").props.onClick()
check("views: + icon again closes the box", calls[1] and calls[1][1] == "setMode" and calls[1][2] == nil and #calls[1] == 1)
eq("views: path box takes focus", findKey(t, "input.path#0").props.focus, true)
eq("views: path placeholder", findKey(t, "input.path#0").props.placeholder, "panel.path_placeholder")
eq("views: open box has no search field", findKey(t, "box.search"), nil)

-- ── views: search field ──────────────────────────────────────────────────────

t = build(snap(), uiState({ mode = "search", querySeq = 3 }))
local sf = findKey(t, "input.search#3")
check("views: search field keyed by its seq", sf ~= nil)
eq("views: search field takes focus", sf.props.focus, true)
eq("views: search placeholder", sf.props.placeholder, "panel.search_placeholder")
check("views: search has no path box", findKey(t, "box.path") == nil)
sf.props.onChange("dem")
eq("views: typing in search calls setQuery", calls[1] and calls[1][1], "setQuery")
eq("views: typing passes the query", calls[1] and calls[1][2], "dem")
findKey(t, "btn.search_close").props.onClick()
check("views: search x closes search", calls[2] and calls[2][1] == "setMode" and calls[2][2] == nil)
eq("views: search x tooltip", findKey(t, "btn.search_close").props.tooltip, "panel.search_close")

-- ── views: search filters every project by name ──────────────────────────────

local function titlesOf(tree, prefix)
  local out = {}
  for _, r in ipairs(rows(tree, prefix)) do
    out[#out + 1] = findKey(r, r.props.key .. ".title").props.text
  end
  return table.concat(out, ",")
end
local all = recents(12)
t = build(snap({ recent = all }), uiState({ mode = "search", query = "demo-1" }))
eq("views: search reaches past load more", titlesOf(t, "row.rec."), "demo-1,demo-10,demo-11,demo-12")
check("views: no load more when every match fits", findKey(t, "btn.more") == nil)
t = build(snap({ recent = all }), uiState({ mode = "search", query = "demo" }))
eq("views: search shows the first `shown` matches", titlesOf(t, "row.rec."), "demo-1,demo-2,demo-3,demo-4,demo-5")
check("views: load more for the rest of the matches", findKey(t, "btn.more") ~= nil)
t = build(snap({ recent = all }), uiState({ mode = "search", query = "demo", shown = 15 }))
eq("views: load more reveals more matches", #rows(t, "row.rec."), 12)
check("views: no load more once every match shows", findKey(t, "btn.more") == nil)
t = build(snap({ recent = all }), uiState({ mode = "search", query = "DEMO-12" }))
eq("views: search ignores case", titlesOf(t, "row.rec."), "demo-12")
t = build(snap({ recent = all }), uiState({ mode = "search", query = "  demo-12   " }))
eq("views: search trims spaces", titlesOf(t, "row.rec."), "demo-12")
t = build(snap({ recent = all }), uiState({ mode = "search", query = "demo.1" }))
eq("views: search is plain text, not a pattern", #rows(t, "row.rec."), 0)
t = build(snap({ recent = all }), uiState({ mode = "search", query = "projects" }))
eq("views: search skips the path", #rows(t, "row.rec."), 0)
check("views: no match line", findText(t, "panel.no_match") ~= nil)
check("views: no match hides empty text", findText(t, "panel.empty") == nil)
t = build(snap({ recent = all, pinned = { entry("pinned-api", { pinned = true }), entry("web", { pinned = true }) } }),
  uiState({ mode = "search", query = "api" }))
eq("views: search filters pinned too", titlesOf(t, "row.pin."), "pinned-api")
check("views: recent section gone with no recent match", findKey(t, "sec.recent") == nil)
check("views: a pinned match is not a no match", findText(t, "panel.no_match") == nil)
t = build(snap({ recent = all }), uiState({ mode = "search", query = "   " }))
eq("views: blank query lists as usual", #rows(t, "row.rec."), 5)
check("views: blank query keeps load more", findKey(t, "btn.more") ~= nil)
t = build(snap({ recent = all }), uiState({ query = "demo-12" }))
eq("views: query ignored when search is closed", #rows(t, "row.rec."), 5)
local titled = entry("x", { title = nil })
t = build(snap({ recent = { titled } }), uiState({ mode = "search", query = "x" }))
eq("views: untitled row falls back to its path", #rows(t, "row.rec."), 1)
eq("views: git keys follow the search", #view.gitKeys(snap({ recent = all }), uiState({ mode = "search", query = "demo-1" })), 4)
eq("views: git keys follow the search limit", #view.gitKeys(snap({ recent = all }), uiState({ mode = "search", query = "demo" })), 5)

-- ── views: inline row actions ────────────────────────────────────────────────

local function actionIds(tree, k)
  local out = {}
  local list = findKey(tree, k .. ".actions")
  if list == nil then return nil end
  for _, b in ipairs(list.children) do out[#out + 1] = (b.props.key or ""):sub(#k + 6) end
  return table.concat(out, ",")
end
t = build(snap())
eq("views: collapsed row shows no actions", actionIds(t, "row.rec." .. key1), nil)
eq("views: collapsed rows show no action buttons", #collect(t, function(n) return (n.props.key or ""):find("%.act%.") ~= nil end), 0)
t = build(snap(), uiState({ expandedKey = key1 }))
eq("views: expanded local row actions", actionIds(t, "row.rec." .. key1), "pin,open_terminal,open_files,copy_path,hide")
eq("views: only the expanded row has actions", #collect(t, function(n) return (n.props.key or ""):match("%.actions$") ~= nil end), 1)
local actBtn = findKey(t, "row.rec." .. key1 .. ".act.open_terminal")
eq("views: action buttons are ghost", actBtn.props.variant, "ghost")
actBtn.props.onClick()
eq("views: action button calls h.action", calls[1] and calls[1][1], "action")
eq("views: action id", calls[1] and calls[1][2], "open_terminal")
eq("views: action key", calls[1] and calls[1][3], key1)
t = build(snap({ recent = { remote } }), uiState({ expandedKey = remote.key }))
eq("views: expanded remote row actions", actionIds(t, "row.rec." .. remote.key), "pin,copy_path,hide")
t = build(snap({ pinned = { entry("demo-1", { pinned = true }) }, recent = {} }), uiState({ expandedKey = key1 }))
eq("views: expanded pinned row offers unpin", actionIds(t, "row.pin." .. key1), "unpin,open_terminal,open_files,copy_path,hide")
-- the row node keeps its parent whether expanded or not
local wrapC = findKey(build(snap()), "row.rec." .. key1 .. ".wrap")
local wrapE = findKey(build(snap(), uiState({ expandedKey = key1 })), "row.rec." .. key1 .. ".wrap")
eq("views: collapsed wrap holds the row", wrapC and wrapC.children[1].props.key, "row.rec." .. key1)
eq("views: expanded wrap holds the row first", wrapE and wrapE.children[1].props.key, "row.rec." .. key1)
-- a missing row's click expands its actions instead of opening
t = build(snap({ pinned = { gone }, recent = {} }))
findKey(t, "row.pin." .. key1).props.onClick()
eq("views: missing row click toggles actions", calls[1] and calls[1][1], "toggleActions")
eq("views: missing row click does not open", #calls, 1)

_G.ui = previousUi

-- ── panel: clone input settles on the service's answer ───────────────────────

do
  local fake = stubs.newNoctalia()
  fake.config = { recent_count = 5 }
  fake.install()
  local savedUi = _G.ui
  _G.ui = stubs.ui
  local rendered, closed = nil, 0
  _G.panel = {
    render = function(tree) rendered = tree end,
    close = function() closed = closed + 1 end,
    openContextMenu = function() return true end,
  }
  loadFresh("panel.luau")
  local cloneUrl = "https://example.com/acme/demo-api.git"
  local base = { seq = 1, requestSeq = 0, serviceBootId = "b", flavor = { id = "code", name = "VS Code" },
    loading = false, pinned = {}, recent = {}, git = {}, hasGit = true, hasPicker = true, clone = { state = "idle" } }
  local function publish(over)
    local s = {}
    for k, v in pairs(base) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    fake.noctalia.state.set("vscode.state", s)
  end
  publish()
  onOpen()
  local function input() return collect(rendered, function(n) return n.type == "input" end)[1] end
  check("panel: opens with no text field", input() == nil)
  findKey(rendered, "btn.add").props.onClick()
  check("panel: + shows the path box", findKey(rendered, "box.path") ~= nil)
  local opened = input().props.key
  input().props.onChange(cloneUrl)
  input().props.onSubmit(cloneUrl)
  eq("panel: clone sends the request", fake.state["vscode.request"].action, "clone")
  local seqAfter = fake.state["vscode.request"].requestId
  eq("panel: clone keeps the box until answered", input().props.key, opened)
  publish({ requestSeq = 2, lastError = { key = "error.busy_clone" } })
  eq("panel: refused clone keeps the text", input().props.key, opened)
  eq("panel: refused clone keeps the button", findKey(rendered, "btn.go").props.text, "panel.clone")
  input().props.onSubmit(cloneUrl)
  publish({ requestSeq = 3, clone = { state = "running", name = "demo-api", dest = "/x" } })
  check("panel: accepted clone clears the box", input().props.key ~= opened)
  check("panel: request ids increase", fake.state["vscode.request"].requestId > seqAfter)
  -- pick_folder closes the panel
  publish({ requestSeq = 3 })
  findKey(rendered, "btn.pick").props.onClick()
  eq("panel: pick folder sends", fake.state["vscode.request"].action, "pick_folder")
  eq("panel: pick folder closes the panel", closed, 1)
  -- Open existing: open_path, then dismiss_error once it worked
  onOpen()
  publish({ requestSeq = 5, clone = { state = "exists", name = "demo-api", dest = "/home/user/Projects/demo-api" } })
  findKey(rendered, "btn.open_existing").props.onClick()
  eq("panel: open existing sends open_path", fake.state["vscode.request"].action, "open_path")
  publish({ requestSeq = 7, clone = { state = "exists", name = "demo-api", dest = "/home/user/Projects/demo-api" } })
  eq("panel: open existing then dismisses", fake.state["vscode.request"].action, "dismiss_error")
  eq("panel: open existing closes", closed, 2)
  -- search: + and search swap; closing clears the query; reopening resets both
  publish({ requestSeq = 8, recent = { entry("demo-1"), entry("web") } })
  onOpen()
  findKey(rendered, "btn.add").props.onClick()
  input().props.onChange("/tmp")
  findKey(rendered, "btn.search").props.onClick()
  check("panel: search replaces the path box", findKey(rendered, "box.path") == nil and findKey(rendered, "box.search") ~= nil)
  local searchKey = input().props.key
  input().props.onChange("WEB ")
  eq("panel: query filters the list", #rows(rendered, "row.rec."), 1)
  eq("panel: typing keeps the search field mounted", input().props.key, searchKey)
  -- search shares the list's limit: recent_count plus 10 per Load more, either side
  publish({ requestSeq = 8, recent = recents(40) })
  input().props.onChange("demo")
  eq("panel: search shows recent_count matches", #rows(rendered, "row.rec."), 5)
  findKey(rendered, "btn.more").props.onClick()
  eq("panel: load more adds matches", #rows(rendered, "row.rec."), 15)
  input().props.onChange("demo-")
  eq("panel: a new query keeps the limit", #rows(rendered, "row.rec."), 15)
  findKey(rendered, "btn.search_close").props.onClick()
  eq("panel: closing search keeps the limit", #rows(rendered, "row.rec."), 15)
  findKey(rendered, "btn.more").props.onClick()
  findKey(rendered, "btn.search").props.onClick()
  input().props.onChange("demo")
  eq("panel: load more on the list carries into search", #rows(rendered, "row.rec."), 25)
  onOpen()
  findKey(rendered, "btn.search").props.onClick()
  input().props.onChange("demo")
  eq("panel: reopening resets the limit", #rows(rendered, "row.rec."), 5)
  findKey(rendered, "btn.search_close").props.onClick()
  publish({ requestSeq = 8, recent = { entry("demo-1"), entry("web") } })
  findKey(rendered, "btn.search").props.onClick()
  input().props.onChange("WEB ")
  findKey(rendered, "btn.search_close").props.onClick()
  check("panel: x closes search", findKey(rendered, "box.search") == nil)
  eq("panel: closing search clears the filter", #rows(rendered, "row.rec."), 2)
  findKey(rendered, "btn.search").props.onClick()
  check("panel: reopened search starts empty", input().props.key ~= searchKey)
  eq("panel: reopened search lists everything", #rows(rendered, "row.rec."), 2)
  findKey(rendered, "btn.add").props.onClick()
  eq("panel: leaving the path box cleared it", input().props.value, "")
  input().props.onChange("we")
  findKey(rendered, "btn.search").props.onClick()
  input().props.onChange("web")
  onOpen()
  check("panel: open starts with both closed", input() == nil)
  eq("panel: open drops the filter", #rows(rendered, "row.rec."), 2)
  -- left click on ⋮ expands; a second click collapses
  publish({ requestSeq = 8, recent = { entry("demo-1") } })
  onOpen()
  findKey(rendered, "row.rec." .. key1 .. ".menu").props.onClick()
  check("panel: menu click expands actions", findKey(rendered, "row.rec." .. key1 .. ".actions") ~= nil)
  findKey(rendered, "row.rec." .. key1 .. ".act.hide").props.onClick()
  eq("panel: inline action sends", fake.state["vscode.request"].action, "hide")
  check("panel: inline action collapses", findKey(rendered, "row.rec." .. key1 .. ".actions") == nil)
  findKey(rendered, "row.rec." .. key1 .. ".menu").props.onClick()
  onOpen()
  check("panel: open collapses actions", findKey(rendered, "row.rec." .. key1 .. ".actions") == nil)
  _G.panel = nil
  _G.ui = savedUi
  fake.uninstall()
end

-- view_launcher.results. Pure; fuzzy is a substring fake (earlier match, higher score).
do
  local vl = loadModule("view_launcher.luau")
  local function fuzzy(q, text)
    local i = string.find(string.lower(text), string.lower(q), 1, true)
    if i == nil then return nil end
    return 100 - i
  end
  local function lentry(name, over)
    local e = entry(name, over)
    return e
  end
  local function titles(res)
    local t = {}
    for i, r in ipairs(res) do t[i] = r.title end
    return table.concat(t, ",")
  end

  local s = snap({ pinned = { lentry("pin-a", { pinned = true }) }, recent = { lentry("r1"), lentry("r2") } })
  local res = vl.results(s, "", fuzzy, tr)
  eq("launcher: pins then recents", titles(res), "pin-a,r1,r2")
  eq("launcher: id is entry key", res[2].id, "file:///home/user/projects/r1")
  eq("launcher: glyph without icon path", res[1].glyph, "brand-vscode")
  eq("launcher: pinned badge", res[1].badge, "launcher.pinned")
  eq("launcher: recent has no badge", res[2].badge, nil)

  local withIcon = snap({ flavor = { id = "code", name = "VS Code", iconPath = "/usr/share/icons/code.png" }, recent = { lentry("r1") } })
  res = vl.results(withIcon, "", fuzzy, tr)
  eq("launcher: flavor icon path", res[1].icon, "/usr/share/icons/code.png")
  eq("launcher: no glyph when icon", res[1].glyph, nil)

  local many = snap({ pinned = { lentry("p1", { pinned = true }) }, recent = recents(80) })
  res = vl.results(many, "", fuzzy, tr)
  eq("launcher: capped at 50", #res, 50)
  eq("launcher: cap keeps pin first", res[1].title, "p1")

  -- name match beats a path-only match, even when the path match scores higher
  local m = snap({ recent = {
    lentry("zzz", { path = "/home/user/api/zzz" }),
    lentry("demo-api"),
  } })
  res = vl.results(m, "api", fuzzy, tr)
  eq("launcher: name match before path-only", titles(res), "demo-api,zzz")
  eq("launcher: non-matching dropped", #vl.results(m, "nomatch", fuzzy, tr), 0)

  res = vl.results(snap({ flavor = false }), "", fuzzy, tr)
  eq("launcher: no flavor one row", #res, 1)
  eq("launcher: no flavor text", res[1].title, "launcher.no_flavor")
  eq("launcher: info id empty", res[1].id, "")
  res = vl.results(snap({ recent = {} }), "", fuzzy, tr)
  eq("launcher: empty text", res[1].title, "launcher.empty")
  eq("launcher: empty info id", res[1].id, "")
  res = vl.results(snap({ recent = {}, loading = true }), "", fuzzy, tr)
  eq("launcher: loading text", res[1].title, "launcher.loading")

  local missing = snap({ pinned = { lentry("gone", { pinned = true, missing = true }) }, recent = {} })
  res = vl.results(missing, "", fuzzy, tr)
  eq("launcher: missing pinned still listed", titles(res), "gone")
end
