# Mimir

An AI companion for Noctalia that brings LLM-powered chat directly into your desktop. Named after the Norse god of wisdom, Mimir lets you converse with AI models while you work — and will eventually let it search files, run commands, and manage your project for you.

## Plugin

| Field | Value |
| --- | --- |
| ID | `alexander/mimir` |
| Entries | Bar widget: `status`; panel: `chat`; service: `brain` |

## Important

1. I used Opencode as example because that is what I Use and what I tested , it should work with more (not tested)
2. THis plugin is very early beta , I will improve it as much as I can with api maturing (need scroll control)
3. I am planing to add commands , file search , etc with opt out options


## Requirements

- An **OpenAI-compatible API endpoint** with a `/chat/completions` and `/models` endpoint.
- An API key (for hosted providers) or an empty string for local servers (e.g., Ollama).
- A [Noctalia](https://noctalia.app) build that supports `plugin_api = 16` or higher.

If you use [OpenCode Go](https://opencode.ai/go), Mimir can auto-detect your API key from `~/.local/share/opencode/auth.json` — no manual setup needed.

## Architecture

Mimir uses three processes that communicate through Noctalia's shared state:

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

**Widget** (`widget.luau`) — A bar indicator showing the brain icon. Click to toggle the chat panel.

**Panel** (`panel.luau`) — The chat interface with model selector, message history with simple markdown rendering (code blocks in shaded boxes), and a text input.

**Service** (`service.luau`) — The brain. Handles all HTTP communication with the API server, manages conversation history, and queues responses to propagate them back to the panel via state.

## Usage

### Install & Enable

1. Add `alexander/mimir` as a path source in Noctalia settings, pointing to the plugin directory.
2. Enable the plugin in **Settings → Plugins → Mimir**.
3. Add the bar widget `alexander/mimir:status` to your bar.

### Chat

Click the brain icon in your bar to open the side panel. Type a message and press Enter to send. Mimir will respond inline with basic markdown formatting — code blocks are highlighted with a shaded background.

### Model Selection

The panel header has a dropdown showing all models available at your API endpoint. Click the refresh button (↻) next to it to reload the list. Select any model to switch instantly — the next message uses the new model.

### Clear History

Click the eraser icon in the status bar to clear the conversation and start fresh.

### Keyboard Shortcut

You can toggle the panel from anywhere via IPC:

```sh
noctalia msg panel-toggle alexander/mimir:chat
```

## Settings

### Panel Settings

Configured globally in **Settings → Plugins → Mimir**:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `api_endpoint` | `string` | `https://opencode.ai/zen/go/v1` | Base URL for the API. Change to `http://localhost:11434/v1` for Ollama, or any OpenAI-compatible provider. |
| `api_key` | `string` | (auto-detect) | API key for hosted providers. If left empty, Mimir tries to read it from `~/.local/share/opencode/auth.json`. |

### Advanced Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `max_history` | `int` | `50` | Maximum number of messages kept in conversation context. Older messages are dropped when exceeded. |

### Widget Settings

Configured per-bar-instance:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `brain` | Icon shown in your bar. |

## How It Works

### API Compatibility

Mimir is compatible with any OpenAI-compatible chat completion API. The default endpoint is OpenCode Go (`https://opencode.ai/zen/go/v1`) which provides models like DeepSeek V4 Flash, DeepSeek V4 Pro, Grok, Kimi, and GLM. You can switch to Ollama (`http://localhost:11434/v1`) or any other provider by changing the endpoint in settings.

### Model Discovery

On startup and refresh, the service fetches the list of available models from `{endpoint}/models`. Models are stored in Noctalia's shared state and displayed in the panel's dropdown. The first available model is selected by default; if none are loaded, it falls back to `deepseek-v4-flash`.

### Conversation State

Messages are stored in a shared state array (`mimir.messages`). The service maintains its own conversation table internally and only pushes copies to state after each turn, ensuring reference stability across the IPC boundary.

### Response Flow

To work around Noctalia's async context model, HTTP callbacks in the service queue responses to a `pendingResponses` table. A timer-driven `update()` function processes this queue in the main loop, calling `state.set()` from the correct context to trigger the panel's re-render.

## Future Plans

Mimir is intentionally built as a foundation with more capabilities planned:

### Terminal Command Execution

Run shell commands through the AI. Mimir will be able to execute terminal commands, capture output, and reason about results — turning natural language into shell operations.

### File Search & Grep

Search across your project files with semantic understanding. Ask Mimir to find specific code patterns, read file contents, or search through directories — the AI navigates your filesystem as a tool.

### Project Organization

Analyze and restructure your codebase. Mimir will understand project structure, suggest reorganizations, move files, rename symbols, and help maintain consistent conventions across your projects.

### Code Editing

Read and modify source files under AI direction. Mimir will be able to make targeted edits to your codebase after confirming with you.

### Multi-Tool Reasoning

Chain multiple tools together — search for a pattern, read the relevant file, run a test, interpret the error, and fix the code — all in a single conversation turn.

### Local Model Support

Full support for local models via Ollama and llama.cpp, enabling fully offline AI assistance with no data leaving your machine.

The plugin's modular service architecture is designed around a tool-calling loop. Each tool (search, read, exec, etc.) will be a registered function that the model can invoke, with results fed back into the conversation for the AI to reason about.

## Notes

- API keys are stored in Noctalia's per-plugin config file at `~/.config/noctalia/plugins/mimir.json` when configured through settings.
- When auto-detecting from OpenCode Go's auth file, the key is read at runtime and never written to Noctalia's config.
- The plugin makes outbound HTTP requests to the configured API endpoint. It respects Noctalia's offline mode.
- The bar widget has no auto-refresh — it renders once and toggles the panel on click.
- The conversation is ephemeral (stored only in memory). Closing the panel or restarting Noctalia clears the conversation history.
- For best results with multi-turn conversations, use a model with a large context window (e.g., DeepSeek V4 Flash at 128K tokens).
