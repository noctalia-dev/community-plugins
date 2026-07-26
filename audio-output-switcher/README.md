# Audio Output Switcher

Route individual apps to different audio outputs. Each playing app appears in the panel with buttons to switch it to any available output (headphones, HDMI, Bluetooth, USB, etc.). Works with PipeWire/PulseAudio.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rael2pac/audio-output-switcher` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `audio-poller` |

## Usage

The bar widget shows a speaker icon. Click it to open the panel listing all currently playing audio streams with buttons for each available output.

Each stream shows the app name with its icon (Firefox, Spotify, etc.) and the current output. Click any output button to route that app to a different output.

```sh
noctalia msg panel-toggle rael2pac/audio-output-switcher:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refreshInterval` | `int` | `3` | Seconds between audio stream polls (min 1, max 15). |

## Notes

- Requires PipeWire or PulseAudio running on the system.
- Uses `pactl` to list sinks and move sink inputs between outputs.
- Auto-detects output names from the internal device names (brand, type).
- Supports up to 5 audio outputs and 8 simultaneous streams.
