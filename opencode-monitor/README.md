# OpenCode Monitor

A read-only Noctalia bar widget and panel that shows what local OpenCode sessions are doing right now.

## Plugin

| Field | Value |
|---|---|
| ID | `faented/opencode-monitor` |
| Entries | `widget`, `panel`, `service` |

The plugin contains a bar `widget`, an attached `panel`, and a background `service` that polls the local OpenCode API every two seconds.

## Requirements

- Noctalia 5.x or newer with Plugin API level 33.
- A local OpenCode v2 service. The plugin reads its URL, password, version, and PID from `$XDG_STATE_HOME/opencode/service.json` (normally `~/.local/state/opencode/service.json`).
- No external commands, API keys, or cloud services are required.

## Usage

1. Add the `widget` to a Noctalia bar.
2. Left-click the widget to open the `panel`, or run:

```
noctalia msg panel-toggle faented/opencode-monitor:panel
```

The panel groups sessions into **Needs attention**, **Running**, **Recent**, and **Subagents**. Running cards show the current tool or reasoning activity, elapsed time, tokens, and cost. Waiting cards show permission or input requests. Recent cards show completed, failed, or idle sessions. A parent card with children opens its **Subagents** section by default; the chevron collapses or expands it.

The panel is read-only. Prompts, permissions, and input forms are answered in the OpenCode TUI; the plugin never sends prompts, creates sessions, or changes permissions.

## Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `poll_interval` | integer (1–15) | `2` | Seconds between polls of the local OpenCode API. |
| `recent_minutes` | integer (1–1440) | `120` | Only sessions updated within this window appear in Recent. |
| `recent_count` | integer (1–30) | `8` | Maximum number of recent sessions shown. |
| `display_mode` | select | `activity` | Bar display: `activity`, `counts`, or `dots`. |
| `show_label` | boolean | `true` | Show text next to the bar icon. |
| `label_width` | integer (8–60) | `26` | Maximum characters in the bar label. |
| `glyph` | glyph | `robot` | Icon used when OpenCode is idle. |
| `show_children` | boolean | `true` | Include child and subagent sessions in the bar widget. The panel always shows them. |

## Security and limits

- **Read-only and GET-only.** The plugin never calls prompt, session-creation, permission, interrupt, or other mutation endpoints. It has no custom connection or launcher settings.
- **Loopback only.** Service discovery accepts only `http://127.0.0.1`, `http://localhost`, or `http://[::1]`, without userinfo, query, fragment, or path. Redirects are disabled.
- **Password containment.** The Basic-auth password stays in memory and is never published in the snapshot, panel, widget, or logs.
- **Redaction.** Session titles, parent titles, activity, reasoning and response excerpts, tool inputs, permission and form text, URLs, warnings, and errors are bounded and secret-scanned before display. The full project directory is not published; only a shortened display path is kept. Agent, outcome, and model names are truncated but are not secret-scanned.
- **Bounds.** Responses over 2 MiB are rejected before JSON decoding. The session list is capped at 200, active sessions at 64, and details are fetched for at most 8 active sessions with at most 3 concurrent requests. Missing data is shown as `partial data`.
- **Subagent bounds.** The flat parent-to-child index is built once per poll without extra HTTP requests. The panel shows at most 12 related rows, to depth 3, with at most 200 nodes per tree; larger trees show `showing X of Y`.
- **Host limits.** Noctalia buffers HTTP bodies before the plugin can reject them, does not expose owner/mode/symlink checks for `service.json`, cannot cancel in-flight requests, and enforces a 25 ms update-callback budget. The plugin keeps work outside that budget and degrades to partial data rather than failing the service.

## Notes

- The plugin stores no secrets and ships no test credentials.
- Tool output is never retained. Only a short, redacted summary of the newest activity is shown.
- The panel is an attached layer; it can be moved to another monitor in Noctalia's panel settings. Press Escape or click outside to close it.
- If the panel shows **OpenCode is not running**, start OpenCode and wait for the next poll. If a session has no Recent entry, increase `recent_minutes`.
