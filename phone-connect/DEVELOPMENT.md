# Phone Connect development

## Module map

| File | Responsibility |
|------|----------------|
| `service.luau` | Service entry: device discovery, device/media controls, translations, saved aliases/images and command dispatch. Starts the messaging service and ticks it once per second. |
| `messaging-service.luau` | Messaging lifecycle: Python helper startup, subscriptions, request deadlines, stale-result rejection, pending operations and published state. |
| `messaging-model.luau` | Pure state reduction, message ordering, number normalization, contact-name lookup and search. No process or filesystem access. |
| `bridge.py` | Typed session D-Bus calls/signals, vCard decoding and temporary contact-photo files. Supports `check`, `request` and `watch` modes. |
| `panel.luau` | Panel lifecycle, shared snapshots, view preferences and tab builders. All three panel placements use this entry. |
| `media-view.luau` | Reusable native media controls with local slider drag state. Receives UI, host API, translation and command callbacks from the panel. |
| `widget.luau`, `tile.luau` | Compact entry points that display device status and open the selected panel placement. |
| `plugin.toml`, `translations/` | Entry IDs, dependencies, settings and translations. English supplies fallback strings. |

The backend owns phone data. Views issue commands and render shared snapshots;
they do not call D-Bus or parse contact files directly.

## Shared state

Noctalia shared state is session memory, cleared when the plugin stops.

| Key | Owner and contents |
|-----|--------------------|
| `pc.devices`, `pc.order`, `pc.selected` | Device service: device records, display order and selected device ID. |
| `pc.backend` | Device service: KDE Connect availability and daemon identity. |
| `pc.aliasMap`, `pc.imageMap` | Device service: per-device aliases and custom image paths, also saved in `state.json`. |
| `pc.trTable` | Device service: flattened translation keys with English fallback. |
| `pc.cmd` | UI/IPC command channel consumed by the service. Each command has an operation, optional device/arguments and a sequence number. |
| `pc.messaging` | Messaging service: `{devices, pending, results, error}`. Device entries contain contacts, threads, fetched messages, notifications, calls, capabilities and loading state. |
| `pc.drafts` | Panel edits; the messaging service clears accepted text. Maps a target to `{text, rev}`. |
| `pc.view` | Panel: active tab, compact mode and per-device selection/search/page preferences. |

`messaging-model.luau` defines the device record. Its principal collections are:

```text
contacts[]                    decoded contacts with numbers and optional photo paths
threads[threadId]              latest message for each conversation
messages[threadId][messageId]  fetched history merged by identity
history[threadId]              loading, start offset, counts and deadline
notifications[notificationId]  current mirrored notifications and available actions
calls[]                       up to 20 observed call events, newest first
```

Message and thread IDs are strings, preserving D-Bus integer identities without
Luau number conversion. Message dates are Unix milliseconds. `direction`
describes the message box; an outgoing message is not proof of delivery. Thread
previews retain the newest message when older history arrives out of order.

Contact matching strips presentation punctuation but does not infer country
codes or use suffix matches. Ambiguous numbers retain their number as a label.
The contact-name index is built lazily and invalidated when contacts change.
Search covers contacts, recipients, previews and fetched message text; it never
requests more history.

## Helper protocol

The helper uses the session bus service `org.kde.kdeconnect`. KDE Connect handles
phone transport and its own caches. The helper has no direct network client.

- `check` verifies that Python can load Gio/GLib and connect to the session bus.
  It writes one JSON result, such as `{"ok":true}`.
- `request '<JSON command>'` performs one operation and exits. It writes exactly
  one JSON object: `{"ok":true,"events":[...]}` or a sanitized error with
  `ok:false` and `message`. The host decodes the complete stdout once, including
  responses larger than 64 KiB. Request output must not use stream framing.
- `watch` stays running and writes newline-delimited events. Each event has a
  `type`; device-specific events also have `device`. It subscribes before its
  initial snapshots and announces `ready` before releasing deferred reads.

Watch events include `capabilities`, `connection`, `contacts`, `threads`,
`message`, `loaded`, `thread_removed`, `notifications`, `notification`,
`notification_removed`, `call`, `removed`, `reset`, `ready`, `heartbeat` and `error`.
`messaging-service.luau` handles lifecycle events and passes device data to the
model reducer.

Noctalia limits individual stream lines to 64 KiB. Events above 48 KiB are
encoded as ASCII JSON and split into 16 KiB fragments wrapped in JSON lines:

```json
{"type":"chunk","index":1,"count":3,"data":"<fragment>"}
```

Indices start at one. The service accepts only consecutive fragments with the
same count and applies the event after reassembly. A new first fragment resets
an incomplete frame. Neither fragment contents nor full events should be logged:
they can contain personal content.

## Requests, drafts and reconnection

The service allows one pending request per target. SMS targets include the
device and thread or recipient; notification replies also include notification
and reply-action identity. This isolates drafts and prevents duplicate sends.

A successful helper request means backend acceptance. It does not establish
delivery. Only an accepted SMS/reply clears its matching draft, and only if the
text still equals the submitted text. Failed or uncertain requests retain text.
The draft revision changes on clearing so the native input is recreated with
the new value; the host treats an input's `value` as its initial value.

Requests capture the daemon generation and device epoch. A daemon reset or
device disconnect invalidates responses from the previous connection. A
notification revision prevents a late snapshot from restoring a notification
removed while that request was in flight.

History requests wait until the watch subscription is ready. A request fetches
50 messages, with contents arriving through signals. The helper emits a
heartbeat every 10 seconds. The service uses a 15-second subprocess timeout,
12-second loading window, 15-second deferred-read deadline and 35-second watcher
health threshold. An incomplete history page remains eligible for another read;
an empty response does not establish that phone permissions are missing.

Daemon owner changes rebuild the watch snapshot. If the helper exits, the
service checks for a matching process before starting a replacement. Noctalia
terminates owned streams when the service reloads or stops.

## Rendering budget

Native callbacks have a small execution budget. `state.get` decodes a fresh
copy, so the panel seeds shared state once and retains `state.watch` snapshots.
Input callbacks and rendering must not reread the whole messaging state.
Watch callbacks request a frame tick; one render consumes the latest snapshots
after a burst. The service similarly publishes incoming signal batches on its
one-second tick, while command pending/results publish immediately.

Conversation, message, contact and notification views build at most 25 rows per
page. Message fetch batches remain 50. Load older traverses cached display pages
before requesting another backend batch. Compact thread mode skips construction
of the hidden conversation list. Closing the panel stops rendering while the
service continues synchronization.

Keep native node keys stable for persistent controls. Reset properties explicitly
when changing an existing node: omitted properties can retain previous values.
Preview uses separate view preferences and never sends commands to the phone.

## Files and processes

`pluginDataDir()/state.json` stores selected-device metadata, aliases and custom
image paths. Messages, notifications, drafts and view preferences stay in memory.

The helper reads KDE Connect's vCards from `$XDG_DATA_HOME/kpeoplevcard/` and
writes supported embedded photos only to
`$XDG_RUNTIME_DIR/noctalia-phone-connect/<device hash>/`. Directories are mode
0700, files 0600, and filenames are content hashes. Unsupported or remote photos
fall back to initials. See [README.md](README.md#notes) for cache limits and
process behavior.

One helper process watches signals. Short-lived helpers handle requests through
argument arrays, so message text is not shell-interpreted. Existing device
controls use `gdbus`, `kdeconnect-cli`, file pickers and openers. Do not include
message arguments in logs or error reports.

## Code style and validation

Use descriptive state names, separate statements and expanded control flow.
Document ownership, data shapes and asynchronous ordering where they are not
obvious. Keep UI construction grouped by tab and pure lookups in the model.
Luau modules exercised by the Lua harness must remain compatible with its Lua
syntax; avoid Luau-only type annotations or compound assignments there.

Formatting uses StyLua 2.6.0 and Black 26.10.1, configured only in this plugin.
They are development tools, not runtime dependencies. From the repository root:

```sh
stylua --config-path phone-connect/stylua.toml --verify phone-connect/*.luau phone-connect/tests/*.lua
black --config phone-connect/pyproject.toml phone-connect/bridge.py phone-connect/tests/test_bridge.py
stylua --config-path phone-connect/stylua.toml --check phone-connect/*.luau phone-connect/tests/*.lua
black --config phone-connect/pyproject.toml --check phone-connect/bridge.py phone-connect/tests/test_bridge.py
```

Run the suites in [TESTING.md](TESTING.md) after behavior changes. Preserve entry
IDs, settings keys and IPC operation names when refactoring.
