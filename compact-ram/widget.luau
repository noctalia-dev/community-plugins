--!nonstrict

barWidget.setImage("ram-dimm.svg", false, 18, 18)
noctalia.setUpdateInterval(2000)

function update()
  local stats = noctalia.systemStats()
  if stats == nil or stats.ram.totalMb == 0 then
    barWidget.setText("--")
    barWidget.setTooltip("Memory unavailable")
    return
  end

  barWidget.setText(string.format("%.1fG", stats.ram.usedMb / 1024))
  barWidget.setTooltip(string.format("Memory: %d / %d MiB used", stats.ram.usedMb, stats.ram.totalMb))
end
