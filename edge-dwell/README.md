# Niri Edge Dwell

Focus the adjacent Niri column by holding the pointer against the left or right edge for 500 ms. Leaving the edge cancels a pending hold; after one action, leave and re-enter to trigger it again.

## Plugin

`omid511/edge-dwell` uses the `edge-service` service to show its `left` and `right` layers.

Each output has a one-logical-pixel strip, with a 40 px top margin and a 12 px bottom margin. The strips do not take keyboard focus or reserve screen space.

## Requirements

- Noctalia plugin API 36 or newer.
- Niri, with `niri` available on Noctalia's `PATH` and a working Niri IPC connection.

## Usage

Install the plugin through a Noctalia plugin source or place this directory in `$XDG_DATA_HOME/noctalia/plugins/edge-dwell/` (normally `~/.local/share/noctalia/plugins/edge-dwell/`). Enable `omid511/edge-dwell` in **Settings → Plugins**, or run:

```sh
noctalia msg plugins enable omid511/edge-dwell
```

Alternatively, add the ID to the existing `enabled` list in Noctalia's `config.toml`:

```toml
[plugins]
enabled = ["omid511/edge-dwell"]
```

Preserve other entries already in the list. An app-owned `[plugins].enabled` override in `settings.toml` can take precedence over this configuration.

## Limitations

- Niri only: this uses `niri msg` IPC and its `focus-column-left` / `focus-column-right` actions.
- The pointer's edge output must already be Niri's focused output when the focused-output query completes. The plugin does not focus another output; focusing can change between the query and action.
- The one-pixel layer-shell strips intercept pointer input, including clicks, along the active portions of the edges. They are not click-through; the top and bottom margins leave those edge segments uncovered.
- A failed IPC query or an unknown output produces no action. Holds are polled, so activation may happen slightly after 500 ms.

## License

MIT; see [LICENSE](LICENSE).
