# Speedtest Meter

Run an internet speed test with a live speedometer, then see full technical
results: ping, jitter, download/upload, test server (host, location,
country) and your ISP.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nilsonlinux/speedtest-meter` |
| Entries | Bar widget: `speedtest-widget`; Panel: `speedtest` |

**Entries:**
- **Widget:** `speedtest-widget` - Shows an icon in the bar; click to open the panel
- **Panel:** `speedtest` - Runs the speed test and displays the results

## Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `glyph` (widget) | `glyph` | `brand-speedtest` | Icon shown in the bar for the `speedtest-widget` widget. |

## Installation

Install via Noctalia Plugin Store.

## Requirements

At least one speedtest tool must be installed and on PATH:

- `speedtest` - the official Ookla Speedtest CLI. Gives a truly live gauge
  (per-phase progress). Not always in official distro repos (e.g. Arch:
  AUR, package name varies — check `yay -Ss speedtest`).
- `speedtest-cli` - the Python speedtest-cli package. Packaged in most
  distros' official repos (Arch: `pacman -S speedtest-cli`, also
  Debian/Ubuntu, Fedora, openSUSE, Alpine). No incremental progress, so the
  gauge pulses instead of tracking real numbers while it runs — the final
  result is still complete either way.

If neither is found, the error screen shows the right install command for
the detected package manager (pacman/apt/dnf/zypper/apk).

## Usage

1. Click the widget in the bar to open the panel
2. Click "Start test" to run a speed test
3. Watch the gauge while it runs (live numbers with the Ookla backend, a
   pulse with the legacy backend)
4. Review the results: download/upload, ping, jitter, packet loss, test
   server details, your ISP and external IP

## Dependencies

**stdbuf** (coreutils) - forces line-buffered output from the Ookla CLI so
the live gauge updates in real time instead of only at the end. Present on
virtually every Linux system.

## Notes for further development

- `speedtest` on PATH isn't proof it's the Ookla CLI: some distros' Python
  `speedtest-cli` package also installs a `speedtest` binary (same tool,
  different entry point name). `speedtest --version` is checked for the
  string "Ookla" before trusting it; otherwise the plugin falls back to
  `speedtest-cli`.
- `ui.progress`'s exact prop schema (beyond `value`, 0..1) isn't confirmed —
  a text-based bar (block characters) and an elapsed-time readout are shown
  alongside it as guaranteed-to-render fallbacks.
- Icon names tried for `ui.glyph` in the results screen (download, upload,
  timer, dns, etc.) turned out not to exist in this Noctalia's bundled icon
  set — they rendered as random unrelated glyphs instead of failing
  visibly, so they were removed entirely rather than guessed a fourth time.
  The results screen is icon-free plain text (plus the ↓/↑ characters,
  which render fine since they're just text) until the real icon name list
  is known.
- The download/upload headline switched from stat cards to colored circles
  per request. Colors are explicit hex (`#22c55e` green, `#f97316` orange)
  rather than semantic role names (`"success"`/`"warning"`), since the
  earlier role-name attempt rendered with no visible color difference in
  testing — hex is guaranteed to show up regardless of what this theme's
  color roles are actually called. `fill`/`width`/`height`/`radius` on
  `ui.column` are confirmed working (that's how the circle and the earlier
  `rss-notifier` badge pill are built).
- `[[panel]]` field names (`title`/`width`/`height`) in `plugin.toml` are
  still unconfirmed; `[[widget]]`/`[[widget.setting]]` are confirmed against
  a working `rss-notifier` plugin.

## License

MIT
