# ShareDND

Automatic Do Not Disturb while the screen is being shared.

When the first screencast starts (any app sharing via the portal — Discord,
OBS, browsers, `niri msg action set-dynamic-cast-*`, ...), notification DND is
enabled. When the last screencast stops, notifications come back.

## How it works

- A headless service follows `niri msg -j event-stream` and reacts to
  `CastsChanged` / `CastStartedOrChanged` / `CastStopped` events — no polling.
- On every cast event it re-queries `niri msg -j casts` as the authoritative
  state, so missed or reordered events cannot desync it. The stream is wrapped
  in a shell retry loop and resends full state on reconnect.
- Stop transitions are debounced by ~1 second: switching what is being shared
  produces a stop/start event pair, which the debounce collapses — DND does
  not flap, and the stop/start race cannot drop ownership.
- DND is toggled through the host IPC (`noctalia msg notification-dnd-set`),
  so the usual OSD feedback appears.

## Ownership rules

- If DND was **already on** before sharing started, the plugin leaves it on
  after sharing ends (it never took ownership). The
  "Always disable DND after sharing" setting overrides this.
- If DND was enabled manually *during* sharing while the plugin owned it, it
  will still be turned off when sharing ends (the plugin cannot tell the
  difference).

## Settings

- **Only active streams** — count only casts with `is_active: true`. Off by
  default: any open screencast session (even paused or showing nothing) keeps
  DND on.
- **Always disable DND after sharing** — force DND off when sharing ends,
  regardless of its state before sharing started.

## Requirements & limitations

- Requires **niri** (detection is niri IPC). Detection only starts inside a
  niri session (`NIRI_SOCKET` set and the `niri` binary in `PATH`); on other
  compositors the service is inert and spawns no processes.
- Disabling or reloading the plugin mid-share while it owns DND turns DND
  back off (`onExit` cleanup).
