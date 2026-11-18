# Mihomo Glyph

`mihomo-glyph.ttf` contains one private-use glyph at `U+E001`, traced from the
bundled Mihomo cat image. It preserves the recognizable silhouette, eyes, mouth,
ears, and tail while allowing Noctalia to color it like text.

The accompanying SVG is the reviewable vector source. Regenerate both assets
with:

```sh
python3 fonts/generate_mihomo_glyph.py
```

Generation requires OpenCV and fontTools; neither is needed at runtime.
