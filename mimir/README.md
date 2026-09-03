# Mimir

An AI companion for Noctalia that brings LLM-powered chat and terminal command execution directly into your desktop. Named after the Norse god of wisdom.

## Plugin

| Field | Value |
| --- | --- |
| ID | `alexander/mimir` |
| Entries | Bar widget: `status`; panel: `chat`; service: `brain` |

## Requirements

- A [Noctalia](https://noctalia.app) build supporting `plugin_api >= 16`.
- An **OpenAI-compatible API endpoint** with `/chat/completions` and `/models` endpoints.
- An API key (for hosted providers) or leave empty for local servers (e.g. Ollama).
- `curl` and `python3` on `PATH` for the web search and page-fetch features.
- An internet connection for the no-setup web search feature.

If you use [OpenCode Go](https://opencode.ai/go) with the default OpenCode endpoint, Mimir auto-detects your API key from `~/.local/share/opencode/auth.json` — no manual setup needed.

## Usage

1. Add the plugin directory as a path source in Noctalia settings.
2. Enable `alexander/mimir` in **Settings → Plugins**.
3. Add the bar widget `alexander/mimir:status` to your bar.

Click the brain icon in your bar or toggle the panel from a terminal:

```sh
noctalia msg panel-toggle alexander/mimir:chat
```

Type a message and press Enter. Mimir responds with formatted text — code blocks render in shaded boxes. Click the copy icon on any message to open its content in a selectable field, then copy the text manually.

When Mimir wants to run a terminal command in `ask` permission mode, the panel shows the command with **Approve** / **Deny** buttons.

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

## IPC

Send a message to Mimir without opening the panel:

```sh
noctalia msg plugin alexander/mimir:brain all input "your message"
```

## Notes

- Conversation is ephemeral (in-memory only). Restarting clears it.
- API key auto-detection reads OpenCode Go's auth file at runtime only — never stored or logged.
- Web search uses DuckDuckGo's public HTML endpoint (no key or account). Search queries are sent to DuckDuckGo; results are cached in memory for five minutes and requests time out after 15 seconds. The model treats search results and fetched pages as untrusted data, not instructions.
- Web requests run through a `curl | python3` subprocess (with the bundled `webparse.py`) rather than inside the Luau VM, because Noctalia enforces small per-callback CPU budgets.
- For best results, use a model with tool-calling support.

### Security

Mimir is a trusted desktop plugin that runs the model's shell commands and makes outbound web requests. This is the security model:

- **API key handling** — the key is read at runtime only and never written to disk, state, or logs. Auto-detection from `~/.local/share/opencode/auth.json` happens only when the endpoint is exactly `https://opencode.ai` on port 443/absent. The API key is never sent to DuckDuckGo or fetched pages — web requests carry only a browser User-Agent and an Accept-Language header.
- **Command execution** — `ask` mode shows every command for approval; `allow` runs non-blocked commands automatically; `off` disables tools. The blocklist rejects destructive, interpreter, and network tools (`sudo`, `rm`, `sh`, `python`, `curl`, `ssh`, `git`, cloud CLIs, and more) as well as shell composition (`; | & > < \` $ \` and newlines). The blocklist is a safety guardrail, not a security boundary — raw shell execution in `allow` mode carries inherent risk.
- **Web fetch** — only accepts `https://` URLs, rejects credentials, private/loopback/link-local IPv4 and IPv6 addresses, `localhost`, `.local` hosts, and numeric/IP obfuscations. Requests verify TLS, follow no redirects, and are restricted to HTTPS. Parser input and output are size- and length-limited and control characters are stripped.
- **Residual risks** — DNS rebinding cannot be fully prevented (Noctalia exposes no DNS resolution API), so `web_fetch` is only for well-known public URLs. Plugins run as trusted code, so a malicious model output combined with `allow` mode can still run commands the blocklist does not cover — review commands in `ask` mode for sensitive work.
