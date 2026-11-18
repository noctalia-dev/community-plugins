--!nonstrict
-- Printers control-center tile: opens the panel, and lights up while there are
-- jobs in the queue or a printer has stopped.

local status = { defaultPrinter = "", printerCount = 0, jobCount = 0, hasFault = false }

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("printer", "printer-off")
  shortcut.setActive(status.jobCount > 0 and not status.hasFault)
  shortcut.setEnabled(true)
end

noctalia.state.watch("printer.status", function(value)
  if type(value) == "table" then
    status = value
  end
  render()
end)

function onClick()
  noctalia.togglePanel("andrewdems/printers:panel")
end

render()
