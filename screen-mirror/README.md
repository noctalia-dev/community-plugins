# Screen Mirror

Mirror the main niri output onto every hotplugged display, toggled from the Noctalia control center, the bar, or a keybind.

## Plugin

| Field | Value |
| --- | --- |
| ID | `goldesquemoon/screen-mirror` |
| Entries | Service: `state`; shortcut: `mirror`; bar widget: `screen-mirror` |

Mirrors the main niri output onto every other connected display, and cleans up when they are
unplugged. niri has no output mirroring of its own, so the plugin drives the companion
`niri-mirror` daemon, which renders the source output with wl-mirror and fullscreens it on the
target outputs.

## Requirements

| Requirement | Why |
| --- | --- |
| `niri` | The compositor this plugin targets; mirroring uses its output and output events. |
| `wl-mirror` | Renders the source output into a window that gets fullscreened on the target display. |
| `python3` | Runs the bundled mirroring engine (`engine/niri_mirror.py`). |
| `wl-mirror` package | The only package to install by hand: `sudo pacman -S wl-mirror`. |

## Usage

Add the tile under **Settings -> Control center -> Shortcuts -> Screen Mirror**, or toggle it with
`noctalia msg plugin goldesquemoon/screen-mirror:state all toggle`. The optional `screen-mirror`
bar widget shows the same state. The settings choose the source output, the excluded outputs,
OSD feedback and whether mirroring starts enabled.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled_on_start` | `bool` | `true` | Turn mirroring on when the plugin starts. |
| `source_output` | `string` | empty | Output to mirror; empty picks the primary output. |
| `excluded_outputs` | `string_list` | empty | Outputs that must never be mirrored. |
| `scaling` | `string` | `fit` | How wl-mirror scales the source into the target display. |
| `show_osd` | `bool` | `true` | Show an OSD popup when mirroring is toggled. |
| `poll_interval` | `int` | `2000` | State refresh interval in milliseconds (minimum 500). |

## Display selection

Mirror the main niri output onto every other display — control-center tile, optional
bar widget, and all the settings in the plugin settings page. Plugging a monitor in
mirrors it automatically; unplugging cleans up. A display on the exclusion list **never
gets a mirror window, even when it is plugged in**.

The two display settings are plain text fields, but you rarely need the exact
connector name: `hdmi` matches `HDMI-A-1` (exact → case-insensitive → unique substring).
A name that matches nothing is reported back with the list of what is actually
connected:

```
Some excluded displays could not be identified
HDMI-X does not match any connected display; available: eDP-2, HDMI-A-1
```

To see the names up front: `python3 engine/niri_mirror.py --list-outputs`.

niri has no output mirroring of its own (`Mirroring is not yet supported`), so the bundled
**`niri-mirror` engine** renders the source output with
[wl-mirror](https://github.com/Ferdi265/wl-mirror) and fullscreens that window on the
target display. The daemon follows niri's event stream, so hotplug works with no
polling; this plugin is the UI and the settings bridge.

## Install

**From the plugin store (recommended)**

1. Install the one package it needs: `sudo pacman -S wl-mirror`.
2. Settings -> Plugins -> Store, search **Screen Mirror**, install and enable it.
3. Add the tile: Settings -> Control center -> Shortcuts -> *Screen Mirror*.

The mirroring engine is **bundled** (`engine/niri_mirror.py`, MIT, from the
[niri-mirror](https://github.com/Goldppx/niri-mirror) project), so there is no second
repository to clone and no CLI to place in `~/.local/bin`. If a `niri-mirror` CLI of your own
exists, it is used instead - handy for a hand-installed engine.

**From a checkout**

```sh
git clone https://github.com/Goldppx/noctalia-screen-mirror.git
cd noctalia-screen-mirror
./install.sh          # registers the source + enables the plugin (no root)
```

## Dependencies

| Need | Why | Install |
|---|---|---|
| `niri` | compositor; the engine reads `niri msg` | your session |
| `wl-mirror` | does the actual output capture/mirroring | `sudo pacman -S wl-mirror` |
| `python3` | runs the bundled engine | `sudo pacman -S python` |

`niri-mirror` is not a separate install any more: `engine/niri_mirror.py` is part of the plugin
and the service calls it with `python3`. The tile is disabled only if that file is missing,
which means the plugin install is broken - reinstall it.

## How it works

```
settings page ──write──▶ ~/.config/niri-mirror/config.json ──read──▶ niri-mirror daemon
                                                                          │
tile / widget ◀──state── $XDG_RUNTIME_DIR/niri-mirror/state ◀──write──────┘
```

* `service.luau` writes the settings as JSON (the daemon's config file), then runs
  `python3 engine/niri_mirror.py ensure` followed by `... reload` so a running daemon picks
  the changes up (`ensure` also starts it when it is not running yet).
* The daemon writes a `key=value` state file on every change; the service mirrors it
  into `noctalia.state "status"` and the tile/widget render from there.
* Toggles go back as `noctalia.state "command"` → `niri-mirror toggle`, so keybind
  toggles, the tile, and the widget all share one source of truth.
* A state file that stops refreshing means the daemon died; the service revives it
  with a throttled `ensure`.

## Settings

| Setting | Type | Default | Effect |
|---|---|---|---|
| Enabled on start | bool | on | `enabled_on_start` — mirroring on as soon as the daemon starts. The manually-toggled **off** state is not persisted across logins. |
| Show OSD feedback | bool | on | `show_osd` — OSD popup on every on/off (falls back to a notification, `feedback: never` when off). |
| Excluded displays | string list | empty | `excluded_outputs` — connectors that never get a mirror window, not even when they are plugged in. |
| Source display | string | empty | `source_output` — connector to mirror from; empty = focused display at startup, re-elected if it disappears. |
| Scaling | select | fit | `scaling` — `fit` / `cover` / `exact`, passed to wl-mirror. |
| Refresh interval (ms) | int | 2000 | UI refresh of the state file (the daemon reacts to niri events, not to this). |

## IPC / keybinds

```sh
noctalia msg plugin goldesquemoon/screen-mirror:state all toggle          # on / off
noctalia msg plugin goldesquemoon/screen-mirror:state all sync            # re-push settings
niri-mirror toggle            # the same thing without going through noctalia
```

niri keybind (works even when Noctalia is not running):

```kdl
Mod+U { spawn-sh "~/.local/bin/niri-mirror toggle"; }
```

## Limitations

* Mirroring costs a capture + composite round trip: expect some latency, and the
  pointer can smear on a 60 Hz target driven by a 180 Hz source. Not for games.
* Layer-shell surfaces (bars, wallpapers) still draw above the fullscreen mirror.
* Every display that is not the source and not excluded gets mirrored, so a third
  screen is mirrored too — add it to `Excluded displays` to keep it usable as its own
  workspace.
