--!nonstrict
-- Tailscale desktop widget — a compact status card pinned to the desktop.
--
-- Logo + state, this node's IP, online/total peers, and the active exit
-- node. Pure display; open the panel for actions.

local snapshot = nil

local function render()
  local state = snapshot and snapshot.state or "stopped"
  local running = state == "running"
  local color = running and "primary" or (state == "stopped" and "outline" or "error")

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.image({
        path = noctalia.isDarkMode() and "icon.svg" or "icon-light.svg",
        width = 18,
        height = 18,
        fit = "contain",
        opacity = running and 1 or 0.5,
      }),
      ui.label({ text = "Tailscale", fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = noctalia.tr(`state.{state}`), fontSize = 11, color = color }),
    }),
  }

  if running and snapshot then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = snapshot.self.name, fontSize = 12, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = snapshot.self.ip, fontSize = 11, color = "on_surface/0.65" }),
    }))
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.label({
        text = `{noctalia.tr("tooltip.online")}: {snapshot.online}/{snapshot.total}`,
        fontSize = 11,
        color = "on_surface/0.7",
        flexGrow = 1,
      }),
      ui.label({
        text = snapshot.exitNode and `⇢ {snapshot.exitNode.name}` or "",
        fontSize = 11,
        color = "secondary",
        visible = snapshot.exitNode ~= nil,
      }),
    }))
  end

  desktopWidget.render(ui.column({ gap = 6, padding = 10, fill = "surface_variant/0.4", radius = 12 }, children))
end

noctalia.state.watch("ts.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function update()
  noctalia.setUpdateInterval(5000)
  render()
end
