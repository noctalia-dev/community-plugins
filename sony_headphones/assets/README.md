# Device artwork (optional)

Drop per-model headphone images here as PNG or WEBP, then map them in
`DEVICE_ART` at the top of `panel.luau`. Each model maps to a list of
variants; the panel header's photo button cycles through them:

    ["WH-1000XM5"] = { "assets/wh_1000xm5_black.webp", "assets/wh_1000xm5_white.webp" }

Recommended size: ~400x350 (panel shows them at 200x175, `fit = "contain"`).
Transparent background looks best on both themes. If no file matches the
connected model, the panel falls back to a headphones glyph.
