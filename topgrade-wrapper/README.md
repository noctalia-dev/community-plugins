# Topgrade Wrapper

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin that drives
[topgrade](https://github.com/topgrade-rs/topgrade), the "upgrade everything"
tool. The bar glyph shows how many packages are waiting, and the panel checks
for updates and starts the run in a terminal window — so you get the pending
count at a glance without giving up the interactive upgrade.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/topgrade-wrapper` |
| Entries | Bar widget: `topgrade-wrapper`; panel: `panel`; service: `service` |

## Requirements

Noctalia with plugin API 9 or newer (the panel wires its callbacks as closures),
and `topgrade` on `PATH`. A terminal emulator is needed for the update run:
the plugin uses Noctalia's own detection (`$TERMINAL`, then `ghostty`, `kitty`,
`alacritty`, `wezterm`, `foot`, `konsole`, `gnome-terminal`, `ptyxis`, `xterm`),
or the one named in the **Terminal** setting.

Everything else is optional and affects only the count, never the upgrade.

### Count coverage

A manager is counted when the tool that can answer "how many updates?" is
installed. Nothing here is required: an absent tool costs you a number, not a
feature.

| Counted | Needs |
| --- | --- |
| Arch repositories | `checkupdates` (from `pacman-contrib`) |
| AUR | `yay` or `paru` |
| Debian/Ubuntu | `apt-get` |
| Fedora/RHEL | `dnf` |
| openSUSE | `zypper` |
| Flatpak, Snap, Homebrew | `flatpak`, `snap`, `brew` |
| Cargo, npm, RubyGems, pip | `cargo-install-update` (from `cargo-update`), `npm`, `gem`, `pip` |

Anything topgrade would run but this list does not cover — Void's `xbps`,
Gentoo's `emerge`, Alpine's `apk`, Nix, VS Code extensions, container images,
and so on — is named in the panel under *Not counted*, and left out of the
total. A step that is only partly covered names the manager that could not
answer instead: on Arch with an AUR helper but no `pacman-contrib`, the panel
counts the AUR and lists **Pacman** as not counted, so the total is never
mistaken for the whole system update.

## Usage

Add the `topgrade-wrapper` widget from Noctalia's widget picker, then click it to
open the panel. You can also open the panel directly or bind it in your
compositor:

```sh
noctalia msg panel-toggle nightwatch75/topgrade-wrapper:panel
```

| Action                            | Effect                                                      |
|-----------------------------------|-------------------------------------------------------------|
| Left click (bar glyph)            | Open/close the panel                                        |
| Right click (bar glyph)           | Check for updates now                                       |
| **Check Updates** (panel)         | Count what topgrade would upgrade                           |
| Click a manager row (panel)       | Expand or collapse the packages behind its number            |
| Hover a package (panel)           | Show its full `installed → available` versions below the list |
| **Update** (panel)                | Run topgrade in a terminal window                           |
| **Dismiss** (panel)               | Keep the numbers but return the bar glyph to its resting colour |
| ↻ refresh (panel header)          | Same as **Check Updates**                                   |

The glyph turns to the accent colour with the pending count next to it once a
check finds something, stays neutral while everything is up to date or after
**Dismiss**, and turns red when `topgrade` is missing or a check failed. Its
tooltip carries the status, the per-manager breakdown, and the time of the last
check. Middle click is not used: every bar widget carries a built-in binding for
it that opens the widget's own settings.

### Checking

topgrade has no "how many packages?" mode, so the check runs in two stages:

1. `topgrade --dry-run --no-self-update` reports the steps topgrade *would* run.
   Your own topgrade configuration decides that list, which is exactly what the
   count needs to reflect, and the **Excluded steps** setting is layered on top
   of it.
2. Every package manager named in that output is asked once, with a read-only
   query, to *list* what it has pending — `checkupdates`, `flatpak remote-ls
   --updates`, and so on. The queries run one at a time.

The panel then shows one row per manager that has updates, the total in the
headline, and two captions: *Up to date* for the managers that answered zero,
and *Not counted* for the steps that ran but that no query covers (VS Code
extensions or container images, say). A manager whose query times out or reports
an error is moved to *Not counted* rather than shown as zero; a query that simply
comes back empty is taken at its word.

**Click a manager row** to expand it into the packages behind its number, and
click again to fold it. The number *is* the length of that list — the queries list
rather than count, so the two can never disagree and expanding a row costs no
second trip to a mirror.

Each package shows its name and, where the manager reports them, `installed →
available` with the incoming version in the accent colour. Arch git-snapshot
versions run long, so the pair is elided to fit the row; **hover a package** and
the line under the list spells it out in full. (Noctalia's plugin UI has no
tooltip for a plain row — only buttons take one — so the detail line is where the
untruncated text goes. It stays visible while any list is open, hovered or not,
because a line that appeared on hover would resize the list under your pointer.)

Flatpak is a special case: it tracks commits, so an app's version string often
does not move across an update. When it does, the pair is shown as usual; when it
does not, the short commits stand in (`187a4c5 → 7a8c453`) rather than an arrow
between two identical numbers. Homebrew and npm report names only.

Turn **Show package versions** off to get plain name-only rows. The hover line
stays exactly as it is with them on, so the versions remain one hover away — the
setting decides how much each row carries at rest, not whether the detail is
available.

Very long lists are trimmed for display, with a `+N more` line so the rows never
quietly contradict the count. A re-check folds every row back.

Checks only happen when you ask for one, unless you set an **Auto-check
interval**.

### Updating

**Update** opens a terminal window running `topgrade`. Nothing is upgraded in the
background: package managers keep their prompts, and `sudo` asks for your
password on the terminal's tty. The window closes when the run ends unless you
enable **Keep the terminal open**.

While the run is in flight the panel says so, and the plugin watches for the
`topgrade` process; as soon as it is gone the counts are refreshed automatically,
so the bar clears itself without another click.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `topgrade_config` | `file` | *(empty)* | Alternative topgrade configuration, passed as `--config`. Empty lets topgrade resolve its own file. |
| `exclude_mode` | `select` | `config` | Where skipped steps come from: `topgrade configuration` (its `disable` list alone) or `Override with the list below`. |
| `exclude_steps` | `string_list` | *(empty)* | topgrade step ids to skip, passed as `--disable <id>` (e.g. `flatpak`, `cargo`, `containers`). Only shown, and only applied, in override mode. Run `topgrade --help` for the full list. |
| `auto_check_hours` | `int` | `0` | Check automatically every N hours. `0` never checks on its own. |
| `notify_on_updates` | `bool` | `true` | Send a desktop notification when a check finds packages to upgrade. |
| `show_versions` | `bool` | `true` | Show `installed → available` beside each package in an expanded row. Off lists names only; hovering still shows the full pair under the list either way. |
| `terminal` | `string` | *(empty)* | Terminal command for the update run, e.g. `kitty`. Empty uses Noctalia's detection. |
| `assume_yes` | `bool` | `false` | Pass `--yes` so package managers do not ask for confirmation. |
| `sudo_loop` | `bool` | `false` | Pass `--sudoloop`, so the password is asked once and the sudo timestamp is refreshed for the whole run. |
| `keep_terminal_open` | `bool` | `false` | Pass `--keep` so the window waits for a key press instead of closing. |
| `glyph` | `glyph` | `package` | The glyph shown for the widget on the bar. |
| `show_count` | `bool` | `true` | Show the pending-update count next to the glyph. |

### Excluding steps

By default the plugin adds nothing of its own: what topgrade skips is whatever
the `disable` list in your `topgrade.toml` says, and the count follows. Switch
**Excluded steps source** to *Override with the list below* to reveal the
**Excluded steps** list and have its ids passed as `--disable <id>` on every
command line, check and run alike. Your configuration file is never rewritten —
and because `--disable` only ever adds, this layers on top of the config's own
exclusions rather than replacing them; it cannot re-enable a step your
`topgrade.toml` disables.

Switching the mode, or editing the list, invalidates the last count: it
described a different invocation.

Ids are validated before they reach the command line, and only `[a-z0-9_]` is
accepted; anything else is dropped with a line in the Noctalia log. An id
topgrade does not know makes the check fail with topgrade's own message
("invalid value … for `--disable`") in the panel, which tells you what to fix.

## IPC

The service accepts the same three actions as the panel buttons, so a check or a
run can be bound to a key or driven from a script:

```sh
noctalia msg plugin nightwatch75/topgrade-wrapper:service all check
noctalia msg plugin nightwatch75/topgrade-wrapper:service all update
noctalia msg plugin nightwatch75/topgrade-wrapper:service all dismiss
```

## Notes

- **Commands spawned.** `topgrade --dry-run --no-self-update` for the step list;
  one read-only listing query per detected manager (`checkupdates`, `yay -Qua`,
  `paru -Qua`, `apt-get -s upgrade`, `dnf check-update`, `zypper list-updates`,
  `flatpak list` + `flatpak remote-ls --updates`, `snap refresh --list`,
  `brew outdated`, `cargo install-update --list`, `npm -g outdated`,
  `gem outdated`, `pip list --outdated`, each piped through `awk`/`sed` to one
  package per line);
  and, for the run, your terminal with `topgrade` inside it. Nothing else, and no
  upgrade command is ever run outside the terminal window.
- **Network.** Several count queries contact package mirrors, the AUR RPC, or a
  Flatpak remote, exactly as the corresponding upgrade would. They are read-only
  and only run when a check runs.
- **Privileges.** The plugin never elevates anything itself. topgrade escalates
  per step with its own `sudo_command`, which prompts on the terminal's tty.
  Setting `sudo_command = "pkexec"` in your `topgrade.toml` routes that prompt
  through Noctalia's polkit agent instead, as a graphical dialog.
- **Files.** The plugin writes nothing: no cache, no state file, and your
  `topgrade.toml` is never modified — step exclusions are command-line
  overrides.
- **Counts are per manager, not per step.** A count is only ever as good as the
  query behind it, so managers without one are named instead of estimated. The
  total is the sum of the rows shown, nothing more.
- **Settings that change the command line** (the configuration file and the
  excluded steps) invalidate the last result, since it described a different
  run; cosmetic edits such as the glyph leave it alone.

## Install

Install **Topgrade Wrapper** from Noctalia's plugin store (*Settings →
Plugins*), then add the widget to a bar from *Settings → Bar*. Plugin options
live in *Settings → Plugins*.

For local development, add your working copy as a path source instead
(`.luau` edits hot-reload):

```sh
noctalia msg plugins source add dev path /path/to/plugins
noctalia msg plugins enable nightwatch75/topgrade-wrapper
```

## License

MIT.
