--!nonstrict
-- MochiType launcher provider: type /type and select the result to open the
-- typing panel.

function onQuery(text)
  launcher.setResults(text, {
    {
      id = "open",
      title = "Typing test",
      subtitle = "Open the MochiType panel",
      glyph = "keyboard",
    },
  })
end

function onActivate(id)
  if id == "open" then
    noctalia.togglePanel("lepinx/typer:test")
  end
end
