# Calculator

A popup calculator panel powered by `qalc`, with a text input and a session
expression history. Click a history row to copy its result to the clipboard.

## Plugin

| field   | value                                                              |
| ------- | ------------------------------------------------------------------ |
| id      | `samuelskovbakke/calculator-plus`                                  |
| entries | `calculator-plus-widget` (widget), `calculator-plus-panel` (panel) |

## Usage

1. Enable the plugin:
   `noctalia msg plugins enable samuelskovbakke/calculator-plus`
2. Add the **Calculator** widget to a bar from Settings → Bar (or the Add-widget
   picker).
3. Click the bar icon to open the panel, type an expression, and press Enter to
   evaluate it.
4. Click any row in the history to copy that result to the clipboard.

The panel can also be toggled directly:

```
noctalia msg panel-toggle samuelskovbakke/calculator-plus:calculator
```

## Requirements

- `qalc`, the command-line calculator from
  [libqalculate](https://qalculate.github.io/). Install the `libqalculate`
  (Arch), `qalculate` (Fedora/Debian family package names vary) package for your
  distro; the binary is usually just called `qalc`.

## Notes

- Expressions are run as `qalc -t -f <sessionExprs>` via `noctalia.runAsync`
  using the argument-array form (no shell interpolation), so the panel does not
  spawn a shell.
- History is kept only for the lifetime of plugin enablement, it is not written
  to disk, and can be cleared with a button or by writing `clear` in the input
  field.
