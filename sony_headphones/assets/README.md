# Device artwork

The images in this directory are **original artwork** created for this plugin:
stylised, flat illustrations of over-ear and in-ear headphones. They are part
of the plugin and licensed under its MIT license — no third-party product
photography, vendor render, or trademarked logo is included.

Each `.webp` is rasterised from the matching `.svg` source next to it. Regenerate
or tweak the set with:

```sh
python3 tools/generate_art.py           # writes the .svg sources
for f in assets/*.svg; do
  rsvg-convert -o /tmp/art.png "$f"
  magick /tmp/art.png -quality 92 "${f%.svg}.webp"
done
```

Files:

- `over_ear_{black,white,silver,lavender}.webp` — over-ear models
- `in_ear_{black,white}.webp` — true-wireless models

The per-model mapping lives in `DEVICE_ART` in `panel.luau`; the panel header
button cycles the variants. To use your own image for a model, drop a PNG/WEBP
here and point that model's entry at it.
