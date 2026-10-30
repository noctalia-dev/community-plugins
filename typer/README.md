# Typer

A monkeytype-style typing test that lives in your shell: press a keybind and a
floating panel opens with a three-line window of random words typed against
the clock, per-character feedback, a blinking caret, and live WPM/accuracy.
Results persist per day and language, and the bar widget shows today's best
WPM.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lepinx/typer` |
| Entries | Panel: `test`; bar widget: `wpm`; launcher provider: `open` |
| Launcher Prefix | `/type` |

## Usage

1. Enable the plugin in Settings → Plugins.
2. Open the panel with the launcher (`/type` → "Typing test") or bind a global
   keybind to:

```sh
noctalia msg panel-toggle lepinx/typer:test
```

3. Pick English/Spanish, **Time** (15s/30s/60s) or **Words** (15/25/50), then
   start typing — the first keystroke starts the clock. Space submits the word
   (monkeytype-style; a completed word waits for it). Wrong characters render
   in red and letters beyond the target count as errors. Typing goes straight
   into the word window; there is no separate input field.
4. When the session ends, the panel shows WPM, accuracy, duration and today's
   best. **Enter** (or the button) restarts; **Escape** closes the panel.
5. Optionally add the `wpm` bar widget (Settings → Bar → Add widget): it shows
   today's best WPM and updates live while you test.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `language` | `string` | `en` | Word language for new sessions: `en` (English) or `es` (Spanish). The panel selector overrides it per session. |
| `mode` | `string` | `time` | Default session mode: `time` (seconds) or `words` (word count). The panel selector overrides it per session. |

## Notes

- **Filesystem writes:** session results are stored as JSON under the plugin's
  private data directory (`pluginDataDir()` → `stats.json`), keyed by date and
  language. Nothing else is written.
- **No network access.** The plugin spawns no processes; wordlists ship inside
  the plugin (`words/en.txt`, `words/es.txt`).
- The three-line word window wraps by estimated character width (the plugin UI
  API has no inline text wrapping), so line shifts are instant rather than
  animated.
