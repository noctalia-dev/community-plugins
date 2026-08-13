local image = noctalia.getConfig("custom_image")

if image ~= "" and image ~= nil then
    barWidget.setImage(image)
else
    barWidget.setGlyph(noctalia.getConfig("glyph"))
end

barWidget.setTooltip(noctalia.tr("widget.tooltip"))
