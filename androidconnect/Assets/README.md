# Artwork source and license

`phone-idle.svg` and `device.svg` are original geometric SVG illustrations created
for AndroidConnect by the AndroidConnect contributors in 2026. Their source is the
readable SVG in this directory. They use only rectangles, paths, and gradients;
they do not trace a manufacturer product render, contain a stock wallpaper, or
reproduce manufacturer/Android logos. Both are licensed under GPL-2.0-only, as
marked in their source; see the plugin's `../LICENSE`.

`phone.png` is the raster export of `phone-idle.svg`, under the same license.
Reproduce it from the plugin directory with librsvg's development tool:

```sh
rsvg-convert Assets/phone-idle.svg -o Assets/phone.png
```

`rsvg-convert` is needed only to regenerate artwork, not to run the plugin.

## Local custom artwork

The optional `artwork_directory` setting selects an existing directory containing
`phone.png` and `phone-idle.svg`. Files are read locally; the plugin does not
upload, copy into its source, or distribute them. The directory is not included
in releases or community submissions. Users supply their own artwork; the
plugin's GPL notice does not assign a license to their local files.

Both images use a 597 by 1241 canvas. The PNG must have those dimensions, and the
SVG must declare `viewBox="0 0 597 1241"`. The live screen opening starts at
x=25, y=26, is 538 by 1190, and has corner radius 52. These dimensions are retained
for input-mapping and saved-preview-size compatibility. FFmpeg replaces that
opening with live video; the rest of the PNG is the surrounding frame. The SVG
is shown while idle. Leave the setting empty to use the bundled generic artwork.

The former manufacturer-style phone image, embedded raster in the idle SVG, and
vendor badge files were removed because this project had no verified source or
redistribution license records for them. They are not covered by this attribution.
