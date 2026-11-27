# AI Hub

AI Hub is a chat panel for OpenAI-compatible providers. It brings local gateways,
cheap inference clouds and hosted models into one transcript with a model picker,
streaming replies and optional tool calls.

## Plugin

| Field | Value |
| --- | --- |
| ID | `robpidev/ai-hub` |
| Entries | Bar widget: `status`; panel: `chat`; service: `brain` |

## Requirements

Noctalia with plugin API version 43 or newer is required. There are no external
command dependencies.

An OpenAI-compatible endpoint is needed: a local server such as OmniRoute, Ollama
or LM Studio works without a key, while hosted providers need an account and an
API key. Keys can also be reused from an existing OpenCode `auth.json`.

## Usage

Add the bar widget `robpidev/ai-hub:status` to a bar to get a status icon that
opens the panel on click. The `brain` service starts automatically and owns the
conversation, so the same transcript appears every time the panel is reopened.

Open the panel directly with:

```sh
noctalia msg panel-toggle robpidev/ai-hub:chat
```

Type in the composer and press **Enter** to send. **Shift+Enter** inserts a
newline. While a reply is streaming, the send button becomes a stop button;
stopping keeps the text produced so far. Pick a model from the dropdown at the
top of the panel, use the plug button to test the connection, and the trash
button to clear the conversation. Older messages are available through the
**Show more** button at the top of the transcript.

Each message has a copy button. Fenced code blocks have their own copy button
that copies only the code. Tools must be enabled explicitly with
`tool_permission`; when set to `ask`, each call shows an approve/deny prompt.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `provider` | `select` | `omniroute` | Preset that fills in the base URL. |
| `endpoint` | `string` | `""` | Overrides the base URL. Trailing slashes and `/chat/completions` are normalised. |
| `api_key` | `string` | `""` | Bearer token. Empty means no `Authorization` header is sent. |
| `key_source` | `select` | `manual` | Use the typed key or reuse one from OpenCode `auth.json`. |
| `auth_provider` | `string` | `""` | Credential name in `auth.json`; leave empty when there is only one. |
| `model` | `string` | `""` | Default model id. The panel dropdown overrides and remembers the choice. |
| `stream` | `bool` | `true` | Stream tokens with Server-Sent Events. |
| `tool_permission` | `select` | `off` | Tool access: `off`, `ask` per call, or `allow` all permitted calls. |
| `web_search` | `bool` | `false` | Offer the `web_search` and `web_fetch` tools. Also requires `tool_permission` to be `ask` or `allow`. |
| `tool_blocklist` | `string_list` | See manifest | Substrings that reject a command before approval and before execution. |
| `max_tokens` | `int` | `0` | Maximum tokens per reply. `0` leaves the choice to the server. |
| `max_history` | `int` | `40` | Number of transcript entries sent as context on each turn. |
| `system_prompt` | `string` | `""` | Optional system message prepended to every request. |
| `panel_width` | `int` | `500` | Floating panel width in px, from 300 to 1200. Needs a panel reload. |
| `panel_height` | `int` | `700` | Floating panel height in px, from 400 to 1200. Needs a panel reload. |
| `key_store_mode` | `select` | `per_provider` | Store one key per provider or a single global key. |

The bar widget also has a `glyph` entry setting (default `sparkles`) for its
icon.

## IPC

The service accepts a `dump` event that writes the transcript, state and
resolved configuration (never the API key itself) to a JSON file:

```sh
noctalia msg plugin robpidev/ai-hub:brain all dump
```

The file is written to
`~/.local/state/noctalia/plugins/data/robpidev/ai-hub/dump.json`.

## Notes

- Network access: requests go to the configured OpenAI-compatible endpoint.
  With `web_search` enabled, the plugin also fetches DuckDuckGo's HTML search
  page and any URL passed to the `web_fetch` tool.
- Files: credentials and conversation state are stored in `state.json` under
  the plugin data directory; the `dump` event writes `dump.json`. OpenCode's
  `auth.json` is read only when chosen as the key source.
- Processes: with `tool_permission` set to `ask` or `allow`, the `run_command`
  tool can execute shell commands through `noctalia.runAsync()` after the
  approval step and a blocklist check. With the default `off`, no tools are
  offered to the model and no command is run.
- Streaming replies that end abruptly are kept and marked as stopped. The
  panel renders only the newest messages at first to stay within the plugin
  callback budget; older ones are loaded on demand with **Show more**.

## License

MIT.
