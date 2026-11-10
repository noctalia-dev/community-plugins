# System Menu

![Made with AI](https://img.shields.io/badge/Made%20with-AI-76ddcf)

A Noctalia menu with Packages, Task Manager, Terminal and About This System.
Inspired by the GNOME [Logo Menu](https://github.com/Aryan20/Logomenu) extension.
The menu and About panel are native Luau; Packages runs in Kitty with fzf.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ajsem1337/system-menu` |
| Entries | Bar widget: `button`; panels: `menu`, `about` |
| Compatibility | Noctalia plugin API 43+; Arch Linux or a compatible derivative for package actions |
| License | MIT |

## Requirements

Install dependencies separately:

- **Menu and terminals:** `python3` (3.11+), `kitty`.
- **Packages:** `fzf` (0.74.5+), `pacman`, `pacman-conf`, `paru`, `sudo`, `cat`.
- **About:** `fastfetch`, `lsblk` (util-linux).
- **Task Manager:** `btop` (btop or btop++).
- **Optional:** [`downgrade`](https://github.com/archlinux-downgrade/downgrade) for
  cached versions, [`traur`](https://github.com/Sohimaster/traur) for manual audits,
  `xdg-open` for VirusTotal browser links.

Missing optional tools do not block unrelated features. No scanner fork,
makepkg wrapper, private configuration or API key is bundled.

## Usage

Enable the plugin and add **System Menu** (`ajsem1337/system-menu:button`) to a bar.
Existing custom buttons can use `panel-toggle ajsem1337/system-menu:menu` instead.
Both panels also open directly:

```sh
noctalia msg panel-toggle ajsem1337/system-menu:menu
noctalia msg panel-toggle ajsem1337/system-menu:about
```

- **Packages:** merged repo/AUR search, multiselect install/uninstall,
  cache-only downgrade, VirusTotal lookup and full system update.
- **Task Manager / Terminal:** btop and Kitty, using your existing configuration.
- **About This System:** hardware, disks and software; on-demand Refresh,
  expandable Technical Details and Copy Information. No resource polling.

### Package controls

| Key | Action |
| --- | --- |
| Up/Down, Enter | Choose a menu action; review and confirm selected packages |
| Tab / Shift+Tab | Select / unselect; maximum 50 packages |
| Ctrl+A / Ctrl+D | Select all matches / clear |
| Alt+P | Toggle preview |
| Shift+Left/Right | Enlarge/shrink preview (25–75%); Shift+Up/Down scrolls it |
| Alt+T | Manual Traur audit of AUR names |
| Esc | Back |

Search matches package **names only**, ignoring case. AUR joins after 2 characters
and a short pause. Results are alphabetical per source, with distinct source
colors. Finish selecting before changing the query: reload can clear non-matching
selections. Results remain visible until Enter, then the terminal is cleared.

## Notes

- Normal pacman/paru confirmations remain. Exact `repo/package` targets are kept;
  mixed selections run repo and AUR transactions separately, without rollback.
- Downgrade uses local caches only. Review old builds and dependency changes.
- Traur is a **manual heuristic audit**, not a sandbox or automatic installation
  gate. Failed/missing reports provide no safety verdict. Existing paru settings
  are untouched.
- VirusTotal retrieves existing SHA-256 reports; **no uploads**. Supply your own
  key through `VT_API_KEY` or the hidden prompt, stored at
  `~/.config/package-menu/virustotal.key` (0600). Never commit it.
- AUR/VT requests, temporary files and About's clipboard report are documented in
  [Operations and privacy](OPERATIONS.md). No system settings are changed automatically.

## Credits

Menu concept: GNOME [Logo Menu](https://github.com/Aryan20/Logomenu).
Package workflow: Omarchy's fzf scripts; [MIT notice](packages/LICENSE-OMARCHY) retained.

## AI assistance

**Made with AI.** This project was developed with AI assistance, including code, documentation, and testing.
