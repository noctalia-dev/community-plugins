-- API 32 contract checks; no real host, profile, network or processes.
dofile("tests/test_runtime.lua")
local color = require("./ui/palette.luau")
local host = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      assert(props.clip == nil, "API 52 clip must never reach the host")
      return { type = kind, props = props, children = children or {} }
    end
  end,
})
local old = { surface_variant = "#123456", outline = "#abcdef" }
local new =
  { surface_container = "#223344", surface_container_high = "#445566", outline_variant = "#ddeeff" }
noctalia = {}
assert(color("card") == "surface")
assert(color("muted_border", 0.5) == "on_surface_variant/0.5")
for _, palette in ipairs({ old, new }) do
  noctalia = {
    getColor = function(role)
      return palette[role]
    end,
  }
  assert(color("card", 0.5) == (palette.surface_container or palette.surface_variant) .. "80")
  assert(color("muted_border", 0.35) == (palette.outline_variant or palette.outline) .. "59")
  assert(color("card", 0):sub(-2) == "00")
  assert(color("card", 1):sub(-2) == "ff")
  assert(color("raised") == (palette.surface_container_high or palette.surface_variant))
  -- Palette lookup is performed per construction, not frozen at module load.
  local token = palette.surface_container and "surface_container" or "surface_variant"
  palette[token] = "#010203"
  assert(color("card") == "#010203")
end
-- Exercise the complete real panel against a host that rejects new props and
-- raw adapter aliases. Navigation must not dispatch consequential commands.
local commands, tree, watcher = {}, nil, nil
_G.ui = host
panel = {
  render = function(node)
    tree = node
  end,
}
local fixture = {
  state = "ready",
  devices = {
    {
      id = "demo",
      name = string.rep("Phone 🦀", 100),
      online = true,
      battery = { level = 50 },
      ringing = false,
    },
  },
}
noctalia = {
  getColor = function(role)
    return old[role]
  end,
  getConfig = function()
    return nil
  end,
  json = {
    encode = function(v)
      return v
    end,
    decode = function(v)
      return v
    end,
  },
  state = {
    get = function()
      return fixture
    end,
    watch = function(_, cb)
      watcher = cb
    end,
    set = function(_, value)
      commands[#commands + 1] = value
    end,
  },
}
dofile("panel.luau")
assert(ui == host, "the plugin must use native constructors without replacing ui")
onOpen()
local function validate(node)
  assert(node.props.clip == nil)
  for _, key in ipairs({ "fill", "border", "color", "track" }) do
    local value = node.props[key]
    local role = type(value) == "string" and value:match("^[%w_]+") or nil
    assert(role ~= "card" and role ~= "raised" and role ~= "muted_border")
    assert(not value or not value:find("surface_container", 1, true))
  end
  if node.type == "label" then
    assert(node.props.maxWidth and node.props.maxWidth > 0 and node.props.maxWidth <= 1072)
    assert(node.props.maxLines and node.props.maxLines > 0)
  end
  for _, child in ipairs(node.children) do
    validate(child)
  end
end
for _, page in ipairs({ "home", "messages", "calls", "photos", "apps", "deck", "guide" }) do
  onNavigate(page)
  validate(tree)
  assert(tree.props.width == 1072 and tree.props.height == 528)
end
for _, command in ipairs(commands) do
  assert(command.action == "visible" or command.action == "page" or command.action == "page_leave")
end
onClose()
print(
  "PASS: old/new palette colors, alpha, theme refresh, native API 32 UI and explicit text bounds"
)
