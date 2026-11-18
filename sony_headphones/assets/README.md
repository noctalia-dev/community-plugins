# Device artwork

Generic headphone **symbols** used as temporary placeholders. No Sony product
photography, vendor render, or trademarked logo is bundled.

## Provenance & license

- **Source:** [Tabler Icons](https://tabler.io/icons) — the `headphones`
  (filled) icon for over-ear models and the `device-airpods` (outline) icon for
  true-wireless models. Pristine upstream copies are in `sources/`.
- **Author:** Paweł Kuna / Tabler Icons.
- **License:** MIT. The full text is in
  [`LICENSES/Tabler-Icons-MIT.txt`](LICENSES/Tabler-Icons-MIT.txt).
- **Modifications:** recoloured (black/white) and centred on a transparent
  400×350 canvas. The `.webp` files are rasterised from the SVGs with:

  ```sh
  rsvg-convert -w 240 -h 240 -o /tmp/icon.png sources/tabler-headphones-filled.svg
  magick /tmp/icon.png -gravity center -background none -extent 400x350 over_ear_black.webp
  ```

These are placeholders; the author plans to replace them with their own
hand-drawn sketches under the same MIT license and the same file names.

## Files

- `over_ear_{black,white}.webp` — over-ear models
- `in_ear_{black,white}.webp` — true-wireless models

The per-model mapping lives in `DEVICE_ART` in `panel.luau`; the panel header
button cycles the variants. To use your own image for a model, drop a PNG/WEBP
here and point that model's entry at it.
