--!nonstrict
-- Bangumi Progress bar widget: icon and newly available unwatched episode count.

local PANEL_ID = "mirei124/bangumi-progress:library"

local snapshot = noctalia.state.get("bgm_snapshot") or {}
local open = false

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function tr(key, subst)
  return noctalia.tr("bar." .. key, subst)
end

local function watchingCount()
  for _, c in ipairs(snapshot.collections or {}) do
    if c.type == 3 then
      return #c.rows
    end
  end
  return 0
end

local function render()
  local glyph = noctalia.getConfig("glyph") or "device-tv"
  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(if open then "primary" else "on_surface")

  if snapshot.loading and not snapshot.viewer then
    barWidget.setText("")
    barWidget.setTooltip(tr("tooltip_loading"))
    return
  end

  if snapshot.error and snapshot.error ~= "" and not snapshot.viewer then
    barWidget.setText("")
    local message = snapshot.error
    if message == "not_configured" then
      message = tr("tooltip_not_configured")
    elseif message == "unauthorized" then
      message = tr("tooltip_unauthorized")
    elseif message == "network" then
      message = tr("tooltip_network")
    end
    barWidget.setTooltip(message)
    return
  end

  local count = watchingCount()
  local unwatched = snapshot.unwatched
  if type(unwatched) == "number" then
    barWidget.setText(tostring(unwatched))
    if unwatched > 0 then
      barWidget.setTooltip(tr("tooltip_unwatched", { count = unwatched, series = count }))
    else
      barWidget.setTooltip(tr("tooltip_all_caught_up", { series = count }))
    end
    return
  end
  if count > 0 then
    -- Use the watching count as a placeholder while unwatched episodes are being calculated.
    barWidget.setText(tostring(count))
    barWidget.setTooltip(tr("tooltip_counting"))
  else
    barWidget.setText("")
    barWidget.setTooltip(tr("tooltip_empty"))
  end
end

noctalia.state.watch("bgm_open", function(value)
  open = value == true
  render()
end)

noctalia.state.watch("bgm_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  local username = snapshot.viewer and snapshot.viewer.username
  if username and username ~= "" then
    noctalia.runAsync("xdg-open " .. shellQuote("https://bgm.tv/user/" .. username) .. " >/dev/null 2>&1")
  else
    noctalia.openSettings()
  end
end

render()

-- The host invokes entry points by name; this reference suppresses static-analysis unused warnings.
local _ = { update, onClick, onRightClick }
