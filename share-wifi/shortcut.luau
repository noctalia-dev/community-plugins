-- shortcut.luau

local function syncStatus()
  local raw = noctalia.state.get("share_wifi_status")
  if raw and raw.active then
    shortcut.setActive(true)
    if raw.clients and raw.clients > 0 then
      shortcut.setLabel(noctalia.tr("shortcut.connected", { count = tostring(raw.clients) }))
    else
      shortcut.setLabel(noctalia.tr("shortcut.sharing"))
    end
  else
    shortcut.setActive(false)
    shortcut.setLabel(noctalia.tr("shortcut.label"))
  end
end

noctalia.state.watch("share_wifi_status", function()
  syncStatus()
end)

function onClick()
  noctalia.togglePanel("conqazht/share-wifi:panel")
end

syncStatus()
