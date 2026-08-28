--!nonstrict
-- Mihomo Control — control-center shortcut.
--
-- Quick toggle for the proxy mode: clicking switches between rule and global.
-- The tile shows the current mode and lights up while global mode is active.

local function current_mode()
  local config = noctalia.state.get("mihomo.config") or {}
  return config.mode or "rule"
end

local function render()
  local mode = current_mode()
  shortcut.setLabel(noctalia.tr("shortcut.label", { mode = noctalia.tr("shortcut.mode_" .. mode) }))
  shortcut.setIcon("cat")
  shortcut.setActive(mode == "global")
  shortcut.setEnabled(true)
end

noctalia.state.watch("mihomo.config", function(_value)
  render()
end)

function onClick()
  local next_mode = current_mode() == "global" and "rule" or "global"
  noctalia.state.set("mihomo.command", {
    op = "mode",
    mode = next_mode,
    seq = math.floor(os.clock() * 1000000),
  })
end

render()
