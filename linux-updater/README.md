# Linux Updater

Check and install system updates from the bar on any major Linux
distribution. One click runs the whole upgrade in the background: polkit
asks for your password, the panel shows a live log tail and a progress bar,
finished runs land on a history strip — with rollback where the
distribution supports it. The right package-manager backend is picked
automatically from `/etc/os-release`.

![Pending updates](screenshots/panel.png)
![Update history strip](screenshots/history.png)

## Features

- **Background updates.** The run is spawned detached (it survives a shell
  restart), fully non-interactive, logged to a file the panel tails live
  with a progress bar; the bar widget shows a percentage. On success:
  notification and an automatic re-check. A failed run keeps its log on
  screen and offers an interactive **Retry in terminal** fallback.
- **Update history with rollback.** Every finished run becomes a segment on
  the history strip (hover for date and size, click for the package list).
  On Arch, single packages or whole runs roll back from the package cache —
  dependencies from the same run travel along, and pacman refuses anything
  that would break other packages. On Fedora a whole run is undone with
  `dnf history undo`. A second click confirms every rollback.
- **Ignore management.** Every package row has an ignore button; ignored
  packages live in an expandable section with restore buttons. The system's
  own mechanisms (`IgnorePkg`, `apt-mark hold`) are detected and shown with
  a tag explaining where they are managed. The plugin list is honored
  during updates (`--ignore`/`--exclude`/hold/lock per backend).
- **One polkit password per run.** pkexec normally re-authenticates every
  package-manager call; the panel offers to install a narrow
  keep-authorization rule (one confirmed click) so a single password covers
  the whole run.
- **Self-fixing setup.** When something the plugin relies on is missing or
  off (the polkit rule, apt's list-refresh timers), the panel says so and
  offers a one-click, one-confirmation fix. Nothing is ever changed
  silently.
- **Extras.** Download-size estimate and Arch news (pacman backend), AUR
  via paru/yay, Flatpak on every backend, reboot recommendation with the
  best available method per distribution, desktop notifications, launcher
  quick actions (`/up`), full log in a terminal pager.

## Plugin

| Field | Value |
| --- | --- |
| ID | `umedbazarov/linux-updater` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service`; launcher: `launcher` |
| Launcher Prefix | `/up` |

## Backends and capabilities

| | pacman (Arch, Manjaro, …) | dnf (Fedora) | apt (Debian, Ubuntu, Mint, …) | zypper (openSUSE) | xbps (Void) | PackageKit (fallback) |
| --- | --- | --- | --- | --- | --- | --- |
| Check without root | ✓ | ✓ | ✓ (via apt timers) | ✓ (via autorefresh) | ✓ | ✓ |
| Background update | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Old→new versions in the list | ✓ | ✓ | ✓ | ✓ | new only | new only |
| Download size estimate | ✓ | — | — | — | — | — |
| Rollback | per package / per run, from the package cache | whole run, `dnf history undo` | — | — (use snapper) | — | — |
| System ignore shown | `IgnorePkg` | — | `apt-mark hold` | — | — | — |
| Plugin ignore honored on update | `--ignore` | `--exclude` | hold for the run | lock for the run | hold for the run | display only |
| Distribution news | Arch news feed | — | — | — | — | — |
| AUR layer | ✓ (paru/yay) | — | — | — | — | — |
| Reboot detection | kernel modules | `needs-restarting` | `/var/run/reboot-required` | `zypper needs-rebooting` | kernel modules | kernel modules |

Flatpak checking and updating works on every backend. NixOS is not
supported by design (see
[nix-monitor](https://noctalia.dev/plugins/avivbintangaringga/nix-monitor)
instead); Gentoo has no backend yet — the backend interface in
`backends/` is open for contributions.

## Requirements

- The distribution's own package manager, on `PATH`: `pacman` +
  `pacman-contrib` (Arch family), `dnf` (Fedora), `apt-get`
  (Debian family), `zypper` (openSUSE), `xbps-install` (Void), or `pkcon`
  (PackageKit) as the generic fallback. Only the one matching your
  distribution is needed; the panel says what is missing.
- `pkexec` (polkit) with an authentication agent — Noctalia's built-in
  agent works out of the box. Not needed for the PackageKit backend, which
  uses its own polkit policies.
- `sh`, `awk`, `sed`, `tail`, `test`, `uname` — base tools on any install.
- Optional: `paru`/`yay` (AUR, Arch family), `flatpak`, `xdg-open`,
  `sudo` + a terminal emulator for the **Retry in terminal** fallback.

## Usage

Add the `widget` bar widget from Noctalia's widget picker. Left click opens
the panel, right click checks for updates now. You can also open the panel
directly:

```sh
noctalia msg panel-toggle umedbazarov/linux-updater:panel
```

The panel lists pending packages by source (system manager, AUR, Flatpak).
Each package row has an ignore button, a copy button and an open button.
**Update** starts the background run: pkexec raises the polkit dialog,
everything else is non-interactive; the package list gives way to a live
log tail with a progress bar, the bar widget shows a percentage, and the
run survives a shell restart. When it ends you get a notification and an
automatic re-check; a failed run keeps its log on screen and offers
**Retry in terminal**.

The strip at the bottom is the update history: one segment per run, hover
for the date, click for the run's package list. Where the backend supports
rollback (see the matrix), packages or whole runs can be rolled back from
there — a second click confirms, and the package manager refuses any
transaction that would break dependencies.

If the system needs a one-time setup step (polkit keep-authorization rule
so one password covers a run; apt timers for fresh package lists), the
panel says so and offers to fix it with one confirmed click. Nothing is
ever changed silently.

Type `/up` in the launcher for quick actions or `/up <text>` to
fuzzy-search pending packages.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `backend` | `select` | `auto` | Package-manager backend; auto-detected from `/etc/os-release`. |
| `aur_helper` | `select` | `auto` | AUR helper (Arch family only): auto/yay/paru/custom/off. |
| `aur_check_cmd` | `string` | *(empty)* | Custom AUR check command when `aur_helper` is `custom`. |
| `flatpak_enabled` | `bool` | `true` | Also check and update Flatpak. |
| `ignore_packages` | `string_list` | *(empty)* | Packages excluded from the count and skipped on update (see matrix for the mechanism per backend). |
| `auto_check_hours` | `int` | `0` | Check automatically every N hours; 0 never. |
| `notify_on_updates` | `bool` | `true` | Desktop notification when updates are found. |
| `show_download_size` | `bool` | `true` | Show the download estimate where the backend supports it. |
| `check_arch_news` | `bool` | `true` | Arch news feed (pacman backend only). |
| `check_reboot_needed` | `bool` | `true` | Flag when a reboot is recommended. |
| `rollback_auto_ignore` | `bool` | `false` | After a rollback, add the rolled-back packages to the plugin ignore list. |
| `hide_setup_hints` | `bool` | `false` | Hide the one-time setup suggestions. |
| `hide_polkit_hint` | `bool` | `false` | Hide the polkit keep-authorization rule suggestion. |
| `log_lines` | `int` | `14` | Log lines shown during a run (6–30). |
| `terminal` | `string` | *(empty)* | Terminal for the fallback; empty uses Noctalia's detection. |
| `update_cmd` | `string` | *(empty)* | Full override for the background update command. |

## IPC

```sh
noctalia msg plugin umedbazarov/linux-updater:service all check
noctalia msg plugin umedbazarov/linux-updater:service all update
noctalia msg plugin umedbazarov/linux-updater:service all update_terminal
noctalia msg plugin umedbazarov/linux-updater:service all dismiss
noctalia msg plugin umedbazarov/linux-updater:service all ignore:NAME
noctalia msg plugin umedbazarov/linux-updater:service all unignore:NAME
```

## Notes

- **Commands spawned.** Per backend, listed in `backends/*.luau` (each file
  documents its own commands): the distribution's check command
  unprivileged; the update through `pkexec <manager>` (or PackageKit's own
  polkit path), detached, logged to `<data>/update.log` and followed with
  `tail`; `flatpak list/remote-ls/update`; `pactree`/`rpm`/`apt-mark`/
  `zypper locks`/`xbps-pkgdb` where the matrix says so.
- **Privileges.** Escalation only through polkit, only for package-manager
  binaries; the optional keep-authorization rules (shipped in `polkit/`,
  installable from the panel with one confirmed click) are scoped to those
  binaries for active local sessions. `pacman.conf`, apt or zypper
  configuration files are never edited.
- **Files written.** Only in the plugin data directory: `update.log`,
  `runs.json` (history), `ignore.json`, `news_state.json`, `run_meta.json`,
  a staged polkit rule and its install marker — plus
  `/etc/polkit-1/rules.d/49-linux-updater-<pm>.rules` when you explicitly
  click the install button.
- **Network.** Whatever the corresponding manual check/upgrade would
  contact, plus the Arch news feed (pacman backend, every 6 h).
## Testing status

Honest coverage, so expectations are set right:

- **Arch (pacman backend): fully exercised on a real system** — background
  updates including AUR builds, per-package rollback and roll-forward from
  the cache, ignore management, the polkit rule install, history, resume
  after a shell restart.
- **dnf / apt / zypper / xbps / PackageKit: command layers verified in
  containers** on real package managers — including the full
  `upgrade → dnf history undo` cycle on Fedora and apt's hold semantics —
  and every parser runs against recorded real-output fixtures in CI-able
  tests.
- **Not yet verified by anyone:** live polkit dialogs and the full UI on
  non-Arch distributions (containers cannot reproduce a polkit session),
  the dnf4 output branch (fixtures cover dnf5), Debian-specific deviations
  from Ubuntu. Treat non-Arch backends as **beta** — the capability matrix
  above is enforced in code, so the worst case is a missing feature, not a
  broken system.

**I would be genuinely glad to see this tested on other package managers
and distributions — Fedora, Ubuntu/Debian/Mint, openSUSE, Void, anything
with PackageKit. Feedback and bug reports on GitHub are very welcome:
please open an issue in
[community-plugins](https://github.com/noctalia-dev/community-plugins/issues)
with `[linux-updater]` in the title, and mention your distribution and the
backend the panel shows.**

## Credits

Grown out of [arch-updater](https://github.com/noctalia-dev/community-plugins/tree/main/arch-updater)
(yuuto, MIT), generalized to a backend architecture.

## License

MIT.
