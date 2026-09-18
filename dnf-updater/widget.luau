--!nonstrict
-- Bar widget entry: displays pending update badge and status in Noctalia bar.

local glyph = noctalia.getConfig("glyph") or "package"
local showWhenClean = noctalia.getConfig("show_widget_when_clean") ~= false

local updateState = noctalia.state.get("update_state")

local function render()
  glyph = noctalia.getConfig("glyph") or "package"
  showWhenClean = noctalia.getConfig("show_widget_when_clean") ~= false

  if not updateState then
    barWidget.setGlyph(glyph)
    barWidget.setText("…")
    barWidget.setTooltip(noctalia.tr("status.checking"))
    barWidget.setVisible(true)
    return
  end

  local status = updateState.status or "IDLE"
  local total = updateState.total_count or 0

  if status == "CHECKING" and total == 0 then
    barWidget.setGlyph(glyph)
    barWidget.setText("…")
    barWidget.setTooltip(noctalia.tr("status.checking"))
    barWidget.setVisible(true)
  elseif status == "UPDATING" then
    barWidget.setGlyph("refresh")
    barWidget.setText(total > 0 and tostring(total) or "…")
    barWidget.setTooltip(noctalia.tr("status.updating"))
    barWidget.setVisible(true)
  elseif status == "ERROR" and total == 0 then
    barWidget.setGlyph("alert-circle")
    barWidget.setText("!")
    barWidget.setTooltip(updateState.error_message or noctalia.tr("status.dnf_error"))
    barWidget.setVisible(true)
  elseif total > 0 then
    barWidget.setGlyph(glyph)
    barWidget.setText(tostring(total))
    local tooltipEntries = {
      { key = noctalia.tr("summary.dnf"), value = tostring(updateState.dnf and updateState.dnf.count or 0) },
      { key = noctalia.tr("summary.flatpak"), value = tostring(updateState.flatpak and updateState.flatpak.count or 0) },
      { key = noctalia.tr("summary.total"), value = tostring(total) },
    }
    if updateState.total_download_formatted and updateState.total_download_formatted ~= "0 B" then
      table.insert(tooltipEntries, { key = noctalia.tr("tooltip.download_size"), value = updateState.total_download_formatted })
    end
    table.insert(tooltipEntries, { key = "Last checked", value = updateState.last_check or "–" })
    barWidget.setTooltip(tooltipEntries)
    barWidget.setVisible(true)
  else
    -- Total == 0 (all up to date)
    if showWhenClean then
      barWidget.setVisible(true)
      barWidget.setGlyph(glyph)
      barWidget.setText("")
      local tooltipText = noctalia.tr("tooltip.all_up_to_date")
      if updateState.last_check then
        tooltipText = tooltipText .. " (" .. updateState.last_check .. ")"
      end
      barWidget.setTooltip(tooltipText)
    else
      barWidget.setVisible(false)
    end
  end
end

-- Live updates from background service
noctalia.state.watch("update_state", function(newState)
  updateState = newState
  render()
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel("strob3/dnf-updater:panel")
end

function onRightClick()
  noctalia.state.set("service_command", { action = "check_now", ts = os.time() })
end

function onMiddleClick()
  noctalia.openSettings()
end

render()
