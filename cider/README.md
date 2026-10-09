# Cider

Cider track-change alerts as Noctalia notifications or a rich now-playing card, plus a sticky karaoke lyrics HUD.

Adds Cider-specific track alerts and lyrics alongside Noctalia’s media controls.

## Plugin

| Field        | Value                                                      |
| ------------ | ---------------------------------------------------------- |
| ID           | `dragged/cider`                                            |
| Entries      | Bar widget: `now-playing`; panel: `osd`; service: `bridge` |
| Dependencies | Base tools and GTK; compositor/audio helpers as described below |

## Requirements

- Noctalia v5.2.1 recommended. Manifest, Luau, IPC, and GTK theme integration checked against its official source; `plugin_api` remains 24 (the oldest API used, available since v5.0.0-beta.9). Niri and Hyprland keep left-click = lyrics HUD.
- Cider with Connectivity / External API enabled
- Python 3.11+ (`python3` on `PATH`), with `python-socketio`, `requests`, and `websocket-client` (`pip install -r requirements.txt` from this plugin directory)
- Overlay HUD: `gtk3`, `gtk-layer-shell`, and `python-gobject`. Untimed silence gate optionally uses `parec` (PulseAudio / PipeWire).
- Base tools: `bash`, `sh`, `pkill`, and `coreutils` (`cat`, `dirname`, `mkdir`, `rm`, `sleep`) launch and stop the bundled helpers. Noctalia's own CLI handles plugin IPC.
- Conditional helpers: `niri` on Niri, `hyprctl` on Hyprland, or `umbriel` on Umbriel for window probes; `xdotool` for Xwayland window hide/show and main-window isolation while the mini is open; `parec` only for the optional silence gate. Install the tools for your compositor/features, not every compositor. The manifest lists these commands for disclosure; Noctalia does not block enabling the plugin if a conditional helper is absent.
- Umbriel loft (middle-click): `umbriel` on `PATH` with output-based scratchpad IPC (verified on 0.1.0). No-op on other compositors.

## Usage

1. Enable **Cider** in Settings → Plugins (or `noctalia msg plugins enable dragged/cider`).
2. Open **Settings → Plugins → Cider** and set the API token, or leave it empty to reuse `~/.config/cider-kde-notifier/config.json`.
3. Add bar widget `dragged/cider:now-playing`. **Left-click** toggles the sticky lyrics HUD. **Middle-click** lofts Cider to the Umbriel scratchpad (and restores it). **Right-click** shows the OSD card. All three are remappable in the widget editor (`[widget.actions]`).
4. **Do not put Cider on** `shell.mpris.blacklist` — that also kills Control Center / Media Now Playing.
5. Hide Cider app toasts with a notification filter (not an MPRIS blacklist). Plugin toasts use app name `Now Playing` / desktop entry `noctalia-now-playing`:

```toml
[notification.filter.cider_app]
enabled = true
match = "cider"
show_toast = false
play_sound = false
save_history = false
```

Put `cider_app` first in `notification.filter_order`.

6. Optional — hide the stock track-change OSD. This shell setting applies to **every player**; leave it enabled to keep stock popups for other players:

```toml
[osd.kinds]
media = false
```

### Panels

```sh
noctalia msg panel-toggle dragged/cider:osd
```

`osd` is the now-playing card (also opened automatically on track change when **Track alert** is OSD). It is a persistent floating panel. Lyrics always use the gtk-layer-shell overlay. Noctalia 5.2.1 exposes the panel’s position and layer overrides under **Settings → Plugins** (gear on this plugin).

Cider’s MPRIS has no synced lyrics. The bridge pulls Apple Music TTML via Cider’s amapi (LRCLIB fallback) for the sticky HUD.

The bridge polls Cider's v2 playback clock every 100 ms. While that clock is healthy, it owns playback updates so delayed engine Socket.IO samples cannot undo a seek. Older or unsupported v2 endpoints use the existing v1 snapshot. Failed v2 requests release playback to Socket.IO until a healthy snapshot takes over again.

Natural next-line advances keep the depth animation. Preview and current lyrics share glyph layout and wrapping; source timing takes over their color within 60 ms while depth travel continues. Incoming previews fade in as they approach. Line-changing seeks fly through the actual intervening lyric rows on a continuous perspective path, forward or backward. Short skips travel slowly over less distance; large skips travel faster, settling within 360–520 ms. Incoming rows fade during their visible arrival; outgoing rows stay opaque until outside the viewport. Very large skips can pass rows between rendered frames. Retargeting starts from the last visible composite and the nearest row in flight. Within-line word updates blend without fading shared glyphs. GTK's frame clock drives drawing independently of the playback polling timer.

Outgoing lyrics retain their opacity while passing above the HUD viewport; they stop drawing only after the glyphs and shadow have left it. Source syllables highlight individually: sung spans settle to the sung color, the current span picks up the accent, and future spans stay muted. Whole-word highlighting does not override syllable timing.

With source word or character timings, the sung word gently grows by up to 2.5% and returns to normal over its timed interval, settling before the next word. Held words stretch the same motion over their full duration, with a soft peak and zero velocity and acceleration at each boundary. Syllables in one word move together; glyph advances and wrapping stay fixed. Preview text, line-only lyrics, and disabled karaoke do not pulse. No word durations are invented.

The v2 clock accepts short backward seeks when its reported position decreases; unchanged samples leave interpolation alone. On the legacy v1/Socket.IO fallback, backward scrubs shorter than 1.5 seconds while playing still resemble timing jitter and are suppressed; paused scrubs and larger seeks are supported.

### Bar chip clicks

Defaults are remappable in the widget editor.

| Click | Umbriel | Niri / Hyprland |
| --- | --- | --- |
| Left | Lyrics HUD | Lyrics HUD |
| Middle | Hide/show that Cider window | Lyrics HUD (`chip-left` dispatcher) |
| Right | Track OSD | Track OSD |

### Cider windows on Umbriel

The bridge prefers `Cider - Mini Player` while it exists. Native Umbriel window events trigger mini-player reconciliation; older builds without subscriptions use a 100 ms fallback. Closing the mini restores the main only if the bridge hid it. Restoring the main yourself releases that ownership once the bridge observes it. A manually hidden main stays hidden. Middle-click and the launcher restore hook target the mini while it is open.

Window-only helpers skip playback-library initialization and repeated hidden-window focus probes. Xwayland hide/show uses native close/open animations. Restore chooses the destination before mapping; it never maps onto one workspace and moves afterward.

For Cider running through Xwayland, an installed `xdotool` lets the bridge unmap the selected main or mini window without closing Cider or stopping playback. Show restores it into the current workspace by default. Enable **Remember Cider workspace** to select its saved workspace before it opens. The bridge records and revalidates the X11 window, PID, and process start time before restoring that same window. While the mini exists, the main remains unmapped even when the mini is hidden. Closing the mini returns the owned main using the same workspace preference and its saved floating mode where known; exact tiled position and floating coordinates are not preserved by Umbriel's IPC. Restoring the main yourself releases ownership.

For compact sizing from the first frame, put this after any catch-all tiling rule in your Umbriel config:

```toml
[[window_rule]]
match.app_id = "^[Cc]ider$"
match.title = "^Cider - Mini Player$"
default_floating = true
```

The bridge also floats a newly detected mini when no rule is installed, but a rule avoids the initial tiled frame. Existing stretched minis must close and reopen once to recover their natural size.

Scratchpad transitions have their own animation switch. To use a smooth fade without a dimmed backdrop:

```toml
[animation.scratchpad]
enabled = true
duration_ms = 250
curve = "easeout"
dim = 0.0
blur = false
```

This affects all scratchpads. The plugin leaves compositor configuration to the user.

Restore waits for this native fade before returning the window to its workspace, so tiling cannot cut the fade short. Timing is read from `$XDG_CONFIG_HOME/umbriel/config.toml` (normally `~/.config/umbriel/config.toml`) and its included files. For a custom `umbriel -c` file, set `CIDER_UMBRIEL_CONFIG` to that path in the environment of both Noctalia and the Cider launcher. If the file cannot be read, restoration waits 250 ms.

Noctalia 5.2.1 excludes scratchpad windows from dock window candidates, so a pinned dock item launches its desktop entry while Cider is hidden. Add this to your existing Cider launcher before its original launch command, replacing the script path with your installed plugin path:

```bash
if [[ $# -eq 0 ]]; then
  python3 /absolute/path/to/cider/scripts/cider_bridge.py --show-window
  case $? in
    0) exit 0 ;; # Existing mini/main restored; do not relaunch Cider.
    2) exit 2 ;; # IPC/restore failed; do not launch a duplicate.
  esac
fi
# Keep the original Cider launch command and "$@" below this block.
```

Keep the desktop entry's `Exec` pointing at that launcher. URL arguments bypass the hook and reach the original Cider command. Exit 1 means no existing Cider window was found, or another compositor is in use. The hook never starts the playback bridge or changes playback sidecars.

Without `xdotool`, with native Wayland Cider, or when a unique window cannot be verified, the bridge keeps Umbriel's output-based scratchpad fallback, verified on 0.1.0. That IPC always restores to the saved workspace: current-workspace restoration is unavailable on this fallback. When the saved workspace is known, the bridge switches there before revealing it. Other hidden members in the same pad may briefly appear while a target is restored; previously hidden siblings are hidden again afterward. Newer named-scratchpad IPC requires matching compositor integration.

`toggle-loft` is also a bindable IPC event. It is a no-op when Cider is not running or the window id is unknown. Lyrics and OSD IPC stay unaliased.

## Settings

| Setting                   | Type     | Default                  | Description                                                                 |
| ------------------------- | -------- | ------------------------ | --------------------------------------------------------------------------- |
| `apptoken`                | `string` | `""`                     | Cider Connectivity token. Empty reuses the KDE notifier config file.        |
| `base_url`                | `string` | `http://127.0.0.1:10767` | Cider HTTP API.                                                             |
| `display_mode`            | `select` | `notification`           | Track-change alert: notification, `osd` panel, or off.                      |
| `osd_duration_ms`         | `int`    | `4500`                   | How long the notification or now-playing OSD stays visible (1000–20000 ms). |
| `remember_workspace`      | `bool`   | `false`                  | Umbriel/Xwayland: restore into the current workspace, or select the saved workspace before showing Cider. |
| `lyrics_osd_enabled`      | `bool`   | `true`                   | Master switch for the sticky lyrics HUD.                                    |
| `lyrics_osd_position`     | `select` | `top_center`             | Overlay HUD edge.                                                           |
| `lyrics_osd_show_next`    | `bool`   | `true`                   | Dim upcoming lyric line.                                                    |
| `lyrics_osd_animate_cues` | `bool`   | `true`                   | Animate intro cue dots.                                                     |
| `lyrics_osd_karaoke`      | `bool`   | `true`                   | Word-level sing-along when Apple timings exist.                             |
| `lyrics_osd_glow`         | `bool`   | `true`                   | Overlay-only drop shadow under glyphs.                                      |
| `lyrics_karaoke_style`    | `select` | `theme`                  | Theme role tokens vs custom hex.                                            |
| `lyrics_karaoke_sung`     | `color`  | `#f2f3f3`                | Custom sung-word hex.                                                       |
| `lyrics_karaoke_active`   | `color`  | `#83c2c8`                | Custom active-word hex.                                                     |
| `lyrics_karaoke_upcoming` | `color`  | `#b2b2b8`                | Custom upcoming-word hex.                                                   |
| `lyrics_osd_show_idle`    | `bool`   | `true`                   | Idle placeholder when the HUD is open with no lyrics.                       |
| `lyrics_show_untimed`     | `bool`   | `false`                  | Show plain (no-timestamp) lyrics. Off = hide them; synced lyrics still show. |
| `lyrics_plain_scroll`     | `bool`   | `false`                  | Opt-in / advanced: advance untimed lyrics across the song length.           |
| `lyrics_plain_scroll_speed` | `int`  | `100`                    | Plain-lyrics scroll pace (%; 25–300).                                       |
| `lyrics_plain_scroll_silence` | `bool` | `false`                | Opt-in / advanced: hold scroll while system audio is quiet (`parec`).       |
| `lyrics_plain_scroll_silence_level` | `int` | `8`              | Quiet threshold 1–40.                                                       |
| `show_cover`              | `bool`   | `true`                   | Bar widget: show artwork.                                                   |
| `cover_size`              | `int`    | `18`                     | Bar widget artwork size, 12–32 px.                                          |
| `glyph`                   | `glyph`  | `music`                  | Bar widget fallback icon when artwork is hidden/missing.                    |

Gap under the bar is shell-global: **Settings → Shell → Panel → floating offset**.

## IPC

```sh
noctalia msg plugin dragged/cider:bridge all show-osd
noctalia msg plugin dragged/cider:bridge all hide-osd
noctalia msg plugin dragged/cider:bridge all toggle-lyrics-hud
noctalia msg plugin dragged/cider:bridge all show-lyrics-hud
noctalia msg plugin dragged/cider:bridge all hide-lyrics-hud
noctalia msg plugin dragged/cider:bridge all chip-left
noctalia msg plugin dragged/cider:bridge all toggle-loft
```

## Notes

- **Network:** the Python bridge uses HTTP and Socket.IO with Cider’s Connectivity API (`base_url`). Lyrics use Cider `amapi/run-v3` (Apple Music TTML) with `https://lrclib.net/api/get` as fallback. Artwork uses track-supplied cover URLs (normally Apple Music CDN); those requests do not carry the Cider token. No remote code is downloaded or executed.
- **Processes:** `scripts/start-bridge.sh` launches `scripts/cider_bridge.py`. The lyrics HUD is `scripts/lyrics_overlay.py`. Umbriel loft and launcher restoration are one-shot `python3 cider_bridge.py --toggle-loft` / `--show-window` (do not restart the bridge). Disable/uninstall stops helpers via `onExit`.
- **Filesystem:** runtime JSON, artwork, loft latch, miniplayer ownership (`miniplayer.json`), the window-action lock, and the Cider API token file live under `~/.cache/noctalia-cider/`. Durable settings also go to `noctalia.pluginDataDir()`. `ui.image` only loads local cover files after the bridge downloads them. Detached process logs: `/tmp/noctalia-cider-bridge.log`, `/tmp/noctalia-cider-lyrics-overlay.log`.
- **Helpers:** window probes run `niri msg`, `hyprctl`, or `umbriel windows --json`; loft uses `umbriel msg`. The optional audio meter spawns `parec` to read system-output audio for silence detection. Launch/cleanup uses `bash`, `sh`, `pkill` for the bridge, and pidfile-based `kill` for the overlay; `coreutils` supplies file/directory and sleep commands. Helpers write PID files in the cache. The bridge can read the existing token/settings from `~/.config/cider-kde-notifier/config.json` when plugin credentials are empty.
- **Compositor:** Umbriel window handling uses `umbriel subscribe windows,workspaces`, `umbriel workspaces --json`, and `umbriel msg` (`window-focus`, `window-toggle-floating`, `window-move-to-scratchpad`, `scratchpad-toggle`, `window-restore-from-scratchpad`, `workspace-switch`). Window focus is verified before acting on the compositor's focused window. The optional Xwayland path runs `xdotool` window identity/geometry queries, `windowunmap`, and `windowmap`, and reads `/proc/<pid>/stat` to validate ownership. No compositor config, launcher, or desktop entry is rewritten by the plugin.
- **Panels:** `panel-open` / `panel-close` are used instead of `togglePanel` so a persistent toast is never inverted if it is already open.
- **Notification history:** Noctalia 5.2.1’s internal plugin toasts are never stored in history. The former `save_to_history` switch was removed because the host ignored it.
- Local path source for development:

```sh
noctalia msg plugins source add cider-local path /path/to/noctalia-plugin
noctalia msg plugins enable dragged/cider
noctalia msg config-reload
noctalia plugins lint /path/to/noctalia-plugin/cider
```
