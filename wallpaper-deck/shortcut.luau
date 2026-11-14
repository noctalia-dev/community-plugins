--!nonstrict
-- Control Center shortcut tile for Wallpaper Deck (Noctalia v5)

local PANEL_ID = "ishan0121/wallpaper-deck:picker"

local function syncShortcut()
  if type(shortcut) == "table" then
    local title = (type(noctalia) == "table" and type(noctalia.tr) == "function" and noctalia.tr("title")) or "Wallpapers"
    if title == "title" or title == "" then
      title = "Wallpapers"
    end
    pcall(shortcut.setLabel, title)
    pcall(shortcut.setIcon, "cards", "cards")
    pcall(shortcut.setEnabled, true)
    pcall(shortcut.setActive, false)
  end
end

function update()
  syncShortcut()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onIpc(event: string, _payload: any)
  if event == "toggle" or event == "click" then
    onClick()
  end
end

function render()
  if type(ui) == "table" and type(ui.button) == "function" then
    return ui.button({
      text = "Wallpapers",
      glyph = "cards",
      variant = "secondary",
      controlSize = "md",
      onClick = onClick,
    })
  end
  return nil
end

syncShortcut()
