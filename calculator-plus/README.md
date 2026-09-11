# Calculator

A popup calculator panel powered by `qalc`, with a text input and a session
expression history. Click a history row to copy its result to the clipboard.

## Plugin

| field   | value                                |
| ------- | ------------------------------------ |
| id      | `samuelskovbakke/calculator-plus`    |
| entries | Bar widget: `widget`; panel: `panel` |

## Requirements

- `qalc`, the command-line calculator from
  [libqalculate](https://qalculate.github.io/). Install the `libqalculate`
  (Arch), `qalculate` (Fedora/Debian family package names vary) package for your
  distro; the binary is usually just called `qalc`.

## Usage

1. Enable the plugin:
   `noctalia msg plugins enable samuelskovbakke/calculator-plus`
2. Add the **Calculator** widget to a bar from Settings → Bar (or the Add-widget
   picker).
3. Click the bar icon to open the panel, type an expression, and press Enter to
   evaluate it.
4. Click any row in the history to copy that result to the clipboard.

## Settings

| Setting              | Type    | Default      | Description                                                                      |
| -------------------- | ------- | ------------ | -------------------------------------------------------------------------------- |
| `notify_on_copy`     | `bool`  | `true`       | Send a notification whenever an expression or result is copied to the clipboard. |
| `repeat_delay_ms`    | `int`   | `400`        | Change repeat delay of up/down arrow for history navigation.                     |
| `repeat_interval_ms` | `int`   | `120`        | Change repeat interval of up/down arrow for history navigation.                  |
| `glyph`              | `glyph` | `calculator` | Icon glyph name.                                                                 |

## IPC

The panel can also be toggled directly:

```sh
noctalia msg panel-toggle samuelskovbakke/calculator-plus:panel
```

## Notes

- Expressions are appended to a scratch file in the plugin's data directory and
  evaluated with `qalc -t -f <path>` via `noctalia.runAsync` using the
  argument-array form (no shell interpolation), so the panel does not spawn a
  shell. Session variables persist across evaluations by re-reading the full
  expression history from that file each time.
- The visible history list is kept only for the lifetime of plugin enablement
  and is not persisted, it can be cleared with a button or by writing `clear` in
  the input field. (The scratch file used internally to replay session variables
  to `qalc` does live in the plugin's data directory, but it holds only the raw
  expression text already visible in the history above, not anything separately
  sensitive, and is overwritten on every evaluation.)
