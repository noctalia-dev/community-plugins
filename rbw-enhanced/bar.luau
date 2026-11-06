--!nonstrict
-- rbw-enhanced bar widget — the [[widget]] entry.
--
-- A lock glyph colored by the vault state. Left click opens the panel, right
-- click opens `rbw tui` (or `rbw login` when the login expired).

local snapshot = nil

local LOOK = {
  unlocked = { glyph = "lock-open", color = "primary" },
  locked = { glyph = "lock", color = "on_surface/0.7" },
  stopped = { glyph = "lock", color = "on_surface/0.5" },
  expired = { glyph = "lock-exclamation", color = "error" },
  ["logged-out"] = { glyph = "lock-off", color = "error" },
  ["not-installed"] = { glyph = "lock-off", color = "outline_variant" },
  error = { glyph = "alert-triangle", color = "error" },
}

-- each entry is its own VM, so a per-entry counter could repeat another
-- entry's value; the time plus a random part can't
local function sendCmd(action)
  noctalia.state.set("rbw.cmd", noctalia.json.encode({
    n = `{noctalia.nowMs()}-{math.random(1, 1e9)}`,
    action = action,
  }))
end

local function stateOf()
  return snapshot and snapshot.state or "stopped"
end

local function render()
  local state = stateOf()
  local look = LOOK[state] or LOOK.error
  barWidget.setVisible(not (state == "unlocked" and noctalia.getConfig("hide_when_unlocked") == true))
  barWidget.render(ui.glyph({ name = look.glyph, color = look.color }))

  local rows = { { key = "rbw-enhanced", value = noctalia.tr(`state.{state}`) } }
  if snapshot and snapshot.lastSync then
    table.insert(rows, {
      key = noctalia.tr("tooltip.synced"),
      value = noctalia.formatTime("%H:%M", snapshot.lastSync),
    })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("rbw.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel("rylos/rbw-enhanced:panel")
end

function onRightClick()
  local state = stateOf()
  if state == "expired" or state == "logged-out" then
    sendCmd("login")
  elseif state ~= "not-installed" then
    -- the tui unlocks a locked vault itself
    sendCmd("tui")
  end
end
