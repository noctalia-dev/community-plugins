# NVibrant

Adjust screen saturation from the bar. On NVIDIA GPUs it drives digital vibrance through [nvibrant](https://github.com/Tremeschin/nvibrant); on every other GPU (AMD, Intel) it applies a hardware color matrix through niri.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nofiltera1/nvibrant` |
| Entries | Bar widget: `bar`; panel: `panel` |

## Requirements

- `bash` and `awk` on `PATH`.
- `niri` on `PATH`.
- NVIDIA outputs: `nvibrant` on `PATH`. Nothing else is needed.
- Non-NVIDIA outputs (AMD, Intel): a niri build that has the `niri msg output <name> color-matrix` action. Stock niri does not ship it; see [Non-NVIDIA outputs](#non-nvidia-outputs-niri-color-matrix) below.

## Usage

Add the widget to a bar section as `nofiltera1/nvibrant:bar` (for example `[widget.nvibrant]` with `type = "nofiltera1/nvibrant:bar"`).

- Left click opens the panel: an on/off toggle and a slider from 0 to 1023. Dragging the slider previews the level live while saturation is on.
- Right click turns saturation on or off without opening the panel.

```sh
noctalia msg panel-toggle nofiltera1/nvibrant:panel
```

The on/off state and the level are remembered between sessions.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `display_index` | `int` | `0` | `0` applies the level to every nvibrant port (recommended). Any other value selects that nvibrant port, `1` being the first. Only affects NVIDIA outputs. |

## Non-NVIDIA outputs (niri color-matrix)

On AMD and Intel there is no nvibrant. The plugin instead sets a saturation color matrix on each connected output with `niri msg output <name> color-matrix set -- <9 numbers>`, and resets it with `color-matrix reset`. This needs a niri compiled with the DRM color-transform-matrix (CTM) output action from [niri-wm/niri#4543](https://github.com/niri-wm/niri/pull/4543). That pull request is not merged upstream, so stock niri releases do not include it.

If you see the notification "NVibrant: niri has no color-matrix", your niri lacks the action. To check:

```sh
niri msg output --help | grep color-matrix
```

If it prints nothing, build niri from the pull request branch and use that binary for both the compositor and the `niri` command:

```sh
git clone https://github.com/nsrkn2n/niri
cd niri
git checkout color-matrix
cargo build --release
# install target/release/niri in place of your niri (or into a directory earlier on PATH)
```

Restart the niri session afterwards: the running compositor must be the new build, because `niri msg` talks to it. Some distributions may package such a build (for example under the name `niri-ctm`); check your package manager.

## Notes

- Runs `apply.sh` from the plugin directory, which calls `nvibrant` and/or `niri msg output ... color-matrix` for every connected output. Saturation is `1 + level / 1023`, computed with Rec. 709 luma weights.
- Stores the on/off state and level in the plugin data directory (`state.json`).
- No network access.
