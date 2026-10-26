# LOQ RGB

A [Noctalia](https://noctalia.dev) v5 plugin to control the RGB lighting of Lenovo LOQ keyboards and
other HID LampArray keyboards: palette sync, gradients, per-zone colors, smooth fades and a live preview.
See [`loq-rgb/README.md`](loq-rgb/README.md) for usage.

## Install

```bash
noctalia msg plugins source add loq-rgb git https://github.com/ArthurGuillerm/loq-rgb
noctalia msg plugins enable arthur/loq-rgb
```

Needs Noctalia >= 5.2.0 (plugin API 32) and `python3`. On first use the panel guides you through the
one-time keyboard access setup.

## Layout

```
loq-rgb/             the plugin (this directory is what gets submitted to community-plugins)
  plugin.toml  service.luau  widget.luau  panel.luau  lib/profile.luau
  helper/lamparray.py          the only non-Luau piece (HID transport + fades, stdlib only)
  scripts/setup-access.sh      one-time udev setup, run in a terminal on demand
  translations/  README.md  thumbnail.webp
catalog.toml         index of this repository when used as a plugin source
```

## Development

Use a path without spaces (Noctalia truncates the path at the first space).

```bash
noctalia msg plugins source add loq-dev path "$(pwd)"   # live copy: .luau files hot-reload
noctalia plugins lint .                                 # manifest checks, rebuilds catalog.toml
```

## License

MIT
