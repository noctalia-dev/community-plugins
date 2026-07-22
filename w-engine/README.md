# W Engine

A [Noctalia](https://github.com/noctalia-dev/noctalia) v5 plugin for applying Wallpaper Engine wallpapers from Steam Workshop.

## Dependencies

Before installing this plugin, make sure you already have Wallpaper Engine installed from Steam. Without it, the plugin will not work.

You also need Steam itself to download wallpapers from the Workshop, plus the `linux-wallpaperengine` tool.

For more details, see the install section below.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tadomika_ari/w-engine` |
| Entries | Bar widget: `w-engine-widget`; panel: `w-engine-panel` |

## Usage

Add the `W Engine` widget from Noctalia's widget picker, then click it to open the panel. You can also open the panel directly or bind it in your compositor:

```sh
noctalia msg panel-toggle tadomika_ari/w-engine:w-engine-panel
```

| Action | Effect |
| --- | --- |
| Left click on the bar glyph | Open or close the W Engine panel |
| Click a wallpaper entry in the panel | Apply that wallpaper |

## Settings

No settings.

## Requirements

- noctalia ≥ 5.0.0
- `linux-wallpaperengine`
- Wallpaper Engine
- Steam for Workshop access

## Install

Install **W Engine** from Noctalia's plugin store (*Settings → Plugins*), then add the widget to a bar from *Settings → Bar*. Plugin options live in *Settings → Plugins*.

Next, install Wallpaper Engine from Steam: https://store.steampowered.com/app/431960/Wallpaper_Engine/

Then install `linux-wallpaperengine` from its project page: https://github.com/Almamu/linux-wallpaperengine

Note that some Wallpaper Engine wallpapers may not work correctly on Linux, especially ones with advanced visual effects.

If you use NixOS, be aware that the package version in nixpkgs may lag behind upstream.

For local development, add your working copy as a path source instead
(`.luau` edits hot-reload):

```sh
noctalia msg plugins source add dev path /path/to/plugins
noctalia msg plugins enable tadomika_ari/w-engine
```

## License

MIT.
