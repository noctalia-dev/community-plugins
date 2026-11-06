--!nonstrict
-- Workspace Restore bar widget: a layout glyph that opens the panel. The
-- tooltip says how many workspaces are ticked. Each poll also runs auto-add,
-- which does nothing unless a workspace has it switched on in the panel.
-- Every update also makes sure the watcher runs (wsr.py watch), which notes
-- saved workspace numbers that another workspace has taken.
-- Its first update starts the login restore of the ticked workspaces; wsr.py
-- --once makes sure that runs once per Hyprland session, not on every bar
-- start or on every monitor's bar.

local shared = require("./shared.luau")

local POLL_MS = 30000

local data = nil
local loginRestoreStarted = false

local function render()
  barWidget.setGlyph("layout-grid")
  barWidget.setText("")
  if data == nil then
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(noctalia.tr("ui.title"))
    return
  end
  local ticked, auto = 0, 0
  for _, ws in ipairs(data.workspaces or {}) do
    if ws.ticked then
      ticked = ticked + 1
    end
    if ws.auto_add then
      auto = auto + 1
    end
  end
  barWidget.setGlyphColor(ticked > 0 and "on_surface" or "on_surface_variant")
  barWidget.setTooltip(noctalia.tr("ui.title") .. "\n"
    .. noctalia.trp("ui.ticked-count", ticked) .. "\n"
    .. noctalia.trp("ui.auto-add-count", auto))
end

function update()
  noctalia.setUpdateInterval(POLL_MS)
  if not loginRestoreStarted then
    loginRestoreStarted = true
    shared.restore("--ticked --wait-monitors --once")
  end
  shared.watch()
  shared.run("auto-add", function(r)
    local added = r and r.added or {}
    if #added > 0 then
      local names = {}
      for _, a in ipairs(added) do
        names[#names + 1] = noctalia.tr("ui.added-one", { app = tostring(a.label or a.class), ws = shared.wsLabel(a.ws) })
      end
      noctalia.notify(noctalia.tr("ui.title"), table.concat(names, "\n"))
    end
    shared.status(function(d)
      data = d
      render()
    end)
  end)
end

function onClick()
  noctalia.togglePanel("soulmanyes/workspace-restore:panel")
end
