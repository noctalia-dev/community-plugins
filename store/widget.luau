--!nonstrict
barWidget.setGlyph("packages")
barWidget.setTooltip("Noctalia Store · Nix, Flatpak and Pacman")
function onClick() noctalia.togglePanel("swashx-dev/store:browser") end
