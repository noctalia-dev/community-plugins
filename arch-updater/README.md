# Arch Updater

Check pacman, AUR and Flatpak for updates from the bar, with an estimated
download size and an Arch news heads-up before you upgrade. One click runs
the whole upgrade in the background: polkit asks for your password, the
panel shows a live log tail and a progress bar, and a notification reports
the result. A terminal fallback stays available for runs that need real
prompts.

## Plugin

| Field | Value |
| --- | --- |
| ID | `yuuto/arch-updater` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service`; launcher: `launcher` |
| Launcher Prefix | `/arch` |

## Requirements

- `pacman-contrib` on `PATH` (for `checkupdates`), required.
- `pacman`, `sh`, `awk`, `sed`, `tail`, `test` and `uname`, required — base
  tools from any standard Arch install, used to run and parse the checks,
  build the download size estimate, check the running kernel, and follow the
  update log.
- `pkexec` (polkit) with an authentication agent, required for the
  background update. Noctalia's built-in polkit agent works out of the box.
- `yay` or `paru` on `PATH`, optional, for the AUR check and update.
  Auto-detected by default, see the **AUR helper** setting.
- `flatpak`, optional, for the Flatpak check and update.
- `xdg-open`, optional, to open a package page, the update log, or the Arch
  news page.
- `sudo` and a terminal emulator, optional, only for the **Retry in
  terminal** fallback: Noctalia's own detection (`$TERMINAL`, then the
  common emulators), or the one named in the **Terminal** setting.

A missing optional tool is skipped, not treated as an error.

## Usage

Add the `widget` bar widget from Noctalia's widget picker. Left click opens
the panel, right click checks for updates now, middle click opens the
widget's own settings. You can also open the panel directly or bind it in
your compositor:

```sh
noctalia msg panel-toggle yuuto/arch-updater:panel
```

The panel groups pending packages by source (Pacman, AUR, Flatpak). Click a
source row to expand it into its packages. Each package row has an ignore
button (see **Ignored packages**), a copy button (name and versions) and an
open button (its page on archlinux.org, the AUR, or Flathub).

**Update** starts the background run: pkexec raises the polkit password
dialog, everything else is non-interactive (`--noconfirm`, and for the AUR
helper `--skipreview` / the `--answer*` flags), so any remaining question
gets its default answer. While the run is going the package list gives way
to a live tail of the update log with a progress bar, and the bar widget
shows a percentage instead of the count. The run is spawned detached, so it
survives a shell restart: a restarted engine re-attaches to an unfinished
log and keeps showing progress. When the run ends you get a notification
and an automatic re-check; a failed run keeps its log on screen and offers
**Retry in terminal**, where prompts and the PKGBUILD review work normally.

**Dismiss** clears the pending list until the next check. **Check Updates**
queries all sources.

Type `/arch` in the launcher for quick actions (check, update, open news),
or `/arch <text>` to fuzzy-search the packages from the last check.
Activating a result opens that package's page.

### Ignored packages

Three ignore sources are merged and shown in an expandable **Ignored**
section at the bottom of the package list:

- **Panel-managed.** The ignore button on a package row adds it to a list
  kept in the plugin's data directory. These entries have a restore button
  in the Ignored section.
- **The `ignore_packages` setting.** Shown with a *settings* tag; clicking
  the tag opens the plugin's settings.
- **`pacman.conf`'s `IgnorePkg`.** Update checkers report these packages
  with an `[ignored]` marker; they are shown with a *pacman.conf* tag and
  are managed only in that file. The plugin never edits `pacman.conf`.

Ignored packages are excluded from the pending count and passed as
`--ignore` to the update run (Flatpak refs are filtered out of `flatpak
update` the same way).

### One polkit password per run

`pkexec` authenticates every pacman transaction separately, so an update
that syncs databases and installs AUR builds can raise several password
dialogs. Until a keep-authorization polkit rule is installed, the panel
shows a hint line with an **Ask once** button: it installs (through one
`pkexec` call you confirm) a rule that keeps a successful authentication
for ~5 minutes — like `sudo`'s timestamp — scoped to `pkexec` launching
`/usr/bin/pacman` for an active local `wheel` session. The rule text ships
in `polkit/49-arch-updater-pacman.rules` and can also be installed by hand:

```sh
sudo install -Dm644 polkit/49-arch-updater-pacman.rules /etc/polkit-1/rules.d/49-arch-updater-pacman.rules
```

The hint can be hidden with the **Hide the polkit rule suggestion**
setting.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `aur_helper` | `select` | `auto` | Which AUR helper to use: auto-detect (yay, then paru), `yay`, `paru`, a custom command, or off. |
| `aur_check_cmd` | `string` | *(empty)* | Custom AUR check command, only used when `aur_helper` is `custom`. Must print `name oldver -> newver` per line. |
| `flatpak_enabled` | `bool` | `true` | Also check and update Flatpak. Skipped automatically when `flatpak` isn't installed. |
| `ignore_packages` | `string_list` | *(empty)* | Package names excluded from the count and passed as `--ignore` on update, on top of the panel-managed list and `pacman.conf`'s `IgnorePkg`. |
| `auto_check_hours` | `int` | `0` | Check automatically every N hours. `0` never checks on its own. |
| `notify_on_updates` | `bool` | `true` | Send a desktop notification when a check finds packages to upgrade. |
| `show_download_size` | `bool` | `true` | Show the estimated pacman download size (`pacman -Si`) in the panel. |
| `check_arch_news` | `bool` | `true` | Check the Arch Linux news feed and flag unread posts. |
| `check_reboot_needed` | `bool` | `true` | Flag when the running kernel is no longer installed on disk. |
| `hide_polkit_hint` | `bool` | `false` | Hide the panel line offering to install the polkit keep-authorization rule. |
| `log_lines` | `int` | `14` | How many of the latest update-log lines the panel shows during a run (6–30). |
| `terminal` | `string` | *(empty)* | Terminal command, only for the **Retry in terminal** fallback. Empty uses Noctalia's detection. |
| `update_cmd` | `string` | *(empty)* | Full override for the background update command. Empty builds it from the settings above, running pacman through `pkexec`. |
| `glyph` | `glyph` | `package` | The glyph shown for the widget on the bar. |
| `show_count` | `bool` | `true` | Show the pending-update count next to the bar glyph. |
| `hide_on_empty` | `bool` | `false` | Hide the widget entirely when there is nothing to show. |

## IPC

```sh
noctalia msg plugin yuuto/arch-updater:service all check
noctalia msg plugin yuuto/arch-updater:service all update
noctalia msg plugin yuuto/arch-updater:service all update_terminal
noctalia msg plugin yuuto/arch-updater:service all dismiss
noctalia msg plugin yuuto/arch-updater:service all ignore:NAME
noctalia msg plugin yuuto/arch-updater:service all unignore:NAME
```

`update` starts the background run, `update_terminal` the terminal
fallback. `ignore:NAME` / `unignore:NAME` edit the panel-managed ignore
list.

## Notes

- **Commands spawned.** Checks: `checkupdates`; the AUR helper's `-Qua` (or
  your custom command); `flatpak list` / `flatpak remote-ls --updates`
  (combined with `sed`/`awk`); `pacman -Si` piped through `awk` for the
  download size; `test -d` against `uname -r` for the reboot check. Update:
  a detached `sh` running `pkexec pacman -Syu` or the AUR helper with
  `--sudo pkexec`, then optionally `flatpak update` — all output redirected
  to the update log, which the engine follows with `tail`. The terminal
  fallback runs the interactive equivalents (`sudo pacman -Syu`, the helper
  without auto-answers) under your terminal, `tee`'d into the same log.
- **Privileges.** Escalation happens only through polkit: `pkexec pacman`
  for repo packages, and the AUR helper escalates its install steps through
  `pkexec` itself (`--sudo pkexec`). AUR builds run unprivileged as usual.
  The optional **Ask once** button installs the shipped polkit rule via one
  user-confirmed `pkexec install` call; nothing else touches system
  configuration, and `pacman.conf` is never modified.
- **Network.** `checkupdates`, the AUR helper and the Flatpak check contact
  mirrors, the AUR RPC, or a Flatpak remote, same as the corresponding
  upgrade would. The Arch news check fetches `archlinux.org/feeds/news/`
  once at startup and then every 6 hours.
- **Files written.** All in the plugin's data directory: `update.log` (the
  current/last run, with `::START`/`::EXIT` markers), `ignore.json` (the
  panel-managed ignore list), `news_state.json` (the last read news post),
  a staged copy of the polkit rule, and a marker recording that the rule
  was installed (`/etc/polkit-1/rules.d` is not readable by regular users
  on Arch, so presence can't always be probed directly).
- **Stuck-run guard.** A background run whose log stops growing for 30
  minutes is declared failed; the panel then offers the terminal fallback.
  Unfinished logs older than 6 hours are not resumed after a restart.
- **Sizes are pacman-only.** AUR and Flatpak downloads aren't sized. Most
  AUR packages build from source, where a download size wouldn't mean much.

## Credits

Ported from the v4 QML "Arch Updater" plugin (MIT), rebuilt for v5's Luau
plugin API. Background update mode, ignore management and the polkit
integration contributed by [UmedjonBA](https://github.com/UmedjonBA).

## License

MIT.
