# Mic Denoise

Real-time RNNoise noise suppression for your microphone on PipeWire, toggled from the Noctalia control center, the bar, or a keybind.

## Plugin

| Field | Value |
| --- | --- |
| ID | `goldesquemoon/mic-denoise` |
| Entries | Service: `state`; shortcut: `denoise`; bar widget: `mic-denoise` |

RNNoise microphone noise suppression for PipeWire: the default source follows a virtual
filter-chain source while denoising is on, and switches back to the raw microphone when it is
off, which leaves the chain without a consumer so PipeWire suspends it.

## Requirements

| Requirement | Why |
| --- | --- |
| `pipewire` | Carries the filter-chain that does the denoising. |
| `noise-suppression-for-voice` | Provides the `librnnoise_ladspa.so` plugin the chain loads. |
| `libpulse` | `pactl` switches the default source and moves capture streams. |

## Usage

Add the tile under **Settings -> Control center -> Shortcuts -> Mic Denoise**, or toggle it with
`noctalia msg plugin goldesquemoon/mic-denoise:state all toggle`. The optional `mic-denoise` bar
widget shows the same state. Pick the physical microphone in the settings; leave it empty for
automatic detection.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `hardware_source` | `string` | empty | Microphone to fall back to when denoising is off. Empty reuses the last one or picks the first input. |
| `source` | `string` | `rnnoise_source` | Virtual source created by the bundled filter-chain config. |
| `auto_reload` | `bool` | `true` | Restart PipeWire once after the filter-chain config is written, so denoising works without a manual restart. |
| `poll_interval` | `int` | `5000` | State refresh interval in milliseconds (minimum 500). Toggles refresh immediately; the tick only catches changes made elsewhere. |

## Installing dependencies

| Distribution | Command |
| --- | --- |
| Arch / CachyOS | `sudo pacman -S pipewire noise-suppression-for-voice libpulse` |
| Fedora | `sudo dnf install pipewire noise-suppression-for-voice pulseaudio-libs` |
| Debian / Ubuntu | `sudo apt install pipewire noise-suppression-for-voice libpulse0` (`noise-suppression-for-voice` may require a third-party repository or a source build). |


## Install

**From the plugin store (recommended)**

1. Install `noise-suppression-for-voice` for your distro (see the table above).
2. Settings -> Plugins -> Store, search **Mic Denoise**, install and enable it.
3. Add the tile: Settings -> Control center -> Shortcuts -> *Mic Denoise*.

Nothing else is needed: the plugin generates
`~/.config/pipewire/pipewire.conf.d/50-mic-denoise.conf` on first run and, with
**Reload PipeWire automatically** on (the default), restarts PipeWire once so the virtual
source exists immediately. Turn that setting off if you would rather pick the moment
(e.g. during a call) - then run:

```sh
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
```

If `librnnoise_ladspa.so` is missing, the notification names the exact package command for
your distro and a right click on the tile copies it to the clipboard.

**From a checkout**

```sh
git clone https://github.com/Goldppx/noctalia-mic-denoise.git
cd noctalia-mic-denoise
./install.sh            # register the source + enable the plugin (no root)
./install.sh --restart  # also restart PipeWire once
```

## License

MIT
