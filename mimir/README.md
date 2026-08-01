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

If you use [OpenCode Go](https://opencode.ai/go) with the default OpenCode endpoint, Mimir auto-detects your API key from `~/.local/share/opencode/auth.json` — no manual setup needed.

## Features

- **Chat** — Conversational AI with formatted responses, markdown rendering (code blocks in shaded boxes), and selectable text for every message.
- **Command History** — Optionally shows executed commands in the chat, including commands run automatically in `allow` mode.
- **Model Browser** — Fetches available models from your API endpoint. Switch models on the fly from the panel header.
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

**Service** (`service.luau`) — HTTP communication with the API, conversation management, command execution, model discovery, and deferred state propagation.

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
| `show_commands` | `bool` | `true` | Show executed commands in the chat. |
| `max_history` | `int` | `50` | Max messages kept in context. |
| `glyph` | `glyph` | `brain` | Bar icon (per-widget setting). |

## How It Works

### API Compatibility
Compatible with any OpenAI-compatible chat completion API. Defaults to OpenCode Go.

### Tool Calling
When the model returns `tool_calls`, the service routes them to `run_command`. The permission mode determines whether to run immediately, prompt the user, or skip. Blocklisted commands and shell composition are rejected before execution.

### State Flow
Entries are isolated VMs — they communicate through Noctalia's shared state (`noctalia.state.*`). HTTP callbacks queue responses to avoid cross-context state corruption. A timer-driven `update()` processes the queue and propagates results.

## Notes

- Conversation is ephemeral (in-memory only). Restarting clears it.
- API key auto-detection reads OpenCode Go's auth file at runtime only — never stored.
- For best results, use a model with tool-calling support.
