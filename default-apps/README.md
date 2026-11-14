# Default Apps

View and change your XDG default applications from Noctalia: web browser, email, calendar, file manager, archive manager, video and music players, photos, plain text editor, code editor, PDF viewer, word processor, spreadsheet, presentation, and BitTorrent client. Changes are written through `xdg-mime`, so they apply desktop-wide.

## Plugin

- **Id:** `thaer99ob/default-apps`
- **Panel entry:** `manager`
- **Widget entry:** `current`
- **Launcher entry:** `search` (Prefix: `/apps`)

## Requirements

- `xdg-utils`

## Usage

### Panel

Open the manager panel from the bar widget, via the Noctalia launcher by typing `/apps`, or with:

```bash
noctalia msg panel-toggle thaer99ob/default-apps:manager
```

Each row shows a category, its current default, and a dropdown of installed applications. Select your preferred applications from the dropdowns and click the **Apply** button to save all changes at once.

### Bar widget

Add the widget to a bar from the widget picker. It provides a clean shortcut icon on your bar. Clicking it opens the manager panel.

### Launcher

Open the Noctalia global search and type `/apps`. Clicking the provider will immediately launch the configuration panel.

## Notes

- Defaults are stored by `xdg-mime` in `~/.config/mimeapps.list`.
- Candidate apps come from desktop entries in standard system and Flatpak paths, plus any directory in `XDG_DATA_DIRS`. On Non-FHS systems such as Guix or Nix, `GUIX_PROFILE` and `GUIX_ENVIRONMENT` are also scanned.
- The Code Editor row lists text editors, IDEs and development tools, plus apps that handle plain text or common source-code MIME types. Web browsers are excluded.
- Hidden and `NoDisplay` entries and URL-handler entries (such as `code-url-handler.desktop`) are not shown.
- The current default is always kept in the dropdown, even if the app doesn't match the row's filter.
