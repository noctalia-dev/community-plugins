--!nonstrict

local STATE = "tuxedo_control_center.profiles"
local COMMAND = "tuxedo_control_center.command"
local snap = noctalia.state.get(STATE) or { loading = true, profiles = {} }
local nonce = 0

local function send(action, id)
  nonce = nonce + 1
  noctalia.state.set(COMMAND, { action = action, id = id, nonce = noctalia.nowMs() * 1000 + nonce })
end

local function profileButton(profile)
  local id = profile.id
  local active = id == snap.activeId
  return ui.button({
    key = id,
    text = tostring(profile.name or profile.displayName or id),
    glyph = active and "circle-check" or "circle",
    variant = active and "primary" or "ghost",
    selected = active,
    contentAlign = "start",
    controlSize = "lg",
    tooltip = id,
    enabled = not snap.loading,
    onClick = function() send("set", id) end,
  })
end

local function render()
  local body = {}
  if snap.loading and #snap.profiles == 0 then
    body[#body + 1] = ui.label({ text = "Loading profiles…", color = "on_surface_variant" })
  elseif snap.error then
    body[#body + 1] = ui.label({ text = snap.error, color = "error", maxLines = 2 })
  elseif #snap.profiles == 0 then
    body[#body + 1] = ui.label({ text = "No TUXEDO profiles to display.", color = "on_surface_variant" })
  else
    for _, profile in ipairs(snap.profiles) do
      body[#body + 1] = profileButton(profile)
    end
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "cpu", size = 20, color = "primary" }),
      ui.label({ text = "TUXEDO Control Center", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Refresh profiles", onClick = function() send("refresh") end }),
      ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = "Plugin settings", onClick = noctalia.openSettings }),
    }),
    ui.label({ text = "Power Profile", fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    ui.scroll({ gap = 4, flexGrow = 1, align = "stretch" }, body),
  }))
end

function onOpen()
  snap = noctalia.state.get(STATE) or snap
  render()
  send("refresh")
end

noctalia.state.watch(STATE, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

render()
