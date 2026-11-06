-- launcher.luau and panel.luau as thin clients, on the fake noctalia plus fake
-- `launcher` / `panel` globals. All paths are made up.
local function newFake()
  local fake = stubs.newNoctalia()
  fake.config = {}
  fake.install()
  local n = _G.noctalia
  n.string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end }
  n.fuzzyScore = function(q, t)
    if t:find(q, 1, true) then return 1 end
    return nil
  end
  return fake
end

local function entry(name, extra)
  local e = { key = "file:///home/user/" .. name, title = name, subtitle = "~/" .. name, path = "/home/user/" .. name }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

-- launcher
do
  local fake = newFake()
  local prevLauncher = _G.launcher
  local published = {}
  _G.launcher = { setResults = function(q, r) published[#published + 1] = { q = q, r = r } end }
  local snap = { flavor = { id = "code" }, pinned = { entry("gone", { pinned = true, missing = true }) }, recent = { entry("api") } }
  fake.state["vscode.state"] = snap
  loadFresh("launcher.luau")

  _G.onQuery("a")
  eq("launcher: query publishes", #published, 1)
  fake.noctalia.state.set("vscode.state", snap)
  eq("launcher: snapshot right after a query re-publishes", #published, 2)
  fake.advance(6000)
  fake.noctalia.state.set("vscode.state", snap)
  eq("launcher: snapshot long after the last query does not re-run matching", #published, 2)
  _G.onQuery("o")
  eq("launcher: a new query publishes again", #published, 3)
  eq("launcher: missing row carries the Missing badge", published[3].r[1].badge, "launcher.missing")

  local before = fake.state["vscode.request"]
  _G.onActivate("file:///home/user/gone")
  check("launcher: Enter on a missing entry sends nothing", fake.state["vscode.request"] == before)
  _G.onActivate("file:///home/user/api")
  eq("launcher: Enter on a present entry opens it", fake.state["vscode.request"].key, "file:///home/user/api")
  fake.uninstall()
  _G.launcher = prevLauncher
end

-- panel: the "Clones into" folder follows a settings change while open
do
  local fake = newFake()
  local prevPanel, prevUi = _G.panel, _G.ui
  _G.ui = stubs.ui
  _G.panel = { render = function() end, close = function() end }
  local vp = loadModule("view_panel.luau")
  local realBuild = vp.build
  local seen = {}
  vp.build = function(snapshot, ui_state, tr, handlers)
    seen[#seen + 1] = ui_state.cloneDir
    return realBuild(snapshot, ui_state, tr, handlers)
  end
  fake.config = { clone_dir = "/home/user/one" }
  loadFresh("panel.luau")
  _G.onOpen({})
  eq("panel: cloneDir read on open", seen[#seen], "/home/user/one")
  fake.config.clone_dir = "/home/user/two"
  fake.noctalia.state.set("vscode.state", { serviceBootId = "b", requestSeq = 0, pinned = {}, recent = {}, flavor = { id = "code" } })
  eq("panel: cloneDir refreshed on render", seen[#seen], "/home/user/two")
  vp.build = realBuild
  fake.uninstall()
  _G.panel, _G.ui = prevPanel, prevUi
end

-- panel: a finished clone's banner is cleared when the panel is opened again
do
  local fake = newFake()
  local prevPanel, prevUi = _G.panel, _G.ui
  _G.ui = stubs.ui
  _G.panel = { render = function() end, close = function() end }
  local vp = loadModule("view_panel.luau")
  local realBuild = vp.build
  local lastClone
  vp.build = function(snapshot, ui_state, tr, handlers)
    lastClone = snapshot and snapshot.clone and snapshot.clone.state
    return realBuild(snapshot, ui_state, tr, handlers)
  end
  local function snapWith(state)
    return { serviceBootId = "b", requestSeq = 0, pinned = {}, recent = {}, flavor = { id = "code" }, clone = { state = state, name = "repo" } }
  end
  for _, st in ipairs({ "done", "cancelled" }) do
    fake.state["vscode.state"] = snapWith(st)
    loadFresh("panel.luau")
    _G.onOpen({})
    eq("panel: open clears a " .. st .. " clone (request)", fake.state["vscode.request"] and fake.state["vscode.request"].action, "clear_clone")
    eq("panel: open hides a " .. st .. " clone at once", lastClone, "idle")
  end
  for _, st in ipairs({ "running", "failed", "exists" }) do
    fake.state["vscode.state"] = snapWith(st)
    loadFresh("panel.luau")
    _G.onOpen({})
    eq("panel: open keeps a " .. st .. " clone", lastClone, st)
  end
  vp.build = realBuild
  fake.uninstall()
  _G.panel, _G.ui = prevPanel, prevUi
end
