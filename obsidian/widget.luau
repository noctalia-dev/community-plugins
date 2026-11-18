--!nonstrict

local PANEL_ID = "davemhammer/obsidian:manager"
local STATE_KEY = "obs_snapshot"
local COMMAND_KEY = "obs_command"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  git = { dirty = 0, isRepo = false },
  vaultName = "",
  dailyExists = false,
}

local requestId = 0

local function render()
  local available = snapshot.available == true
  local dirty = 0
  if type(snapshot.git) == "table" then
    dirty = tonumber(snapshot.git.dirty) or 0
  end
  local showDirty = noctalia.getConfig("show_dirty") ~= false
  local icon = available and "assets/obsidian-purple.png" or "assets/obsidian-grey.png"
  if available and dirty > 0 then
    icon = "assets/obsidian-green.png" -- has local changes to sync
  end

  local children = {
    ui.image({
      path = icon,
      width = 16,
      height = 16,
      fit = "contain",
    }),
  }

  if showDirty and available and dirty > 0 then
    table.insert(children, ui.label({
      text = tostring(dirty),
      fontWeight = "bold",
      color = "on_surface",
    }))
  end

  if available then
    table.insert(children, ui.box({
      width = 7,
      height = 7,
      radius = 4,
      fill = dirty > 0 and "#73c936" or "#7C3AED",
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if not available then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_missing"))
  else
    local git = "—"
    if type(snapshot.git) == "table" then
      if not snapshot.git.isRepo then
        git = "no repo"
      elseif snapshot.git.clean then
        git = "clean"
      else
        git = tostring(dirty) .. " dirty"
      end
    end
    barWidget.setTooltip(noctalia.tr("widget.tooltip_ok", {
      vault = snapshot.vaultName ~= "" and snapshot.vaultName or "vault",
      daily = snapshot.dailyExists and "yes" or "new",
      git = git,
    }))
  end
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.setUpdateInterval(8000)
render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  -- Quick open today's daily note (service rejects missing/invalid vault)
  if snapshot.available ~= true then
    return
  end
  requestId += 1
  noctalia.state.set(COMMAND_KEY, { action = "open_daily", requestId = `widget-{requestId}` })
end
