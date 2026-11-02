--!nonstrict
-- USB Manager bar widget — the [[widget]] entry.
--
-- A USB glyph with the number of drives. The glyph is lit while something is
-- mounted, pulses with the tertiary color while a drive is being written or
-- prepared for removal, and the widget hides itself when nothing is plugged
-- in (configurable). Left click opens the panel, right click safely removes
-- every drive.

local shared = require("./shared.luau")

local snapshot = nil

local function drives()
  return snapshot and snapshot.drives or {}
end

local function anyPending()
  return snapshot ~= nil and next(snapshot.pending or {}) ~= nil
end

local function anyBusy()
  for _, drive in drives() do
    if drive.busy then
      return true
    end
  end
  return anyPending()
end

local function render()
  local list = drives()
  local count = #list
  local hidden = count == 0 and noctalia.getConfig("hide_when_empty") ~= false
  barWidget.setVisible(not hidden)
  if hidden then
    return
  end

  local mounted = shared.mountedCount(list)
  local color = "on_surface/0.55"
  if anyBusy() then
    color = "tertiary"
  elseif mounted > 0 then
    color = "primary"
  elseif count > 0 then
    color = "on_surface"
  end

  local glyph = "usb"
  if count == 1 then
    glyph = shared.driveGlyph(list[1])
  end
  local children = { ui.glyph({ name = glyph, color = color }) }
  if count > 0 and noctalia.getConfig("show_count") ~= false then
    table.insert(children, ui.label({ text = tostring(count), fontWeight = "bold", color = color }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  local rows = {}
  for _, drive in list do
    local parts = {}
    for _, volume in drive.volumes do
      local name = shared.volumeName(volume) or volume.name
      if volume.mountPoint then
        table.insert(parts, `{name}: {noctalia.tr("tooltip.mounted", { path = volume.mountPoint })}`)
      else
        table.insert(parts, `{name}: {noctalia.tr("tooltip.not-mounted")}`)
      end
    end
    local value = shared.formatBytes(drive.size)
    if #parts > 0 then
      value ..= " · " .. table.concat(parts, " · ")
    end
    table.insert(rows, { key = drive.title, value = value })
  end
  if count == 0 then
    table.insert(rows, { key = noctalia.tr("title"), value = noctalia.tr("panel.empty") })
  end
  if count > 0 then
    table.insert(rows, { key = noctalia.tr("tooltip.right-click"), value = noctalia.tr("tooltip.remove-all") })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("usbm.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function update()
  noctalia.setUpdateInterval(5000)
  if snapshot == nil then
    snapshot = shared.snapshot()
  end
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel("rylos/usb-manager:panel")
end

function onRightClick()
  if #drives() > 0 then
    shared.sendCmd("remove_all")
  end
end
