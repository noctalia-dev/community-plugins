# Hyprland Visual Editor

Visually edit Hyprland animations, borders and shaders from a Noctalia
panel, applied instantly without manual config edits. A Luau port of XimoCP's v4
plugin for Noctalia v5.

> **⚠️ Lua config required.** This plugin targets Hyprland's **Lua** configuration
> (`hyprland.lua`). It does **not** work with the legacy hyprlang `.conf` format —
> HVE generates Lua (`hl.animation`, `hl.config`) and loads it via `dofile`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `linux-fertxo/hyprland-visual-editor` |
| Entries | Bar widget: `hve-trigger` · panel: `hve-panel` · service: `hve-scanner` |

## Requirements

- `hyprland` running a **Lua** config (`hyprland.lua`) — not the legacy hyprlang
  `.conf` format (HVE emits `hl.animation` / `hl.config` and loads via `dofile`).
- `bash` and `python` on `PATH` (the preset converter and assembler are shell
  scripts that call `python3`).

## Usage

1. Add the **Hyprland Visual Editor** widget to your bar.
2. Click the bar widget to open the panel. Pick a preset (Animations, Borders or
   Effects) and press **Apply** — HVE applies it and reloads Hyprland instantly.

On first enable, HVE appends the overlay loader to the end of your
`~/.config/hypr/hyprland.lua` (idempotent, marked with a
`HYPRLAND VISUAL EDITOR` comment). If you prefer to do it manually, the line is:

```lua
pcall(function() dofile(os.getenv("HOME") .. "/.cache/noctalia/HVE/overlay.lua") end)
```

The panel can also be toggled directly:

```sh
noctalia msg panel-toggle linux-fertxo/hyprland-visual-editor:hve-panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `is_system_active` | `bool` | `false` | Master switch that enables effects. |
| `active_anim_file` | `string` | `""` | Currently active animation preset. |
| `active_border_file` | `string` | `""` | Currently active border preset. |
| `active_shader_file` | `string` | `""` | Currently active shader preset. |

## IPC

```sh
noctalia msg panel-toggle linux-fertxo/hyprland-visual-editor:hve-panel
```

## Notes

- HVE writes its generated overlay to `~/.cache/noctalia/HVE/overlay.lua` and
  reloads Hyprland with `hyprctl reload` after every apply. Your `hyprland.lua`
  is never modified except for the one-time loader line above.
- Ships 18 animation presets, 13 border presets and 9 GLSL shaders. Add your own
  by dropping a `.conf`/`.frag` into the matching `assets/` folder with the
  `@Title` / `@Desc` / `@Icon` / `@Color` / `@Tag` metadata header.
- Shaders are applied as absolute-path `screen_shader` entries; re-apply the
  shader after moving the plugin directory.
- UI is localized: English (`en`), Spanish (`es`) and Catalan (`ca`).

## Credits

- **Architecture & core:** XimoCP (Noctalia v4, QML)
- **Luau port (v5):** Hermy & [linux-fertxo](https://github.com/linux-fertxo)
