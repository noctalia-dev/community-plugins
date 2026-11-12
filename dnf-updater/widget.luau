--!nonstrict
-- Bar widget entry: displays pending update badge and status in Noctalia bar.

local glyph = noctalia.getConfig("glyph") or "package"
local showWhenClean = noctalia.getConfig("show_widget_when_clean") ~= false

local updateState = noctalia.state.get("update_state")

local function formatAgo(timestamp)
  if not timestamp or timestamp <= 0 then
    return nil
  end
  local minutes = math.floor((os.time() - timestamp) / 60)
  if minutes < 1 then
    return noctalia.tr("ago.now") or "just now"
  elseif minutes < 60 then
    local s = noctalia.tr("ago.minutes") or "{n} min ago"
    return s:gsub("{n}", tostring(minutes))
  elseif minutes < 1440 then
    local s = noctalia.tr("ago.hours") or "{n} h ago"
    return s:gsub("{n}", tostring(math.floor(minutes / 60)))
  end
  local s = noctalia.tr("ago.days") or "{n} d ago"
  return s:gsub("{n}", tostring(math.floor(minutes / 1440)))
end

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
    local tooltipEntries = {}
    if updateState.reboot_required then
      table.insert(tooltipEntries, { key = noctalia.tr("summary.system"), value = noctalia.tr("status.reboot_required") })
    end
    table.insert(tooltipEntries, { key = noctalia.tr("summary.dnf"), value = tostring(updateState.dnf and updateState.dnf.count or 0) })
    table.insert(tooltipEntries, { key = noctalia.tr("summary.flatpak"), value = tostring(updateState.flatpak and updateState.flatpak.count or 0) })
    table.insert(tooltipEntries, { key = noctalia.tr("summary.total"), value = tostring(total) })
    if updateState.total_download_formatted and updateState.total_download_formatted ~= "0 B" then
      table.insert(tooltipEntries, { key = noctalia.tr("tooltip.download_size"), value = updateState.total_download_formatted })
    end
    if updateState.total_delta_formatted and updateState.total_delta_formatted ~= "" then
      table.insert(tooltipEntries, { key = noctalia.tr("tooltip.disk_delta"), value = updateState.total_delta_formatted })
    end
    table.insert(tooltipEntries, { key = noctalia.tr("summary.last_checked"), value = updateState.last_check or "–" })
    if updateState.last_update_timestamp and updateState.last_update_timestamp > 0 then
      local ago = formatAgo(updateState.last_update_timestamp)
      if ago then
        table.insert(tooltipEntries, { key = noctalia.tr("summary.last_update"), value = ago })
      end
    end
    barWidget.setTooltip(tooltipEntries)
    barWidget.setVisible(true)
  else
    -- Total == 0 (all up to date)
    if updateState.reboot_required then
      barWidget.setVisible(true)
      barWidget.setGlyph("rotate-cw")
      barWidget.setText("")
      barWidget.setTooltip(noctalia.tr("status.reboot_required"))
    elseif showWhenClean then
      barWidget.setVisible(true)
      barWidget.setGlyph(glyph)
      barWidget.setText("")
      local tooltipEntries = {
        { key = noctalia.tr("summary.system"), value = noctalia.tr("tooltip.all_up_to_date") },
      }
      if updateState.last_check then
        table.insert(tooltipEntries, { key = noctalia.tr("summary.last_checked"), value = updateState.last_check })
      end
      if updateState.last_update_timestamp and updateState.last_update_timestamp > 0 then
        local ago = formatAgo(updateState.last_update_timestamp)
        if ago then
          table.insert(tooltipEntries, { key = noctalia.tr("summary.last_update"), value = ago })
        end
      end
      barWidget.setTooltip(tooltipEntries)
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
