-- Static bar widget: glyph + tooltip only. All click behavior is bound in
-- plugin.toml [widget.actions]; per the shell's rules a manifest binding wins
-- over script callbacks, so there is deliberately no onClick here.
if barWidget then
    if barWidget.setGlyph then barWidget.setGlyph("brand-youtube-filled") end
    if barWidget.setText then barWidget.setText("") end
    if barWidget.setTooltip then barWidget.setTooltip("Noctalia YT Music") end
end
