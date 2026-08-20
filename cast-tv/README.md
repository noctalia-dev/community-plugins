# Cast to TV

A [Noctalia](https://github.com/noctalia-dev/noctalia) plugin that casts your
desktop to a smart TV over Wi-Fi Direct (Miracast), using
[FluxCast](https://github.com/IlyaP358/fluxcast) — a bar icon and a Control
Center shortcut, both opening the same panel: pick a TV from a live scan,
toggle 720p / TV audio / bitrate, click Cast.

## Plugin

| Field | Value |
| --- | --- |
| ID | `andresparrab/cast-tv` |
| Entries | Bar widget: `bar`; panel: `picker`; shortcut: `toggle` |

## Requirements

Install `fluxcast` and `wf-recorder` on `PATH` (AUR: `paru -S fluxcast-git
wf-recorder`).

- A Wi-Fi adapter with Wi-Fi Direct support, driven by NetworkManager (the
  plugin scans via `fluxcast --protocol wfd --wfd-scan`, which shells out to
  NetworkManager's Wi-Fi Direct discovery)
- `wf-recorder` is used as fluxcast's capture backend — see "Why
  `wf-recorder`" below for why it's forced rather than left as fluxcast's
  default

The plugin only talks to the `fluxcast` binary directly — no dependency on
any personal dotfiles or wrapper scripts. If `fluxcast` isn't found, the
panel says so instead of failing silently.

## Usage

Add the bar icon (recommended — one click, no Control Center detour) or the
Control Center shortcut tile, or both — neither placement is automatic, both
are opt-in like any other Noctalia widget/shortcut:

- **Bar icon**: add `"cast-tv"` to `[bar.default].end` (or `.start`/
  `.center`) in `settings.toml`, and add
  ```toml
  [widget.cast-tv]
  type = "andresparrab/cast-tv:bar"
  ```
- **Control Center shortcut tile**: add
  ```toml
  [[control_center.shortcuts]]
  type = "andresparrab/cast-tv:toggle"
  ```
  to `settings.toml`. The Home tab's shortcut grid is capped at 6 tiles, so
  this may mean swapping one out.

Then `noctalia msg config-reload`, or restart Noctalia if you added the bar
widget (a brand-new widget type needs a real restart to register — a reload
alone won't pick it up).

Click the bar icon (or the Control Center shortcut) to open the panel. It
scans for Wi-Fi Direct peers automatically (a few seconds — that's inherent
to Wi-Fi Direct discovery, not the plugin). Pick a TV, adjust options if
needed, click **Cast**. Click **Stop Casting** to end it.

Or open the panel directly:

```sh
noctalia msg panel-toggle andresparrab/cast-tv:picker
```

## Why `wf-recorder` as the capture backend

FluxCast's default portal-based screen capture negotiates through two
capability checks before falling back to one that works — on a wlroots
compositor (niri, Sway, ...) that can take ~15s, long enough that some TVs
give up and disconnect before the stream starts. Forcing
`--wfd-capture-backend wf-recorder` skips that negotiation and connects in
about 2 seconds. This is hardcoded rather than exposed as an option because
it's a strict improvement on this class of compositor, not a tradeoff.

## Notes

- **Stop Casting** sends `pkill -f wfd-peer`, which cleanly kills the
  specific `fluxcast` process this plugin started (matched by the
  `--wfd-peer` flag in its command line), not any other `fluxcast` instance
  you might have running (e.g. `fluxcast --tray`).
- If the plugin is ever misbehaving, you can still cast from a plain
  terminal with the same tuned flags this plugin uses:
  ```sh
  fluxcast --protocol wfd --wfd-scan
  fluxcast --wfd-capture-backend wf-recorder --wfd-monitor <output> \
    --bitrate 6M --wfd-peer <mac> --wfd-no-audio
  ```
