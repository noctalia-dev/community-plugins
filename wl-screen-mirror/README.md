# Wayland Screen Mirror

This plugin allows you to easily toggle screen mirroring in Wayland via `wl-mirror`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `elijaharch/screen-mirror` |
| Entries | Bar widget: `mirror`; panel: `controls`; service: `mirror-service` |

## Requirements

- [`wl-mirror`](https://github.com/Ferdi265/wl-mirror) available on `PATH`

## Usage

1. Add the `mirror` widget to your bar
2. Open the panel and select the source and destination displays
3. Click on **Start mirroring**

```sh
noctalia msg panel-toggle elijaharch/screen-mirror:controls
```

The service stops mirroring automatically if either selected output disconnects.

## Notes

- The plugin launches
  `wl-mirror --fullscreen-output DESTINATION --fullscreen SOURCE`.
- A private marker and the latest `wl-mirror` error output are written under the
  plugin data directory. No user content is stored.
- The managed process is terminated when mirroring stops, the plugin reloads,
  or Noctalia exits. Other `wl-mirror` processes are not affected.
- The plugin makes no network requests.
