# Fresh CachyOS setup

This plugin needs a running Noctalia **5.4.0 or newer** session (API **43**), an installed WayVibes executable, at least one soundpack, and permission to read the selected keyboard. Noctalia v4 is a different runtime and is not supported.

Run the following in Bash as your normal desktop user. Use `sudo` only where shown. The desktop should already have working audio and a supported Wayland compositor; follow [Noctalia's compositor setup](https://docs.noctalia.dev/noctalia/getting-started/installation/) for your session.

## Install dependencies and WayVibes

Update CachyOS and install explicit build/runtime dependencies:

```bash
sudo pacman -Syu --needed noctalia base-devel git libevdev nlohmann-json procps-ng coreutils
```

Build the upstream daemon without requiring `yay` or `paru`. Its checkout uses a different directory name from the plugin:

```bash
mkdir -p "$HOME/src"
git clone https://github.com/sahaj-b/wayvibes.git "$HOME/src/wayvibes-engine"
make -C "$HOME/src/wayvibes-engine"
sudo install -Dm755 "$HOME/src/wayvibes-engine/wayvibes" /usr/local/bin/wayvibes
wayvibes --help
noctalia --version
```

If a checkout already exists, use it or choose another destination rather than cloning over it. Installing to `/usr/local/bin` makes the daemon available to the desktop session without depending on a terminal-specific `~/.local/bin` PATH. If your session uses a custom PATH, set the plugin's Executable Path to `/usr/local/bin/wayvibes`.

The upstream `wayvibes-git` AUR package is an alternative to building from source. Install it with an AUR helper you have explicitly installed; an AUR helper is not required by the plugin.

## Configure keyboard access

```bash
sudo usermod -aG input "$USER"
```

Fully log out of the graphical session and log back in, or reboot. Then verify the groups of the **current session**:

```bash
id -nG
```

The output must include `input`. A terminal opened before the new login still has its old groups. Do not run Noctalia or WayVibes with sudo; playback belongs to your normal user's audio session.

## Install a soundpack

The plugin includes no audio assets. For an initial test, copy a pack from the separately cloned upstream repository:

```bash
mkdir -p "$HOME/.local/share/soundpacks"
cp -a "$HOME/src/wayvibes-engine/soundpacks/nk-cream" "$HOME/.local/share/soundpacks/"
test -f "$HOME/.local/share/soundpacks/nk-cream/config.json"
```

Other Mechvibes-compatible packs can be placed in the same directory. Each pack must have its own folder containing `config.json` and its audio files; do not add an extra wrapper folder. Review the source and license of soundpacks you download.

## Install the plugin

Use the revision containing these fixes (`plugin.toml` version `1.0.1` or later). Changes in a local development checkout are not available to a fresh clone until they have been committed and pushed.

For an independent installation, clone the plugin into Noctalia's local plugin directory:

```bash
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins"
git clone https://github.com/VIKSIT-GARG/wayvibes.git \
  "${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/wayvibes"
noctalia plugins lint "${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/wayvibes"
```

For testing unpublished changes, copy the contents of the current working tree into that same `wayvibes/` directory instead of cloning the old remote revision. Preserve the layout: `wayvibes/plugin.toml`, `wayvibes/service.luau`, and `wayvibes/translations/en.json`.

Start Noctalia normally in your Wayland session. If it is already running, reload configuration, then enable the plugin:

```bash
noctalia msg config-reload
noctalia msg plugins enable viksit-garg/wayvibes
noctalia msg panel-toggle viksit-garg/wayvibes:panel
```

Add the `wayvibes` bar widget in Noctalia Settings. The widget is optional for opening the panel through the command above. If the plugin is later installed from the community store, use that installation instead of keeping a stale local copy, since local plugins take precedence.

## Verify the first run

1. Open **Input Device** and select the keyboard you will type on. The first detected keyboard is selected automatically only when no valid device configuration exists. For a remapper such as `keyd`, select its virtual keyboard when appropriate.
2. Confirm that `${XDG_CONFIG_HOME:-$HOME/.config}/wayvibes/input_device` contains a `NAME:` or `PATH:` record. No legacy `input_device_path` file is required.
3. Open **Soundpacks**, find the copied pack, and press its play button. Type into a normal application and check that audio is audible. Confirm `pgrep -x wayvibes` finds a process.
4. Change volume, switch packs if you have another, and press **Turn Off**. Confirm typing sounds stop. Search, shuffle, and refresh should operate without resetting the selected keyboard.
5. Enable `auto_start` only after manual playback works. Restart Noctalia and confirm the last saved pack and volume are restored. Leave `auto_start` disabled if you want a silent login.

To separate an upstream audio/device problem from a plugin problem, stop playback in the panel, then run the daemon in a terminal as your normal user:

```bash
wayvibes --device
wayvibes "$HOME/.local/share/soundpacks/nk-cream" -v 3
```

The first command configures the keyboard through upstream's interactive selector. The second stays in the foreground and exposes startup errors; press Ctrl+C to stop it. If this fails, resolve that error before testing background playback in the plugin. Ogg conversion may require optional `ffmpeg`; the initial WAV-based pack avoids that requirement.

## Automated checks and limits

The service regression suite can be run without input devices or an audio server:

```bash
python3 tests/run.py --luau /path/to/luau
```

It runs 15 service tests and 2 UI tests covering an empty profile, absent dependencies, failed daemon startup, device discovery and selection, current/legacy configuration, failed writes, and opening the panel or widget after the service has initialized. Its host fixtures never modify your real configuration or start real daemons.

A clean container can verify package installation, compilation, the real upstream CLI, Noctalia's linter, and these regression tests. It cannot establish audible playback or physical keyboard permissions in a fresh graphical login. Those require the first-run checks above on the installed desktop.

From the plugin checkout, repeat the clean container check with Docker:

```bash
docker build -f tests/cachyos.Dockerfile -t wayvibes-cachyos-smoke:local .
```

The Dockerfile pins the official CachyOS base image and the upstream WayVibes/Luau source revisions, builds both executables inside the container, installs a real soundpack, and runs the tests as a new unprivileged user. CachyOS package versions follow its rolling mirrors. It does not mount your home directory, input devices, or audio sockets. Its pacman network-sandbox adjustment is confined to the disposable container and is not part of the desktop setup instructions.

Sources: [Noctalia installation](https://docs.noctalia.dev/noctalia/getting-started/installation/), [plugin API versions](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/), [local plugin workflow](https://docs.noctalia.dev/noctalia/plugins/development/workflow/), and [upstream WayVibes](https://github.com/sahaj-b/wayvibes).
