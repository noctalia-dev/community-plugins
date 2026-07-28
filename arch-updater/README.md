# Arch Updater

Check pacman, AUR and Flatpak for updates from the bar, with an estimated
download size and an Arch news heads-up before you upgrade. Runs the update
in a terminal window.

## Plugin

| Field | Value |
| --- | --- |
| ID | `yuuto/arch-updater` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service`; launcher: `launcher` |
| Launcher Prefix | `/arch` |

## Requirements

- `pacman-contrib` on `PATH` (for `checkupdates`), required.
- `pacman`, `sh`, `sudo`, `awk`, `sed`, `test` and `uname`, required — base
  tools from any standard Arch install, used to run and parse the pacman
  check, build the download size estimate, check the running kernel, and
  run the plain-pacman upgrade.
- `yay` or `paru` on `PATH`, optional, for the AUR check and update.
  Auto-detected by default, see the **AUR helper** setting.
- `flatpak`, optional, for the Flatpak check and update.
- `xdg-open`, optional, to open a package page or the Arch news page.
- A terminal emulator for the update run: Noctalia's own detection
  (`$TERMINAL`, then `ghostty`, `kitty`, `alacritty`, `wezterm`, `foot`,
  `konsole`, `gnome-terminal`, `ptyxis`, `xterm`), or the one named in the
  **Terminal** setting.

Everything except `pacman-contrib`, `pacman`, `sh`, `sudo`, `awk`, `sed`,
`test` and `uname` is optional. A missing optional tool is skipped, not
treated as an error.

## Usage

Add the `widget` bar widget from Noctalia's widget picker. Left click opens
the panel, right click checks for updates now, middle click opens the
widget's own settings. You can also open the panel directly or bind it in
your compositor:

```sh
noctalia msg panel-toggle yuuto/arch-updater:panel
```

The panel groups pending packages by source (Pacman, AUR, Flatpak). Click a
source row to expand it into its packages. Each package row has a copy
button (name and versions) and an open button (its page on archlinux.org,
the AUR, or Flathub). **Check Updates** queries all sources, **Update** opens
a terminal running the upgrade, **Dismiss** keeps the numbers but returns the
bar glyph to its resting colour.

Type `/arch` in the launcher for quick actions (check, update, open news), or
`/arch <text>` to fuzzy-search the packages from the last check. Activating a
result opens that package's page.

## Extras

Not in the v4 plugin:

- **Arch Linux news.** The news feed is checked periodically. An unread post
  is flagged in the panel and the bar tooltip, with a button that opens the
  news page and marks it read. Arch news is where manual-intervention steps
  get announced, so it's worth seeing before a big upgrade.
- **Reboot recommendation.** Detected from whether the running kernel's
  `/usr/lib/modules/<version>` directory still exists, so it works for any
  kernel flavour (`linux`, `linux-lts`, `linux-zen`, `linux-cachyos`, ...)
  without naming one. Shown in the panel and the bar tooltip, and colours the
  bar glyph independently of the pending count.
- **Estimated download size** for the pending pacman packages (`pacman -Si`),
  shown before you commit to **Update**.
- **An ignore list that's actually enforced.** v4 only let you rewrite the
  raw check/update commands. Here, packages in **Ignore packages** are
  filtered out of both the count and the update run (`--ignore`), on top of
  `pacman.conf`'s own `IgnorePkg`.
- **Auto-detected AUR helper**, with `yay`/`paru`/a custom command/off as
  explicit overrides.
- **A generic package-page link** (`archlinux.org/packages`,
  `aur.archlinux.org`, `flathub.org`) instead of hardcoded per-repo mirror
  URLs, so it stays correct across Arch-based distros.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `aur_helper` | `select` | `auto` | Which AUR helper to use: auto-detect (yay, then paru), `yay`, `paru`, a custom command, or off. |
| `aur_check_cmd` | `string` | *(empty)* | Custom AUR check command, only used when `aur_helper` is `custom`. Must print `name oldver -> newver` per line. |
| `flatpak_enabled` | `bool` | `true` | Also check and update Flatpak. Skipped automatically when `flatpak` isn't installed. |
| `ignore_packages` | `string_list` | *(empty)* | Package names excluded from the count and passed as `--ignore` on update. |
| `auto_check_hours` | `int` | `0` | Check automatically every N hours. `0` never checks on its own. |
| `notify_on_updates` | `bool` | `true` | Send a desktop notification when a check finds packages to upgrade. |
| `show_download_size` | `bool` | `true` | Show the estimated pacman download size (`pacman -Si`) in the panel. |
| `check_arch_news` | `bool` | `true` | Check the Arch Linux news feed and flag unread posts. |
| `check_reboot_needed` | `bool` | `true` | Flag when the running kernel is no longer installed on disk. |
| `terminal` | `string` | *(empty)* | Terminal command for the update run, e.g. `kitty`. Empty uses Noctalia's detection. |
| `assume_yes` | `bool` | `false` | Pass `--noconfirm` / `-y` so package managers do not ask for confirmation. |
| `update_cmd` | `string` | *(empty)* | Full override for the update command. Empty builds it from the settings above. |
| `glyph` | `glyph` | `package` | The glyph shown for the widget on the bar. |
| `show_count` | `bool` | `true` | Show the pending-update count next to the bar glyph. |
| `hide_on_empty` | `bool` | `false` | Hide the widget entirely when there is nothing to show. |

## IPC

```sh
noctalia msg plugin yuuto/arch-updater:service all check
noctalia msg plugin yuuto/arch-updater:service all update
noctalia msg plugin yuuto/arch-updater:service all dismiss
```

## Notes

- **Commands spawned.** `checkupdates`; the configured AUR helper's `-Qua`
  (or your custom command); `flatpak list` / `flatpak remote-ls --updates`;
  `pacman -Si` for the download size (piped through `awk` to sum it); a local
  `test -d` against `uname -r` for the reboot check; and, for the update,
  your terminal running `sh` to launch `sudo pacman`/the AUR helper,
  optionally `flatpak update` (filtered through `awk` when packages are
  ignored, using `sed` to combine the Flatpak listings during the check). No
  upgrade command runs outside the terminal.
- **Network.** `checkupdates`, the AUR helper and the Flatpak check contact
  mirrors, the AUR RPC, or a Flatpak remote, same as the corresponding
  upgrade would. The Arch news check fetches `archlinux.org/feeds/news/` on
  its own schedule, independent of a manual check.
- **Privileges.** The plugin never elevates anything itself. Plain pacman
  updates run via `sudo pacman -Syu` in the terminal, where `sudo` prompts
  normally. An AUR helper handles its own privilege escalation as usual.
- **Files.** One small file in the plugin's data directory tracks the last
  Arch news post you've read, so unread counts survive a restart. Nothing
  else is written; `pacman.conf` is never modified.
- **Sizes are pacman-only.** AUR and Flatpak downloads aren't sized. Most AUR
  packages build from source, where a download size wouldn't mean much.

## Credits

Ported from the v4 QML "Arch Updater" plugin (MIT), rebuilt for v5's Luau
plugin API with a different feature set. See **Extras** above.

## License

MIT.
