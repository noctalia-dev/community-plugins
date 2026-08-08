# OpenCode Companion — Research Notes

Research conducted: 2026-08-06
Researcher: Senior Linux Desktop Plugin Enginee

---

## Environment Survey

| Component | Version | Notes |
| --- | --- | --- |
| Noctalia | v5.0.0 (97917d9ca07e) | Current installed version |
| OpenCode | 1.18.13 | Installed at `/usr/bin/opencode` |
| Shell | sh (sandbox) | Network access requires elevated perms |
| Boot ID | `bedc954f-1f74-4f19-86b6-6b5bc00c12a5` | From `/proc/sys/kernel/random/boot_id` |

---

## Noctalia Plugin API Discovery

### Plugin API Version

`plugin_api = 3` is chosen. Rationale:
- Covers every feature needed: `[[panel]]`, `ui.*` controls, plugin IPC dispatch, `barWidget.*`, `onIpc`.
- `[[service]]` entry kind requires `plugin_api >= 3` (confirmed from claude-companion which uses 3).
- `plugin_api = 4` (used by llamanager) is supported but not required; no level-4-only feature is needed.
- The Noctalia 5.0.0 beta manifest parser **requires** the `plugin_api` key (replaces older `min_noctalia`).

### Entry Architecture

Three entries confirmed supported:
- `[[widget]]` — bar widget (uses `barWidget.*`)
- `[[panel]]` — panel (uses `panel.render`, `onOpen`, `onClose`, `update`)
- `[[service]]` — headless background service (uses `onIpc`, state management, event-driven)

### Key Runtime API Functions

| Function | Signature | Notes |
| --- | --- | --- |
| `noctalia.state.set` | `(key: string, value: any)` | Plain-data only; no functions |
| `noctalia.state.get` | `(key: string) -> any` | Returns nil if absent |
| `noctalia.state.watch` | `(key: string, callback)` | Fires across runtimes |
| `noctalia.http` | `(request, callback)` | Returns `{ok, status, body}` |
| `noctalia.httpStream` | `(request, onProgress, onFinish)` | SSE streaming |
| `noctalia.json.encode` | `(obj) -> string` | |
| `noctalia.json.decode` | `(str) -> any` | |
| `noctalia.notify` | `(title, message)` | Desktop notification |
| `noctalia.notifyError` | `(title, message)` | Error notification |
| `noctalia.togglePanel` | `(panelId)` | Toggle panel visibility |
| `noctalia.getConfig` | `(key) -> any` | Read plugin setting |
| `noctalia.commandExists` | `(cmd) -> bool` | Check executable |
| `noctalia.runAsync` | `(cmd, callback)` | Async shell command |
| `noctalia.runInTerminal` | `(cmd)` | Open in terminal |
| `noctalia.expandPath` | `(path) -> string` | Expand `~` |
| `noctalia.fileExists` | `(path) -> bool` | |
| `noctalia.readFile` | `(path) -> string` | |
| `noctalia.writeFile` | `(path, content)` | |
| `noctalia.removeFile` | `(path)` | |
| `noctalia.listDir` | `(path) -> string[]` | |
| `noctalia.isDarkMode` | `() -> bool` | |
| `noctalia.tr` | `(key, args?) -> string` | Translation |
| `noctalia.getenv` | `(name) -> string?` | |
| `noctalia.copyToClipboard` | `(id, type)` | |
| `noctalia.setUpdateInterval` | `(ms)` | Bar widget tick interval |

### UI Components Available

| Component | Props | Notes |
| --- | --- | --- |
| `ui.column` | `{ gap, padding, flexGrow, justify, align }` | Vertical layout |
| `ui.row` | `{ gap, padding, flexGrow, justify, align }` | Horizontal layout |
| `ui.label` | `{ text, fontSize, fontWeight, color, maxWidth, maxLines, opacity, textAlign }` | Text display |
| `ui.button` | `{ text, glyph, onClick, tooltip, variant, flexGrow }` | Clickable |
| `ui.glyph` | `{ name, color, size, opacity, width, height }` | Tabler icon |
| `ui.scroll` | `{ flexGrow }` | Scrollable container |
| `ui.spacer` | `{ height?, width? }` | Empty space |
| `ui.separator` | `{ spacing? }` | Divider line |
| `ui.input` | `{ value, placeholder, onChange, multiline, flexGrow }` | Text input |
| `ui.select` | `{ options, onChange, placeholder, flexGrow }` | Dropdown |

### Panel-specific API

| Function | Notes |
| --- | --- |
| `panel.render(ui)` | Render the panel |
| `panel.setWantsSecondTicks(bool)` | Enable/disable second ticks |
| `onOpen(context)` | Called when panel opens |
| `onClose()` | Called when panel closes |
| `update()` | Called on tick (if ticks enabled) |

### Widget-specific API

| Function | Notes |
| --- | --- |
| `barWidget.setGlyph(name)` | Set Tabler icon |
| `barWidget.setGlyphColor(color)` | Set icon color |
| `barWidget.setTooltip(text)` | Set tooltip |
| `onClick()` | Left click handler |
| `onRightClick()` | Right click handler |
| `update()` | Called on tick interval |
| `noctalia.setUpdateInterval(ms)` | Set tick rate |

### Service-specific API

| Function | Notes |
| --- | --- |
| `onIpc(event, payload)` | Handle IPC messages |
| `update()` | Optional tick handler |

### Shared State Pattern

- Service is single source of truth — publishes to `noctalia.state`
- Widgets and panels are pure subscribers — watch state and render
- State must be plain JSON-serializable data (no functions)
- State keys follow `plugin_name.field` convention (e.g., `opencode.connection`)

### IPC Pattern

- Use `noctalia.msg plugin <id>:<entry> all <event> [payload]` to send IPC
- The `all` addresses all widget instances
- Payloads are single space-free tokens (use CSV, not JSON)

---

## OpenCode API Discovery

### Server Management

| Command | Notes |
| --- | --- |
| `opencode serve [--port N] [--hostname H] [--cors origin]` | Start headless HTTP server |
| Default port | `4096` |
| Default hostname | `127.0.0.1` (loopback only) |
| `OPENCODE_SERVER_PASSWORD` | Enable HTTP basic auth |
| `OPENCODE_SERVER_USERNAME` | Override default username (`opencode`) |

### Verified Endpoints

#### Global

| Method | Path | Response |
| --- | --- | --- |
| GET | `/global/health` | `{ healthy: bool, version: string }` |
| GET | `/global/event` | SSE stream |

#### Sessions

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| GET | `/session` | — | `Session[]` |
| POST | `/session` | `{ parentID?, title? }` | `Session` |
| GET | `/session/status` | — | `{ [sessionID]: SessionStatus }` |
| GET | `/session/:id` | — | `Session` |
| DELETE | `/session/:id` | — | `boolean` |
| PATCH | `/session/:id` | `{ title? }` | `Session` |
| POST | `/session/:id/abort` | — | `boolean` |
| POST | `/session/:id/share` | — | `Session` |
| DELETE | `/session/:id/share` | — | `Session` |
| POST | `/session/:id/permissions/:permissionID` | `{ response, remember? }` | `boolean` |
| POST | `/session/:id/fork` | `{ messageID? }` | `Session` |

#### Messages

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| GET | `/session/:id/message?limit=N` | — | `{ info: Message, parts: Part[] }[]` |
| POST | `/session/:id/message` | `{ messageID?, model?, agent?, noReply?, system?, tools?, parts }` | `{ info: Message, parts: Part[] }` |
| GET | `/session/:id/message/:messageID` | — | `{ info: Message, parts: Part[] }` |
| POST | `/session/:id/prompt_async` | Same as `/message` | `204 No Content` |

#### Provider / Model

| Method | Path | Response |
| --- | --- | --- |
| GET | `/provider` | `{ all: Provider[], default: {...}, connected: string[] }` |
| GET | `/config/providers` | `{ providers: Provider[], default: {[key]: string} }` |

#### Agent

| Method | Path | Response |
| --- | --- | --- |
| GET | `/agent` | `Agent[]` |

#### MCP

| Method | Path | Response |
| --- | --- | --- |
| GET | `/mcp` | `{ [name]: MCPStatus }` |
| POST | `/mcp` | body: `{ name, config }` |

#### Events

| Method | Path | Response |
| --- | --- | --- |
| GET | `/event` | SSE stream (first event: `server.connected`) |

### Data Types (Verified from Live Server)

#### Session

```json
{
  "id": "ses_0292b9f65ffeUYVLls5sGGc3mv",
  "slug": "brave-sailor",
  "projectID": "global",
  "directory": "/home/weinguyen",
  "path": "home/weinguyen",
  "summary": { "additions": 0, "deletions": 0, "files": 0 },
  "cost": 0,
  "tokens": {
    "input": 43586,
    "output": 2351,
    "reasoning": 286,
    "cache": { "read": 1174528, "write": 0 }
  },
  "title": "...",
  "agent": "build",
  "model": { "id": "longcat-2.0-free", "providerID": "opencode", "variant": "high" },
  "version": "1.18.13",
  "time": { "created": 1786015670426, "updated": 1786015993254 },
  "permission": [{ "permission": "...", "pattern": "...", "action": "..." }]
}
```

#### Message

```json
{
  "info": {
    "parentID": "msg_...",
    "role": "assistant",
    "mode": "build",
    "agent": "build",
    "variant": "high",
    "path": { "cwd": "/home/weinguyen", "root": "/" },
    "cost": 0,
    "tokens": { "total": 123235, "input": 565, "output": 45, "reasoning": 1, "cache": { "write": 0, "read": 122624 } },
    "modelID": "longcat-2.0-free",
    "providerID": "opencode",
    "time": { "created": 1786015979735, "completed": 1786015984544 },
    "finish": "tool-calls",
    "id": "msg_...",
    "sessionID": "ses_..."
  },
  "parts": [
    { "type": "step-start", "id": "prt_...", "sessionID": "ses_...", "messageID": "msg_..." },
    { "type": "reasoning", "text": "...", "time": { "start": ..., "end": ... }, "id": "prt_...", "sessionID": "ses_...", "messageID": "msg_..." },
    {
      "type": "tool",
      "tool": "write",
      "callID": "call_...",
      "state": {
        "status": "completed",
        "input": { "filePath": "...", "content": "..." },
        "output": "Wrote file successfully.",
        "metadata": { "diagnostics": {}, "filepath": "...", "exists": true, "truncated": false },
        "title": "...",
        "time": { "start": ..., "end": ... }
      },
      "id": "prt_...",
      "sessionID": "ses_...",
      "messageID": "msg_..."
    },
    { "type": "text", "text": "...", "time": { "start": ..., "end": ... }, "id": "prt_...", "sessionID": "ses_...", "messageID": "msg_..." },
    { "reason": "stop", "type": "step-finish", "tokens": {...}, "cost": 0, "id": "prt_...", "sessionID": "ses_...", "messageID": "msg_..." }
  ]
}
```

#### Part Types Observed

- `step-start` — beginning of a step
- `reasoning` — reasoning text
- `text` — response text
- `tool` — tool call with state
- `step-finish` — end of step (with `reason`: "stop", "tool-calls")

#### Provider

```json
{
  "id": "opencode",
  "name": "OpenCode",
  "source": "builtin",
  "env": [],
  "options": {},
  "models": {
    "model_id": {
      "id": "...",
      "providerID": "opencode",
      "name": "...",
      "family": "...",
      "capabilities": {...},
      "cost": {...},
      "limit": {...},
      "status": "active",
      "variants": {}
    }
  }
}
```

#### Agent

```json
{
  "name": "build",
  "description": "The default agent. Executes tools based on configured permissions.",
  "mode": "primary",
  "native": true,
  "permission": [{ "permission": "...", "pattern": "...", "action": "allow|ask|deny" }]
}
```

#### MCPStatus

```json
{
  "context7": { "status": "connected" },
  "firecrawl": { "status": "connected" },
  "serena": { "status": "failed", "error": "Executable not found..." },
  "gimp": { "status": "disabled" }
}
```

Status values: `"connected"`, `"failed"`, `"disabled"`

### SSE Events

From live testing, the first event is always:
```
data: {"id":"evt_...","type":"server.connected","properties":{}}
```

From GitHub issues and docs, the following event types exist:
- `server.connected` — first event after connecting
- `message.part.updated` — a message part was updated
- `message.updated` — a message was updated
- `session.status` — session status changed
- `session.idle` — session went idle

The SSE format is standard: `data: <json>\n\n`

---

## Reference Plugins Studied

### 1. claude-companion (lowcache/claude-companion)

**Why**: Most architecturally similar — service aggregator pattern, pure subscriber widgets, IPC-based.

**Key learnings**:
- `plugin_api = 3` with `[[service]]` entry
- Service is single source of truth, publishes to `noctalia.state`
- Widgets/panels are pure subscribers via `state.watch`
- `panel.setWantsSecondTicks(true)` for live updates
- `onOpen`/`onClose` lifecycle hooks
- Fingerprinting to avoid unnecessary re-renders
- `noctalia.tr()` for i18n
- `ui.scroll` with `flexGrow` for scrollable content
- Header/body/footer panel layout pattern
- Separator usage between sections

### 2. llamanager (marccvictoria/llamanager)

**Why**: Shows HTTP API integration pattern, uses `noctalia.http` and `noctalia.httpStream`.

**Key learnings**:
- `plugin_api = 4`
- `noctalia.http(request, callback)` pattern
- `noctalia.httpStream(request, onProgress, onFinish)` for streaming
- Command execution via `noctalia.runAsync`
- `noctalia.state.watch` for command dispatch
- Multiple views in single panel via state machine
- `ui.input` with `multiline = true` for text input
- Shell escaping helper function

### Key Patterns from Both

1. Service publishes state, views subscribe
2. Fingerprinting to avoid re-render on no-op ticks
3. Separator + scroll + flexGrow for scrollable panels
4. Button with glyph for actions
5. Label with fontWeight="bold" for headers
6. Error color fallback as RGB constant

---

## Architecture Decisions

### 1. Three-Entry Architecture

```
plugin.toml
widget.luau    — bar widget (pure view of connection state)
panel.luau     — chat panel (session picker + chat UI)
service.luau   — headless backend (API client, server lifecycle, state)
```

### 2. Plugin API Level

`plugin_api = 3` — sufficient for all required features, maximally compatible.

### 3. State Schema

Service publishes these keys to `noctalia.state`:
- `opencode.connection` — `{ status: "online"|"starting"|"busy"|"offline"|"waiting_permission", error?: string }`
- `opencode.server_version` — `string`
- `opencode.active_session` — `Session | null`
- `opencode.sessions` — `Session[]`
- `opencode.messages` — `{ info: Message, parts: Part[] }[]`
- `opencode.session_status` — `{ [sessionID]: "idle"|"processing"|"error" }`
- `opencode.pending_permissions` — `Permission[]`
- `opencode.mcp_status` — `{ [name]: MCPStatus }`
- `opencode.providers` — `Provider[]`
- `opencode.agents` — `Agent[]`
- `opencode.unread_count` — `number`
- `opencode.last_error` — `{ message: string, detail?: string } | null`

### 4. Server Lifecycle

- Auto mode: managed local server on `127.0.0.1:4096` (configurable)
- External mode: user provides base URL + credentials
- Boot-ID scoping for session persistence across panel close/open
- No server spawn per panel open
- No duplicate SSE connections

### 5. Session Persistence

- Read `/proc/sys/sys/kernel/random/boot_id` for boot ID
- Save `{ boot_id, active_session_id, workspace, draft }` to `noctalia.pluginDataDir()/state.json`
- Match boot ID: restore session
- Different boot ID: show session chooser

### 6. SSE Connection Strategy

- Single SSE connection in service
- Subscribe to `/event` endpoint
- Events drive state updates
- Reconnect with exponential backoff on disconnect
- After reconnect: fetch session messages to reconcile

### 7. Permission Flow

- Permission events appear in SSE stream
- Service publishes to `opencode.pending_permissions`
- Panel renders permission card with allow/deny options
- User response sent to `/session/:id/permissions/:permissionID`
- Never auto-approve

### 8. UI Rendering

- No `ui.markdown` (may not be available in plugin_api 3)
- Fallback: `ui.label` with text content
- Code blocks rendered as single label with monospace hint
- Tool calls rendered as status cards

### 9. Settings

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `server_mode` | `string` | `"auto"` | "auto" or "external" |
| `server_host` | `string` | `"127.0.0.1"` | Server hostname |
| `server_port` | `double` | `4096` | Server port |
| `server_url` | `string` | `""` | External server URL |
| `default_workspace` | `folder` | `""` | Default workspace directory |
| `default_model` | `string` | `""` | Default model (provider/model) |
| `default_agent` | `string` | `"build"` | Default agent |
| `auto_start` | `bool` | `true` | Auto-start managed server |
| `show_tool_calls` | `bool` | `true` | Show tool call status |
| `show_reasoning` | `bool` | `false` | Show reasoning text |
| `notify_on_complete` | `bool` | `true` | Notify when response completes |
| `max_messages_load` | `double` | `50` | Max messages to load initially |
| `debug_logging` | `bool` | `false` | Enable debug logging |
| `open_near_click` | `bool` | `true` | Open panel near click |

### 10. Security

- Loopback binding only
- Shell quoting helper for all paths
- No credential logging
- No plaintext secret storage
- Validate URLs and ports
- Limit message rendering

---

## Known Risks / Beta Notes

1. **SSE reliability**: OpenCode 1.14.42+ had SSE bugs (events not forwarded). Version 1.18.13 tested OK but reconnection handling must be robust.

2. **Panel layer**: Panels render at `Layer::Top` — overlays (notifications, polkit) may cover the panel.

3. **state.watch reliability**: Earlier bars had issues; Noctalia 5 beta fixed this. Both watch and polling used as fallback.

4. **No module system**: v5 plugins load each entry as a single chunk. No `require()` across files. Use inline code or duplicate helpers.

5. **plugin_api gate**: `[[service]]` entry requires a build that ships the Service entry kind (Noctalia 5 beta+). The installed version (97917d9ca07e) supports it.

6. **Desktop widget**: Not included in initial build — only bar widget + panel + service. Desktop orb can be added later.

---

## Open Questions / To Verify During Testing

1. Does `prompt_async` return `204` immediately and all content comes via SSE?
2. What is the exact SSE event type for permission requests?
3. Does the session status endpoint show processing state in real-time?
4. Is `ui.markdown` available in this build?
5. How does the server behave when killed mid-session?
6. What happens to SSE connection when server restarts?

---

## Next Steps

1. Create plugin skeleton (plugin.toml, widget.luau, panel.luau, service.luau)
2. Implement server lifecycle management
3. Implement session state and boot-ID behavior
4. Implement widget
5. Implement panel with session picker
6. Implement chat and event updates
7. Implement permission flow
8. Add model/agent/MCP status display
9. Add settings and translations
10. Test on live Noctalia
