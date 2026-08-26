# Hyprland Display Config

A Noctalia panel plugin for Hyprland: view connected monitors as ordered
cards, edit each one's mode/scale/rotation/enabled state, reorder them
left-to-right, and drag workspace-ID chips onto a card to bind that
workspace to that monitor.

## Plugin

| Field | Value |
| --- | --- |
| ID | `maddingo/hypr-display-config` |
| Entries | Bar widget: `widget`; panel: `panel`; services: `service`, `writer_service` |

## Requirements

Requires `hyprland`: a running Hyprland compositor with `hyprctl` and
`Hyprland` on `PATH`, using the native Lua config parser (`hl.monitor`,
`hl.workspace_rule`, `hl.dsp.workspace.move` via `hyprctl eval`). This
plugin does not use `hyprctl keyword` or legacy `hyprctl dispatch` — both
are rejected outright by the Lua-config parser.

## Usage

Open the panel to manage your monitors:

```sh
noctalia msg panel-toggle maddingo/hypr-display-config:panel
```

The panel lists connected monitors as ordered cards. For each one you can
edit its mode, scale, rotation, and enabled state; reorder monitors
left-to-right by dragging a card; and drag a workspace-ID chip onto a card
to bind that workspace to that monitor. Changes apply live via `hyprctl`
and are also written to the generated Lua config described above, so they
persist across restarts.

## Settings

- **Hyprland config file** (`hyprland_config`, default
  `~/.config/hypr/hyprland.lua`) — the plugin ensures this file
  `require()`s a generated `hypr-display-config.lua` placed in the same
  directory, and rewrites that generated file on every apply.
- **Workspace count** (`workspace_count`, default `10`) — how many
  workspace-ID chips are offered.

## Local development

```sh
noctalia msg plugins source add hypr-display-config-dev path ~/Develop/hypr-display-config
noctalia msg plugins enable maddingo/hypr-display-config
```

Luau file edits hot-reload; `plugin.toml` changes need
`noctalia msg config-reload`.

Run the standalone test suite (pure logic only — `panel.luau` is excluded,
see below) from the plugin root:

```sh
for f in tests/*.lua; do lua "$f" || exit 1; done
```

## Testing multi-monitor behavior without extra hardware

Hyprland can create virtual outputs at runtime:

```sh
hyprctl output create headless
hyprctl output create headless
hyprctl monitors all -j   # confirm HEADLESS-1, HEADLESS-2 alongside real outputs
```

Open the panel (`noctalia msg panel-toggle
maddingo/hypr-display-config:panel`), reorder cards, drag workspace
chips onto the headless monitors, and confirm:

- `hyprctl monitors all -j` reflects the new mode/scale/position live.
- `hyprctl workspacerules -j` reflects the new bindings.
- `~/.config/hypr/hypr-display-config.lua` contains matching
  `hl.monitor`/`hl.workspace_rule` calls.
- `~/.config/hypr/hyprland.lua` contains
  `require("hypr-display-config")` exactly once.

Remove the virtual outputs afterward:

```sh
hyprctl output remove HEADLESS-1
hyprctl output remove HEADLESS-2
```

