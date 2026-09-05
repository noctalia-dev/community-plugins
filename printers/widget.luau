--!nonstrict
-- Printers bar widget: a printer glyph with the active job count. Hidden while
-- there is nothing to say, unless "show_when_idle" is on. Click opens the panel.

local status = { defaultPrinter = "", printerCount = 0, jobCount = 0, hasFault = false }

local function render()
  local showIdle = noctalia.getConfig("show_when_idle") == true
  local interesting = status.jobCount > 0 or status.hasFault
  barWidget.setVisible(showIdle or interesting)

  barWidget.setGlyph(status.hasFault and "printer-off" or "printer")
  barWidget.setText(status.jobCount > 0 and tostring(status.jobCount) or "")

  local role = if status.hasFault then "error" elseif status.jobCount > 0 then "primary" else "on_surface_variant"
  barWidget.setColor(role)
  barWidget.setGlyphColor(role)

  local rows = {}
  if status.defaultPrinter ~= "" then
    table.insert(rows, { key = noctalia.tr("tooltip.default"), value = status.defaultPrinter })
  end
  table.insert(rows, { key = noctalia.tr("tooltip.queue"), value = tostring(status.jobCount) })
  if status.hasFault then
    table.insert(rows, { key = noctalia.tr("tooltip.state"), value = noctalia.tr("tooltip.stopped") })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("printer.status", function(value)
  if type(value) == "table" then
    status = {
      defaultPrinter = type(value.defaultPrinter) == "string" and value.defaultPrinter or "",
      printerCount = tonumber(value.printerCount) or 0,
      jobCount = tonumber(value.jobCount) or 0,
      hasFault = value.hasFault == true,
    }
  end
  render()
end)

function onClick()
  noctalia.togglePanel("andrewdems/printers:panel")
end

function onRightClick()
  noctalia.state.set("printer.cmd", { op = "refresh" })
end

render()
