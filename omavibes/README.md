# OmaVibes

Cozy typing sound effects with 40+ sound effects, typing profile, ranks, and local analytics for Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `viksit-garg/omavibes` |
| Entries | Bar widget: `omavibes`; panel: `panel`; service: `daemon` |

## Requirements

OmaVibes requires keyboard input event access and native compilation dependencies:

- `g++` and `make` to compile the lightweight audio daemon (`wayvibes`) on first launch
- `libevdev` for Linux input event monitoring
- `tar` and `zstd` to unpack the bundled soundpacks archive
- User membership in the `input` group:

```sh
sudo usermod -aG input $USER
```

Log out and back in after adding yourself to the `input` group.

## Usage

Add the `omavibes` widget to your bar in Noctalia Settings. Click the widget or run the following command to toggle the panel:

```sh
noctalia msg panel-toggle viksit-garg/omavibes:panel
```

Inside the panel, you can:
- **Browse & Search:** Filter through 50+ mechanical switch profiles and cozy soundpacks.
- **Adjust Volume:** Control master and per-pack volume from level 1 to 10.
- **Randomize:** Click the shuffle button to pick a random soundpack from the current search results.
- **Track Progress:** View your typing rank, milestone achievements, and local keyboard usage analytics.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `default_volume` | `int` | `3` | Default playback volume level (1-10) for new soundpacks. |
| `auto_start` | `bool` | `false` | Automatically restore typing sound playback on login. |
| `glyph` | `glyph` | `keyboard` | Bar widget icon glyph. |

## Notes

- **Privacy:** Keystroke analytics are computed entirely on-device. No typed text, passwords, or key sequences are ever stored or transmitted.
- **Custom Soundpacks:** Place your own custom soundpacks in `~/wayvibes/<pack-name>/` with their `config.json` and `.wav` files to override or augment bundled packs.
- **Audio Engine:** OmaVibes uses `wayvibes` with `miniaudio` for near-zero latency keyboard audio feedback.
