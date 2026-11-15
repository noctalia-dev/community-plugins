# Clipboard Viewer

Shows what is on the clipboard right now as text in the bar, so you can see what a paste will insert before you paste it. Hover for the first few lines, click to open the clipboard history.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nitesh/clipboard-viewer` |
| Entries | Bar widget: `clipboard` |

## Requirements

Install `wl-clipboard`; the plugin needs `wl-paste` on `PATH`. If it is missing, the widget shows an error notification when it loads.

## Usage

Add the **Clipboard Viewer** widget to a bar in **Settings → Bar**.

- The bar shows the start of the copied text, with runs of whitespace collapsed to one space.
- Copied images and other non-text data show their type, for example `image/png`.
- Copies that a password manager marks as sensitive show `(hidden)`.
- Hovering shows the first few lines of the copied text.
- Left click opens Noctalia's clipboard history panel. It needs clipboard history enabled (`[shell] clipboard_enabled`, on by default). You can change the click action in the widget's **Actions** settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `max_length` | `int` | `25` | Characters of clipboard text shown in the bar (5–200). Longer text ends with `...`. |

## Notes

- **Processes:** the widget runs one long-lived `sh` loop around `wl-paste --watch`. On every copy it runs `wl-paste --list-types`, and for empty text reads it again with `wl-paste -t text`. It also uses `cat`, `tr` and `head`. If `wl-paste` exits, the loop restarts it after 2 seconds. Everything stops when the widget is removed.
- **Every copy is read once more.** The watcher reads each new clipboard item in full, as any clipboard manager does. This adds one more read when you also run a history tool such as cliphist.
- **Privacy:** the clipboard content is shown on screen, including in screenshots and screen shares. Copies carrying the `x-kde-passwordManagerHint` type (KeePassXC, 1Password and others set it) are never read or shown. Other secrets you copy as plain text are shown like any other text.
- **No files and no network.** The plugin writes nothing to disk and makes no network requests.
