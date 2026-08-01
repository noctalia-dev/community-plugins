# Mimir

An AI companion for Noctalia that brings LLM-powered chat and terminal command execution directly into your desktop. Named after the Norse god of wisdom.

## Plugin

| Field | Value |
| --- | --- |
| ID | `alexander/mimir` |
| Entries | Bar widget: `status`; panel: `chat`; service: `brain` |

## Requirements

- An **OpenAI-compatible API endpoint** with `/chat/completions` and `/models` endpoints.
- An API key (for hosted providers) or leave empty for local servers (e.g. Ollama).
- A [Noctalia](https://noctalia.app) build supporting `plugin_api >= 16`.
- An internet connection for the no-setup web search feature.
- `curl` and `python3` for web search and page fetching.

If you use [OpenCode Go](https://opencode.ai/go) with the default OpenCode endpoint, Mimir auto-detects your API key from `~/.local/share/opencode/auth.json` — no manual setup needed.

## Features

- **Chat** — Conversational AI with formatted responses, markdown rendering (code blocks in shaded boxes), and selectable text for every message.
- **Command History** — Optionally shows executed commands in the chat, including commands run automatically in `allow` mode.
- **Model Browser** — Fetches available models from your API endpoint. Switch models on the fly from the panel header.
- **Web Search** — Uses DuckDuckGo's normal HTML search endpoint to return current result titles, URLs, and snippets to the model.
- **Web Fetch** — Reads text from a specific public HTTPS URL when a search result needs deeper inspection.
- **Command Execution** — Mimir can run terminal commands through the AI. In `ask` mode, each command must be approved before it runs; `allow` mode runs non-blocked commands automatically.
- **Permission Modes** — `ask` (prompt before every command), `allow` (run automatically), `off` (no tools). Automatic mode still rejects blocked commands and shell composition.
- **Command Blocklist** — Dangerous commands and shell composition are rejected before execution. This is an extra safeguard, not a replacement for reviewing commands.

## Architecture

```
┌──────────┐    state     ┌──────────┐    HTTP    ┌─────────────┐
│  panel   │◄───────────►│ service  │◄──────────►│  API Server │
│ (chat)   │  mimir.*     │ (brain)  │  chat/*    │ (OpenCode)  │
│          │              │          │  models    │             │
└────┬─────┘              └──────────┘            └─────────────┘
     │
     │ click
┌────▼─────┐
│  widget  │
│ (status) │
└──────────┘
```

**Widget** (`widget.luau`) — Bar indicator. Click to toggle the chat panel.

**Panel** (`panel.luau`) — Chat interface with model selector, command approval, command history, message history with markdown rendering, and per-message selectable text views.

**Service** (`service.luau`) — HTTP communication with the API, public web search, and public-page fetching, plus conversation management, command execution, model discovery, and deferred state propagation.

## Usage

### Install

1. Add the plugin directory as a path source in Noctalia settings.
2. Enable `alexander/mimir` in **Settings → Plugins**.
3. Add the bar widget `alexander/mimir:status` to your bar.

### Chat

Click the brain icon in your bar or run:
```sh
noctalia msg panel-toggle alexander/mimir:chat
```

Type a message and press Enter. Mimir responds with formatted text — code blocks render in shaded boxes. Click the copy icon on any message to open its content in a selectable field, then copy the text manually.

### Command Approval

When Mimir wants to run a terminal command (in `ask` permission mode), the panel shows an approval dialog:
1. Review the command shown in the dialog.
2. Click **Approve** to run it or **Deny** to cancel.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `api_endpoint` | `string` | `https://opencode.ai/zen/go/v1` | Base URL for the API. Change to `http://localhost:11434/v1` for Ollama. |
| `api_key` | `string` | (auto-detect) | API key. If empty and using the trusted OpenCode endpoint, reads from `~/.local/share/opencode/auth.json`. |
| `tool_permission` | `enum` | `ask` | `ask` — prompt before commands; `allow` — run automatically; `off` — disable tools. |
| `tool_blocklist` | `string` | `sudo,su,passwd,rm,...` | Comma-separated commands rejected before execution. |
| `web_search_enabled` | `bool` | `true` | Enable or disable web search and public-page fetching. |
| `show_commands` | `bool` | `true` | Show executed commands in the chat. |
| `max_history` | `int` | `50` | Max messages kept in context. |
| `glyph` | `glyph` | `brain` | Bar icon (per-widget setting). |

## How It Works

### API Compatibility
Compatible with any OpenAI-compatible chat completion API. Defaults to OpenCode Go. Mimir automatically retries transient upstream errors (network failures or "Upstream request failed" responses) before showing an error.

### Tool Calling
When the model returns `tool_calls`, the service routes them to `run_command`. The permission mode determines whether to run immediately, prompt the user, or skip. Blocklisted commands and shell composition are rejected before execution.

The `web_search` tool uses DuckDuckGo's normal public HTML search endpoint and needs no key or account. Requests run through a bounded, shell-quoted `curl` command piped to a small bundled Python parser (`webparse.py`), with retries for transient failures. The `web_fetch` tool reads a specific public HTTPS page after a search result needs deeper inspection, using the same pipeline. Search queries are sent to DuckDuckGo. Recent results are cached in memory for five minutes to avoid repeated requests. Search availability and result quality depend on that public endpoint and may be affected by rate limits or website changes. Requests time out after 15 seconds, and web results and fetched pages are treated as untrusted data rather than instructions.

### Noctalia CPU-budget note

Noctalia runs plugin callbacks (including `update()` and HTTP/command callbacks) under small per-call CPU budgets, so heavy work must not run inside the Luau VM. Mimir therefore keeps its web requests and HTML parsing in a `curl | python3` subprocess; the Luau service only passes the already-parsed text back to the model.

### State Flow
Entries are isolated VMs — they communicate through Noctalia's shared state (`noctalia.state.*`). HTTP callbacks queue responses to avoid cross-context state corruption. A timer-driven `update()` processes the queue and propagates results.

## Notes

- Conversation is ephemeral (in-memory only). Restarting clears it.
- API key auto-detection reads OpenCode Go's auth file at runtime only — never stored.
- For best results, use a model with tool-calling support.

## Security

Mimir is a trusted desktop plugin that runs the model's shell commands and makes outbound web requests. This is the security model:

### API key handling

- The key is read at runtime only and never written to disk, state, or logs.
- Auto-detection from `~/.local/share/opencode/auth.json` happens **only** when the endpoint is exactly `https://opencode.ai` on port 443/absent. A manually configured `api_key` is sent only to the endpoint you configure.
- The API key is **never** sent to DuckDuckGo or to fetched pages — web requests carry only a browser User-Agent and an Accept-Language header.

### Command execution

- `ask` mode shows every command for explicit approval before it runs; `allow` runs non-blocked commands automatically; `off` disables tools.
- The command blocklist rejects destructive, interpreter, and network tools (`sudo`, `rm`, `sh`, `python`, `curl`, `ssh`, `git`, cloud CLIs, and more). It also rejects shell composition: `; | & > < \` $ \` and newlines, so commands cannot be chained or substituted.
- The blocklist is a safety guardrail, **not** a security boundary — raw shell execution in `allow` mode carries inherent risk.

### Web search and fetch

- `web_fetch` only accepts `https://` URLs, rejects credentials in the URL, private/loopback/link-local IPv4 and IPv6 addresses, `localhost`, `.local` hosts, and numeric/IP obfuscations that resolve to private addresses.
- Requests verify TLS (no insecure TLS), follow no redirects, and are restricted to HTTPS in curl.
- Search results and fetched pages are marked untrusted in the tool output and the system prompt forbids following instructions found in them.
- The parser runs in a subprocess with a capped input size; output is length-limited and control characters are stripped.

### Known residual risks

- **DNS rebinding**: a public-looking domain could resolve to a private address after validation. Noctalia's API does not expose DNS resolution, so this cannot be fully prevented — `web_fetch` is only for well-known public URLs.
- **Trusted-plugin model**: Noctalia plugins run as trusted code, so a malicious model output combined with `allow` mode can still run arbitrary commands that the blocklist does not cover. Review commands in `ask` mode for sensitive work.
