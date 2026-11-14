-- bar.luau (the widget shell) on the noctalia stub: it draws model.barView of the snapshot.
local previousUi, previousBar = _G.ui, _G.barWidget
_G.ui = stubs.ui
local rendered, tooltip

local function bootBar(state)
  local fake = stubs.newNoctalia()
  fake.state["ufw.state"] = state
  fake.install()
  rendered, tooltip = nil, nil
  _G.barWidget = {
    render = function(t) rendered = t end,
    setTooltip = function(text) tooltip = text end,
  }
  loadFresh("bar.luau")
  return fake
end

local function dot()
  return rendered and rendered.children[1] and rendered.children[1].props.fill
end

local ON = {
  installed = true, hasSystemctl = true, source = "files", enabled = true,
  unit = { active = "active", bootEnabled = true }, defaults = { input = "DROP", ipv6 = true },
  rules = {}, pending = {}, busy = false, testMode = false,
}

-- loaded after the service: the last published snapshot is drawn at once
local fake = bootBar(ON)
eq("bar: draws the published snapshot at load", dot(), "#22c55e")
eq("bar: tooltip of the published snapshot", tooltip, "tooltip.on_other")
eq("bar: still asks for a fresh snapshot", fake.state["ufw.request"] and fake.state["ufw.request"].action, "refresh")
fake.noctalia.state.set("ufw.state", { installed = true, hasSystemctl = true, enabled = false, unit = {}, rules = {} })
eq("bar: follows a new snapshot", dot(), "error")
fake.uninstall()

-- loaded before the service published anything
fake = bootBar(nil)
eq("bar: nothing published yet is muted", dot(), "on_surface_variant")
eq("bar: nothing published yet says loading", tooltip, "tooltip.loading")
fake.uninstall()

-- a stale non-table value is ignored
fake = bootBar("junk")
eq("bar: ignores a non-table state", tooltip, "tooltip.loading")
fake.uninstall()

_G.ui, _G.barWidget = previousUi, previousBar
