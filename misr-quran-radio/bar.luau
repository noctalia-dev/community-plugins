--!nonstrict
-- Misr Quran Radio bar widget - live state at a glance.
--
-- The service owns playback and the schedule; this only renders the shared
-- "misr_quran.state" snapshot. Click opens the panel.

local snapshot = { available = false, playing = false }

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function render()
  if snapshot.available ~= true and snapshot.schedule_count == nil then
    -- Before the first snapshot lands, stay out of the bar.
    barWidget.setVisible(false)
    return
  end
  if snapshot.available == false then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  barWidget.setGlyph(noctalia.getConfig("glyph") or "radio")
  if snapshot.playing == true then
    barWidget.setColor("primary")
  else
    barWidget.setColor("on_surface")
  end

  if noctalia.getConfig("show_text") == true then
    if snapshot.playing == true then
      barWidget.setText(tr("bar.live"))
    else
      barWidget.setText(tr("bar.idle"))
    end
  else
    barWidget.setText("")
  end

  local rows = {}
  if snapshot.playing == true then
    table.insert(rows, { key = tr("tooltip.status"), value = tr("bar.live") })
  else
    table.insert(rows, { key = tr("tooltip.status"), value = tr("bar.idle") })
  end
  if snapshot.current ~= nil and type(snapshot.current.title) == "string" then
    local when = ""
    if type(snapshot.current.fromTime) == "string" then
      when = snapshot.current.fromTime
      if type(snapshot.current.toTime) == "string" then
        when = when .. " - " .. snapshot.current.toTime
      end
    end
    table.insert(rows, { key = tr("tooltip.now"), value = snapshot.current.title })
    if when ~= "" then
      table.insert(rows, { key = tr("tooltip.time"), value = when })
    end
  elseif (snapshot.schedule_count or 0) > 0 then
    table.insert(rows, { key = tr("tooltip.schedule"), value = tostring(snapshot.schedule_count) })
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(rows, { key = tr("tooltip.error"), value = snapshot.error })
  end
  table.insert(rows, { key = tr("tooltip.open"), value = "" })
  barWidget.setTooltip(rows)
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("muhammadessam/misr-quran-radio:panel")
end

noctalia.state.watch("misr_quran.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

-- state.watch does not replay an old value to a late-attaching entry, so ask
-- for a snapshot on load instead of rendering the default forever.
noctalia.state.set("misr_quran.request", { action = "refresh" })
