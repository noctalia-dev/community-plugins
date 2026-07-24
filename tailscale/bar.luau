--!nonstrict
-- Tailscale bar widget — the [[widget]] entry.
--
-- State-colored glyph, plus (optionally) the online peer count and this
-- node's Tailscale IP. Left click opens the panel, right click toggles the
-- connection up/down.

local snapshot = nil
local cmdNonce = 0

-- Real Tailscale logo, shipped with the plugin: light fill for dark themes,
-- dark fill for light themes. Problem states add a small colored glyph overlay
-- since the image itself cannot be tinted.
local function logo(state)
  return ui.image({
    path = noctalia.isDarkMode() and "icon.svg" or "icon-light.svg",
    width = 16,
    height = 16,
    fit = "contain",
    opacity = state == "running" and 1 or 0.45,
  })
end

local BADGES = {
  ["needs-login"] = { glyph = "lock-exclamation", color = "error" },
  ["error"] = { glyph = "alert-triangle", color = "error" },
  ["not-installed"] = { glyph = "x", color = "outline" },
}

local COLORS = {
  ["running"] = "primary",
  ["stopped"] = "outline",
  ["needs-login"] = "error",
  ["not-installed"] = "outline",
  ["error"] = "error",
}

local function sendCmd(action)
  cmdNonce += 1
  noctalia.state.set("ts.cmd", noctalia.json.encode({ n = cmdNonce, action = action }))
end

local function stateOf()
  return snapshot and snapshot.state or "stopped"
end

local function render()
  local state = stateOf()
  local color = COLORS[state] or "outline"
  local children = { logo(state) }
  local badge = BADGES[state]
  if badge then
    table.insert(children, ui.glyph({ name = badge.glyph, size = 11, color = badge.color }))
  end

  if state == "running" and snapshot and not barWidget.isVertical() then
    if noctalia.getConfig("show_count") ~= false then
      table.insert(children, ui.label({
        text = `{snapshot.online}/{snapshot.total}`,
        fontWeight = "bold",
        color = color,
      }))
    end
    if noctalia.getConfig("show_ip") == true and snapshot.self.ip ~= "" then
      table.insert(children, ui.label({ text = snapshot.self.ip, color = "on_surface/0.7" }))
    end
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  local rows = { { key = noctalia.tr("tooltip.state"), value = noctalia.tr(`state.{state}`) } }
  if snapshot and state == "running" then
    table.insert(rows, { key = noctalia.tr("tooltip.self"), value = `{snapshot.self.name} ({snapshot.self.ip})` })
    table.insert(rows, { key = noctalia.tr("tooltip.online"), value = `{snapshot.online}/{snapshot.total}` })
    if snapshot.exitNode then
      table.insert(rows, { key = noctalia.tr("tooltip.exit-node"), value = snapshot.exitNode.name })
    end
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("ts.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function update()
  noctalia.setUpdateInterval(2000)
  render()
end

function onClick()
  noctalia.togglePanel("rylos/tailscale:panel")
end

function onRightClick()
  local state = stateOf()
  if state == "running" then
    sendCmd("down")
  elseif state == "stopped" then
    sendCmd("up")
  end
end

function onIpc(event)
  if event == "refresh" then
    sendCmd("refresh")
  end
end
