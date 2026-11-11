# System Menu

![Made with AI](https://img.shields.io/badge/Made%20with-AI-76ddcf)

Packages, Task Manager, Terminal and About This System in a Noctalia menu.
Native Luau panels; the package browser uses fzf in your chosen terminal.
The bar, menu and About panel use your installed distribution's logo.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ajsem1337/system-menu` |
| Entries | Widget `button`; panels `menu`, `about` |
| Compatibility | Plugin API 43+; Arch or compatible derivative for package actions |
| License | MIT |

## Requirements

Install tools separately; nothing is installed automatically.

- `python3` (3.11+), a terminal (default `kitty`).
- `fzf` (0.74.5+), `pacman`, `pacman-conf`, `sudo`, `cat`, and a compatible AUR
  helper (default `paru`; `yay` or a custom executable also works).
- `btop` for Task Manager; `fastfetch` and `lsblk` for About.
- Optional: `downgrade` for cached versions, `traur` for manual audits,
  `xdg-open` for VirusTotal browser links.

## Settings

Open **Settings → Plugins → System Menu**.

| Setting | Default | Meaning |
| --- | --- | --- |
| Terminal executable | `kitty` | Executable name/path, without arguments |
| AUR helper executable | `paru` | Compatible executable name/path |
| Terminal arguments (advanced) | Empty | One list item per option |
| Run-program arguments (advanced) | `-e` | Before Packages/btop; use `--` for GNOME Terminal |

Enable **Show advanced** in Noctalia settings to edit the argument lists.
Existing argument values are preserved.

Arguments are passed directly: no aliases, shell quotes, `~` or variable expansion.
The helper must support `-S --needed --aur -- PACKAGE`, `-Ssa --color never -- QUERY`
and `-Syu`. Existing configuration is preserved; failures never switch helpers.

## Usage

Add `ajsem1337/system-menu:button` through bar settings, or open either panel:

```sh
noctalia msg panel-toggle ajsem1337/system-menu:menu
noctalia msg panel-toggle ajsem1337/system-menu:about
```

- **Packages:** install/uninstall, cache-only downgrade, update and VirusTotal.
- **Task Manager / Terminal:** btop or a terminal using your existing settings.
- **About:** hardware/software, on-demand refresh, technical details and copy.

| Key | Action |
| --- | --- |
| Enter / Esc | Confirm / back |
| Tab / Shift+Tab | Select / unselect, at most 50 packages |
| Ctrl+A / Ctrl+D | Select matches / clear selection |
| Alt+P | Toggle preview |
| Alt+D | Toggle compact / full details for repository and AUR packages |
| Alt+B | Current AUR PKGBUILD, read-only; press again to return |
| Alt+T | Manual Traur report, without installing |
| Shift+Left/Right | Resize preview; Shift+Up/Down scrolls it |

Search matches names only. AUR joins after two characters; results are grouped
by source, with AUR last. Finish selections before changing the query.
Compact previews show version, description, license, dependencies, size and packager
where available; AUR adds maintainer, votes/popularity and out-of-date warnings.
Full details include URL, architecture, groups, conflicts, timestamps and other
metadata. Installed fields come from `pacman -Qi`; AUR statistics use current RPC
data. Uninstalled packages never show invented build/install data.
Votes are community statistics, not a security rating. Installed-source fallback
uses local repositories then exact-name AUR metadata, not proven provenance.

### VirusTotal API key

Open **Packages → VirusTotal**, enter a file path or SHA-256, then answer **y** to
**Add a VT API key for results in this terminal?** Paste your own
[VirusTotal API key](https://www.virustotal.com/gui/my-apikey) into the hidden prompt.
It is saved locally in `~/.config/package-menu/virustotal.key` with permissions
`0600`, not in Noctalia settings. Later lookups reuse it; without a key you can
open the report in your browser. `VT_API_KEY`, if set, takes precedence.

## Notes

**Traur:** Alt+T calls `traur scan NAME --json`. The plugin does not install a
makepkg wrapper or enable automatic scanning. An existing helper/build gate
still runs independently; incomplete/failed scans do not approve anything.

Package-manager confirmations remain. Downgrades use local caches only and can
break dependencies. VirusTotal retrieves existing hash reports: no file uploads,
no promise of safety. See [operations and privacy](OPERATIONS.md) for data access.

## Credits

Inspired by GNOME [Logo Menu](https://github.com/Aryan20/Logomenu) and Omarchy's
fzf workflow ([MIT notice](packages/LICENSE-OMARCHY)).
**Made with AI:** code, documentation and tests received AI assistance.
