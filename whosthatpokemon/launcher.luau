local PANEL_ID = "devpotatoes/whosThatPokemon:panel"

function onQuery(query)
    local rows = {}

    table.insert(rows, {
        id = "play",
        glyph = "device-gamepad",
        title = "Play",
        subtitle = "Launch the mini-game."
    })

    launcher.setResults(query, rows)
end

function onActivate(id)
    if id == "play" then
        noctalia.togglePanel(PANEL_ID)
    end
end