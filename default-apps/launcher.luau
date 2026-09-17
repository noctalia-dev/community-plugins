-- launcher.luau
local PANEL_ID = "thaer99ob/default-apps:manager"

function onQuery(text)
  -- The moment you click the provider in the '/' menu, Noctalia inputs "/apps "
  -- and fires onQuery with an empty string. We use this exact moment to instantly open the panel.
  if text == "" then
    noctalia.togglePanel(PANEL_ID)
    
    launcher.setResults(text, {
      {
        id = "status",
        title = "Panel Opened",
        subtitle = "The Default Apps manager is now active on your screen.",
        glyph = "check"
      }
    })
  else
    launcher.setResults(text, {})
  end
end

function onActivate(id)
  -- Failsafe in case you hit Enter on the status message
  if id == "status" then
    noctalia.togglePanel(PANEL_ID)
  end
end
