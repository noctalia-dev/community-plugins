# System Menu

[![AI-assisted](https://img.shields.io/badge/AI--assisted-development-8A2BE2)](#ai-disclosure)

A small system menu for Noctalia v5, with Packages, Task Manager, Terminal and
About This System. Packages opens a bundled fzf frontend in Kitty; the menu and
About panel are native Noctalia Luau UI. There is no background monitoring service.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ajsem1337/system-menu` |
| Entries | Bar widget: `button`; panels: `menu`, `about` |
| License | MIT |
| Compatibility | Noctalia plugin API 43 or newer; package actions require Arch Linux or a compatible derivative |

## Requirements

Dependencies are not installed automatically. The manifest lists all external
commands, including optional features; missing optional tools do not prevent
opening the menu or using unrelated features.

| Command | Purpose |
| --- | --- |
| `python3` | Bundled package frontend and system collector; Python 3.11+ recommended |
| `kitty` | Packages, Task Manager and Terminal windows |
| `fastfetch` | About hardware/software collection; missing fields degrade gracefully |
| `lsblk` | Physical disk models, capacities and connection types in About; from util-linux |
| `btop` | Task Manager; btop or btop++ depending on your distribution |
| `fzf` | Package selector; **0.74.5 or newer** |
| `pacman` | Repository catalog, installed packages, exact-source installs and removals |
| `pacman-conf` | Read configured system cache directories for downgrade; from pacman |
| `paru` | AUR installation and full system updates; configure it yourself |
| `sudo` | Normal interactive authorization for pacman/downgrade |
| `downgrade` | Optional cache-only package downgrade; https://github.com/archlinux-downgrade/downgrade |
| `traur` | Optional manual AUR recipe audit; https://github.com/Sohimaster/traur |
| `xdg-open` | Optional opening of VirusTotal report links; from xdg-utils |
| `cat` | Display local search status inside fzf; from coreutils |

Install tools through your distribution's package manager and trusted packaging.
No curl-to-shell installer, scanner fork, binary scanner or replacement makepkg
is bundled. Use the upstream Traur installation instructions; availability and
build compatibility depend on your distribution. You do not need Traur or a
VirusTotal account for ordinary package search.

## Usage

Enable **System Menu** and add the `button` widget
(`ajsem1337/system-menu:button`) through Noctalia's bar settings. Click it to open
the attached menu. It does not replace your existing bar layout or logo button.

The panels can also be opened directly:

```sh
noctalia msg panel-toggle ajsem1337/system-menu:menu
noctalia msg panel-toggle ajsem1337/system-menu:about
```

An existing custom button may use `panel-toggle ajsem1337/system-menu:menu` as
its click action. The menu launches:

- **Packages**: find/install, list/uninstall, local-cache downgrade, manual
  VirusTotal lookup and normal full-system update.
- **Task Manager**: btop in its own Kitty window, using your btop configuration.
- **Terminal**: Kitty using your existing default shell/configuration.
- **About This System**: an on-demand, persistent system profile with hardware,
  physical disks, software and expandable technical details. Refresh reruns the
  collectors; Copy Information copies the displayed report to the clipboard.
  Close explicitly or use Escape while focused. There is no periodic polling.

### Packages controls

- Main menu: Up/Down and Enter. Only package lists have a search input.
- Search matches a continuous part of the **name only**, ignoring case.
- Repositories and AUR share one list. AUR queries start after 2 characters and
  a short typing pause; errors are shown rather than presented as a clean result.
- Sources appear first and are grouped alphabetically: configured non-CachyOS
  repositories, CachyOS repositories, then AUR; names are alphabetical per source.
- Arch repos are green, CachyOS purple and AUR yellow. Other repository names
  automatically receive stable pastel colors, including newly configured repos.
- Tab/Shift+Tab: select/unselect; Ctrl+A: select all matches, up to **50**;
  Ctrl+D: clear. Finish selections before changing the query: dynamic reload can
  clear selections that no longer match. Check the selection count before Enter.
- Enter: review the package plan, then explicitly confirm. Package managers
  still ask their normal questions; there is no `--noconfirm`.
- Alt+P: toggle preview. Shift+Left/Right: enlarge/shrink the right-hand preview
  in 5 percentage-point steps, limited to 25–75%. Shift+Up/Down scrolls it.
- Alt+T: manual Traur audit of selected AUR names. Repository entries are skipped.
- Esc: back. After an action, results remain visible until Enter; returning
  clears that terminal's screen and scrollback, not redirected output or logs.
- `[Installed]` appears in search only; installed/uninstall and downgrade lists
  omit the redundant state column. `local/unknown` means missing installation
  provenance, not proof of AUR origin. Current repository availability is not the
  same as the repository a package was originally installed from.

### Package operations and security

Repository selections install exact `repo/package` targets using
`sudo pacman -S --needed -- ...`; AUR selections use
`paru -S --needed --aur -- ...`. Mixed selections run repository packages first,
then AUR as separate transactions. Duplicate names across sources are rejected.
A failure stops subsequent transactions but does not undo completed ones.

Uninstall uses `sudo pacman -Rns -- ...`. Review its dependency removal plan.
Downgrade uses `sudo downgrade --cached-only --ignore=never`, preserving system
caches and adding existing paru/yay caches. There is no Arch Linux Archive
fallback, automatic IgnorePkg change or guarantee that old builds are compatible.
Full update uses `paru -Syu`, not a partial database refresh.

**Traur is a heuristic scanner, not a sandbox or a safety guarantee.** Alt+T is
a read-only, manual audit. This plugin does **not** install an automatic
pre-execution gate, modify `makepkg` or configure paru. Existing user-configured
gates are left untouched. Without such a gate, installing an AUR package does
not automatically run Traur. Remote Traur checks can fail to fetch/decode AUR
metadata; missing, invalid, incomplete or failed reports are not clean verdicts.
Review PKGBUILDs and your helper configuration yourself.

### VirusTotal and credentials

VirusTotal is a separate manual action for a regular file or SHA-256 digest.
Hashing is local; **no file is uploaded**. It only retrieves existing reports.
Without a key, open the report in a browser. Terminal results require your own
VirusTotal API key, entered at the hidden prompt or supplied through `VT_API_KEY`.
The prompt stores it at `~/.config/package-menu/virustotal.key` with mode **0600**.
Never commit or share that file. No account, key or personal configuration is
included in this repository. Public API quotas still apply.

Unknown hashes, API/network failures and rate limits do not mean a file is safe.
Zero detections is not a guarantee; a saved report may be old. This is not
automatic scanning of installed packages, build outputs or downloaded sources.

## Notes

**Network:** package name queries go to `https://aur.archlinux.org/rpc/v5/`.
Manual Traur requests may contact the services configured by Traur. VirusTotal
requests send a hash and the user's key only to
`https://www.virustotal.com/api/v3/files/`; browser links use the same site's
`/gui/file/` path. Pacman, paru and downgrade retain their normal configured
repository/helper behavior. Merely opening About makes no network request.

**Files:** transient catalog JSON, status and preview size live in private
temporary directories under `XDG_RUNTIME_DIR` (or Python's temporary directory)
and are removed when the selector closes normally. Optional VT setup writes the
owner-only key above. An existing `~/.config/fzf/themes/noctalia.sh` is read for
validated color declarations only, never sourced as shell code. Package managers
and Traur may write their own caches, logs and reports in their usual locations.

**System information:** About reads curated fastfetch JSON, `/proc/meminfo`,
`/proc/cpuinfo`, selected `/sys/class/dmi/id` and DRM memory fields, `/etc/os-release`
through Python, session environment variables, hostname and physical disk data.
It does not inventory installed packages or collect IP addresses, MAC addresses,
disk serial numbers or machine IDs. Hostname and hardware details are included
when you explicitly copy the report; review it before sharing.

**Processes and permissions:** UI entries spawn Kitty and Python; the collector
spawns fastfetch, lsblk and `noctalia --version`. The terminal frontend invokes
fzf, its own Python preview/search helpers, cat, and the feature-specific tools
listed above. It never starts as root; only the user's confirmed package
transactions invoke sudo. This is trusted, unsandboxed plugin code: inspect it
before enabling. No services, timers, repositories, mirror settings, system
configuration or terminal/btop themes are installed or changed automatically.

The catalog thumbnail is generated artwork, not a screenshot of a user's system.
The package browser's terminal UI is deliberately separate from Noctalia's native
panel UI. See `packages/README.md` for read-only development commands and the
retained Omarchy attribution in `packages/LICENSE-OMARCHY`.

## AI disclosure

Built with AI assistance using OpenCode. Maintained by
[ajsem1337](https://github.com/ajsem1337). AI assistance and passing tests do not
constitute a security audit. Human review is required before publishing releases.

---

AI-assisted development · Human review required · MIT licensed
