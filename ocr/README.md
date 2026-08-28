# OCR

Grab text straight from the screen: select a region (or take a whole output),
run it through tesseract, and get the recognized text on your clipboard with a
notification preview.

## Plugin

| Field | Value |
| --- | --- |
| ID | `fel/ocr` |
| Entries | Bar widget: `ocr`; control-center shortcut: `grab` |

## Requirements

Install on `PATH`:

- `grim` — Wayland screenshot utility
- `slurp` — region selection
- `tesseract` — OCR engine, plus a tessdata language package for every
  language you enable (e.g. `tesseract-data-eng`)

A Wayland compositor supported by `grim` is required. If any dependency is
missing, the bar widget greys out and the shortcut tile is disabled.

## Usage

Add the **OCR** widget from the bar's Add-widget picker:

- **Left click** — select a screen region with `slurp`; its text is OCR'd and
  copied to the clipboard.
- **Right click** — same, but for the entire focused output (no selection).

Optionally add the **OCR text grab** quick tile under Settings → Control
Center → Shortcuts; it mirrors the widget's left/right click mapping.

While a capture runs, the widget highlights until the result (or an error
notification) arrives.

## Settings

Plugin-level settings live under Settings → Plugins → OCR; both entries share
them.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| Tesseract languages | `string` | `eng` | Language codes passed to `tesseract -l`, joined with `+` (e.g. `eng+deu`). Each code needs its tessdata package installed. |
| Page segmentation | `select` | Uniform block | The tesseract `--psm` mode: Automatic (`3`), Uniform block of text (`6`), or Single line (`7`). |
| Copy result to clipboard | `bool` | on | Copy the recognized text as `text/plain`. |
| Show result notification | `bool` | on | Notify with a preview of the recognized text. |

Each widget instance also has:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| Glyph | `glyph` | `scan` | Bar icon for this instance. |

## Notes

- No network access.
- Processes spawned per capture: one `/bin/sh` pipeline running `mktemp`,
  `slurp`, `grim`, `tesseract` and `rm`.
- Filesystem writes: a single temporary PNG in `$XDG_RUNTIME_DIR` (falling
  back to `/tmp`), deleted immediately after recognition, success or failure.
  Nothing else is written or read.
- A cancelled selection (Esc in `slurp`) is silent by design.
- The capture must finish within 60 s (the runtime's subprocess timeout cap) —
  that includes the time you take to drag the selection.
