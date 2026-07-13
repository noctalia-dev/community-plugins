--!nonstrict
local glyph = barWidget.getConfig("glyph")
local color = barWidget.getConfig("color") or "on_surface"
local glyphColor = barWidget.getConfig("glyph_color") or color
local updateError = noctalia.state.get("update_error")
local notifyOnNewUpdates = barWidget.getConfig("notify")
local click_action = barWidget.getConfig("click_action") or "open_gui"
local updates = noctalia.state.get("updates") or { Packages = {}, Aur = {}, Flatpak = {} }

local function countUpdates(scopedUpdates)
    return #scopedUpdates.Packages + #scopedUpdates.Aur + #scopedUpdates.Flatpak
end

local function getUpdateLabel(update)
  if update.OldVersion then
    return string.format("%s → %s", update.OldVersion, update.Version)
  else
    return update.Version
  end
end

local function appendUpdateSection(rows, title, list)
    if #list == 0 then
        return
    end

    table.insert(rows, {
        key = title,
        value = string.format("%d", #list),
    })

    for _, pkg in ipairs(list) do
        table.insert(rows, {
            key = "  " .. pkg.Name,
            value = getUpdateLabel(pkg),
        })

        if pkg.DownloadSize then
            table.insert(rows, {
                key = "",
                value = pkg.DownloadSize,
            })
        end
    end
end

local function updateTooltip()
  if updateError then
    barWidget.setTooltip(updateError)
    return
  end

  local count = countUpdates(updates)

  if count == 0 then
    barWidget.setTooltip(noctalia.tr("bar.tooltip.no_updates"))
    return
  end

  local rows = {}

  appendUpdateSection(rows, noctalia.tr("bar.tooltip.packages_title"), updates.Packages)
  appendUpdateSection(rows, noctalia.tr("bar.tooltip.aur_title"), updates.Aur)
  appendUpdateSection(rows, noctalia.tr("bar.tooltip.flatpak_title"), updates.Flatpak)

  barWidget.setTooltip(rows)
end

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row

  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = 14, color = glyphColor, visible = glyph ~= "" }),
    ui.label({ text = noctalia.trp("bar.text.updates", countUpdates(updates)), color = color }),
  }))

  updateTooltip()
end

noctalia.state.watch("updates", function(value)
  local prevCount = countUpdates(updates)
  local newCount = countUpdates(value)

  updates = value

  if notifyOnNewUpdates and newCount > prevCount then
      noctalia.notify(noctalia.tr("notify.new_updates.title"), noctalia.trp("notify.new_updates.description", newCount))
  end

  render()
end)

function onClick()
  if click_action == "open_gui" then
    local cmd = "shelly-ui"

    if not noctalia.commandExists(cmd) then
      noctalia.notifyError("Shelly", noctalia.tr("bar.click_handler.error.missing_gui"))
      return
    end

    noctalia.runAsync(cmd)
  elseif click_action == "open_updater" then
    local cmd = "shelly"

    if not noctalia.commandExists(cmd) then
      noctalia.notifyError("Shelly", noctalia.tr("bar.click_handler.error.missing_cli"))
      return
    end

    noctalia.runInTerminal(cmd .. " upgrade-all")
  end
end

render()
