# Changelog

All notable changes to this plugin are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the version numbers
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1]

### Fixed

- The panel no longer rebuilds the whole transcript on every state update.
  Rendered messages are cached by content, and only the newest messages are
  shown at first, so a long conversation stays under the host's 25 ms callback
  budget. This also stops Noctalia from auto-disabling the plugin after repeated
  timeouts — the reason toolbar buttons such as **Clear** stopped responding.
- Markdown without fenced code takes a fast path instead of scanning every
  line, cutting render cost substantially.

### Added

- A **Show more** button at the top of the transcript reveals 12 older messages
  at a time.

## [0.2.0]

### Added

- **Message bubbles** – sent and received messages render as chat-style bubbles
  with role-based alignment (user right, assistant/error left) and distinct
  background fills.
- **Per-provider API keys** – keys typed manually are automatically saved in
  `state.json` and restored when switching providers. A `key_store_mode` setting
  (`global` or `per_provider`) controls the behaviour.
- **Code-block copy buttons** – each fenced code block in an answer gets its own
  "Copy code block" button, copying only the code without surrounding text.
- **Panel width/height settings** – `panel_width` (300–1200) and `panel_height`
  (400–1200) change the default floating-panel size (requires a panel reload).

### Fixed

- The **send button** now sends the composer text. Button clicks arrive at the
  callback as empty strings rather than `nil`, so the button uses a dedicated
  handler that reads the live draft instead of `onComposerSubmit`.
- The composer re-focuses after sending, so typing can continue without an
  extra click.
- **Long code blocks** now wrap to the panel width instead of overflowing and
  being cut off. Fenced code is rendered as a native monospaced label (language
  and copy button in a header row) so the host can wrap it; user messages and
  streaming replies that contain code get a full-width bubble for the same
  reason.
- The model picker's filter row rendered `ui tree node is not a table` when
  tools were off — wrapped nil‑producing expressions in `nodes(...)`.


## [0.1.0] - First release

### Added

- A `chat` panel with a streaming transcript, a fuzzy-searchable model picker, a
  composer and inline tool-call approvals, plus a `status` bar widget and the
  `brain` service that owns the conversation.
- Provider presets for OmniRoute, CheaperInference, Google Gemini (OpenAI-compatible
  endpoint), OpenRouter, Ollama / LM Studio, OpenCode Zen and any custom
  OpenAI-compatible endpoint.
- Keys read from the settings or from an existing OpenCode `auth.json` entry, and
  an `Authorization` header that is only sent when there is a key at all, so a
  local keyless gateway works out of the box.
- Server-Sent Events streaming, with a buffered retry when a server ignores
  `stream: true`, and a non-streaming mode for servers that cannot stream at all.
- Tools the assistant can call: `run_command`, `web_fetch` and `web_search`.
  `tool_permission` defaults to `off`; `ask` approves each call and `allow` runs
  the calls that pass the blocklist, which is re-checked at execution time.
- Reasoning traces, token usage and stopped or truncated answers are preserved
  and explained instead of being shown as empty messages.
- A `dump` IPC event that writes a JSON bug-report file next to the plugin's
  state, without the API key.
