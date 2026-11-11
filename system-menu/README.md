# System Menu

![Made with AI](https://img.shields.io/badge/Made%20with-AI-76ddcf)

A Noctalia menu with Packages, Task Manager, Terminal and About This System.
Inspired by the GNOME [Logo Menu](https://github.com/Aryan20/Logomenu) extension.
The menu and About panel are native Luau; Packages runs with fzf in a terminal
of your choice. Bring your own compatible AUR helper for the package browser.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ajsem1337/system-menu` |
| Entries | Bar widget: `button`; panels: `menu`, `about` |
| Compatibility | Noctalia plugin API 43+; Arch Linux or a compatible derivative for package actions |
| License | MIT |

## Requirements

Install dependencies separately:

- **Menu and terminals:** `python3` (3.11+) and your configured terminal (default: `kitty`).
- **Packages:** `fzf` (0.74.5+), `pacman`, `pacman-conf`, your configured AUR helper
  (default: `paru`; `yay` or another compatible helper can be used), `sudo`, `cat`.
- **About:** `fastfetch`, `lsblk` (util-linux).
- **Task Manager:** `btop` (btop or btop++).
- **Optional:** [`downgrade`](https://github.com/archlinux-downgrade/downgrade) for
  cached versions, [`traur`](https://github.com/Sohimaster/traur) for manual audits,
  `xdg-open` for VirusTotal browser links.

Missing optional tools do not block unrelated features. No scanner fork,
makepkg wrapper, private configuration or API key is bundled.

### Distribution icon

The bar button, menu header and About panel detect the installed distribution
from `LOGO`, `ID` and `ID_LIKE` in `/etc/os-release` (or `/usr/lib/os-release`
when the former is unavailable). Noctalia resolves the logo through the current
icon theme; common files in `/usr/share/icons` and `/usr/share/pixmaps` are also
checked. CachyOS, Arch, Artix and other distributions use their own installed
artwork, not a hard-coded CachyOS path or a bundled collection of distro logos.
The distribution's logo is preferred over its parent distribution's icon.
If no matching icon is installed, a generic system icon is used. Detection is
local, never executes os-release as a script and does not download icons.
This does not change the Arch-specific requirements for package actions.

## Settings

Open **Settings → Plugins → System Menu** (gear icon). These settings are shared
by the menu, including when opened directly through IPC:

| Setting | Default | What to enter |
| --- | --- | --- |
| Terminal executable | `kitty` | Executable name or absolute path, without arguments |
| Terminal arguments | Empty list | Optional terminal options; one list item per argument |
| Run-program arguments | `-e` | Arguments before the program for Packages and Task Manager |
| AUR helper executable | `paru` | `paru`, `yay`, or another compatible helper's executable name/path |

The **Terminal** action uses the executable and terminal arguments only.
**Packages** and **Task Manager** also append the run-program arguments and
the program to run. For example:

| Terminal executable | Run-program arguments |
| --- | --- |
| `kitty`, `foot`, `alacritty`, `konsole`, `xterm` | One item: `-e` |
| `gnome-terminal` | One item: `--` |

For a different terminal or wrapper, use its documented run-program arguments;
an empty list is allowed. Terminal sizing and appearance use your existing
terminal configuration. Paths and arguments are passed directly, not evaluated
by a shell: aliases, `~`, `$VARIABLE`, pipelines and shell command strings are
not expanded. Put each argument in its own list item, without shell quotes.

The package browser accepts your choice of AUR helper, **provided its CLI is
compatible** with `-S --needed --aur -- PACKAGE...`, `-Ssa --color never -- QUERY`
and `-Syu`, including paru/yay-style search output for `--list aur`. Arbitrary
helper CLIs are not automatically translated. Repository installs and removals
still use pacman; live AUR search uses the read-only AUR RPC. Existing helper
configuration and confirmations remain in effect. A failed/missing helper does
not trigger a fallback to another one. Custom helper caches are not discovered
automatically: cache-only downgrade retains the configured pacman caches and
the existing standard paru/yay cache paths.

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
- **Task Manager / Terminal:** btop and your chosen terminal, using your existing configuration.
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
Installed lists also resolve missing sources through local repository databases
and exact-name AUR lookups; AUR stays at the end. Preview distinguishes recorded
origins from availability-based labels. Unmatched/offline results stay unknown.

## Notes

- Normal pacman/helper confirmations remain. Exact `repo/package` targets are kept;
  mixed selections run repo and AUR transactions separately, without rollback.
- Downgrade uses local caches only. Review old builds and dependency changes.
- Traur is a **manual heuristic audit**, not a sandbox or automatic installation
  gate. Failed/missing reports provide no safety verdict. Existing helper settings
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
