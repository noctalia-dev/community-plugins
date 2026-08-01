# File Search

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: fuzzy
search files and folders as you type, with [fzf](https://github.com/junegunn/fzf)
as the matching subsystem. Click the bar glyph to open a search panel; picking
a result opens it with the system MIME association (`xdg-open`) — directories
open in your file manager. One button widens the search to the USB disks you
have plugged in, or narrows it to those alone.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/file-search` |
| Entries | Bar widget: `file-search`; panel: `panel`; launcher provider: `launcher` |
| Launcher Prefix | `/fs` |

## Usage

Add the `file-search` widget from Noctalia's widget picker and click it to
open the search panel. You can also open the panel directly or bind it in
your compositor:

```sh
noctalia msg panel-toggle nightwatch75/file-search:panel
```

| Action       | Effect                                          |
|--------------|-------------------------------------------------|
| Left click   | Open/close the search panel                     |
| Right click  | Open the search folder in the file manager      |

Middle click is not used: every bar widget carries a built-in binding for it
that opens the widget's own settings, and a bound gesture never reaches the
plugin. Use the panel's ⚙ button, or the command below, for the settings.

In the panel:

| Key     | Action                              |
|---------|-------------------------------------|
| `Enter` | Open the top match                  |
| `Esc`   | Close the panel (noctalia default)  |

On a result row:

| Action      | Effect                                                   |
|-------------|----------------------------------------------------------|
| Left click  | Open it with the system MIME association                 |
| Right click | Copy its path, *or* reveal it in the file manager        |

The 🗐/🗁 button in the panel header picks which of the two, and remembers it.
*Reveal* opens the containing folder with the item selected. Both leave the
panel up, so several rows can be picked off in a row. (Middle click is not an
option: a panel row only ever receives left and right clicks.)

A path too long for one row is shortened in the middle rather than at the end,
so the file name — the part the query matched — always stays readable:
`.local/share/flatpak/repo/tmp/cache/…dolphin.idx.sig`.

The plugin version sits next to the panel title. The footer counts what is
listed and what is indexed, and on the right how long the walk behind that
index took — per scope, kept across restarts, and still visible while a new
walk runs, which is when knowing the last one's cost is most useful.

### Search syntax

The query goes to `fzf` as-is, so its extended-search operators work here. The
panel keeps a one-line reminder of them above the status bar.

| Query | Matches |
|---|---|
| `panel luau` | both terms, in any order (space is AND) |
| `'panel.luau` | **exact**, not fuzzy — a single quote, not double quotes |
| `^src` | at the start |
| `.webp$` | at the end |
| `luau !src` | `luau`, excluding anything with `src` |
| `.toml$ \| .json$` | either one (spaces around the `\|` are required) |

A lowercase query is case-insensitive; one uppercase letter anywhere makes it
case-sensitive. There is no regex: fzf does not have one.

The 🗠/🗺 button in the header switches how matches are scored, and remembers it:

| Glyph | Ranking |
|---|---|
| 🗺 | **path-aware** *(default)* — a match starting a file or folder name wins, so `config` finds `.ssh/config` and not the deepest `…/Steam Controller Configs/` |
| 🗠 | generic — fzf's own scoring, which mostly rewards the shortest path |

Path-aware costs about a third more CPU per keystroke and needs fzf 0.36 or
newer; on an older build the button stays on generic and says so.

### Searching external disks

The 🗀 button in the panel header cycles what the search covers:

| Glyph | Scope | Covers |
|-------|-------|--------|
| 🗀 | Search folder only *(default)* | The `search_folder` setting, as before |
| 🗀🗀 | Search folder + external disks | Both, in one index |
| ⚿ | External disks only | Only the mounted removable volumes |

An *external disk* is a mounted volume that came from a USB port or reports
itself removable: sticks and drives (bus-powered SSDs and LUKS-encrypted ones
included), SD cards, optical media. Internal drives never count, not even a
second SATA/NVMe under `/mnt` — put that in `search_folder` instead. The plugin
mounts nothing; it only sees what your desktop has already mounted.

The choice survives restarts and is shared with the `/fs` launcher, which offers
the same switch. Each scope keeps its own index, so switching to the disks and
back does not re-walk your home folder.

**External disks are only ever indexed on command**, because walking a
multi-terabyte drive takes minutes. Switching scope, opening the panel, changing
a setting or plugging a disk in never start a walk: the index stays in use and
the footer says *out of date*. The ↻ button (or *Rebuild search index* in the
launcher) is what rebuilds it, and a scope never indexed says so and waits. The
search folder alone keeps re-indexing itself, as before — it takes seconds.

The panel header also carries a ⚙ button that opens this plugin's page in
*Settings → Plugins*, and a ↻ button that rebuilds the index. The same settings
page opens from the command line, so it can be bound in your compositor too:

```sh
noctalia msg settings-open-plugin nightwatch75/file-search
```

In the noctalia launcher (keyboard-first flow, native navigation):

| Key         | Action                                    |
|-------------|-------------------------------------------|
| `/fs <text>`| Fuzzy search files and folders            |
| `↑` / `↓`   | Move through the results                  |
| `Enter`     | Open the selected result (MIME/xdg-open)  |

With an empty `/fs` query the list also offers *Rebuild search index* and the
scope switch; the index is shared with the panel. *Rebuild search index* walks
the tree there and then, keeping the launcher open, and is offered next to the
results whenever the index is out of date.

## Features

- Live results while you type: the search folder is walked once with `find`
  into a cache, then every keystroke is fuzzy-matched through
  `fzf --filter`, so typing stays responsive even on large trees
- Configurable bar glyph, search folder (defaults to `~`), excluded folder
  names (`.git, node_modules, .cache, .venv` by default, matched anywhere in
  the tree), hidden entries on/off, max results
- One button to search the mounted USB/removable disks as well, or only those:
  one index per scope, and disks walked only when you ask
- `Enter` opens the top match; every result row opens on click via the
  system MIME association — files in their default app, folders in the file
  manager
- Launcher provider for a keyboard-first flow: type `/fs <text>` in the
  noctalia launcher and navigate the results with the native arrow keys +
  `Enter` (plugin panels cannot receive arrow keys in the current Luau API,
  so the launcher is the keyboard way to browse results)
- Folder results are marked with a trailing `/` and a folder glyph
- Right click copies a result's path, or reveals it in the file manager with the
  item selected (`org.freedesktop.FileManager1.ShowItems` — Thunar, Nautilus,
  Dolphin, Nemo, Caja and PCManFM-Qt all implement it)
- The search-folder index rebuilds itself when the relevant settings change, and
  on demand via the panel's refresh button; any index covering an external disk
  rebuilds on demand only
- Panel placement (attached/floating), position and open-near-click are the
  standard per-panel settings noctalia exposes in Settings → Plugins

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `search_folder` | `folder` | *(empty)* | Root folder the search indexes. Empty = your home folder. |
| `exclude_dirs` | `string` | `.git, node_modules, .cache, .venv` | Folder names skipped while indexing, separated by `,` or `;`, matched anywhere in the tree. |
| `show_hidden` | `bool` | `false` | Index files and folders whose name starts with a dot. |
| `max_results` | `int` | `50` | How many matches the panel lists at most (10–200). |
| `glyph` (widget) | `glyph` | `search` | Icon shown on the bar. |

## Requirements

- noctalia v5.0.0-beta.6 or newer — the first tagged release that accepts
  `plugin_api = 15` (`noctalia.openSettings()`, the panel's ⚙ button)
- [`fzf`](https://github.com/junegunn/fzf) — the fuzzy matcher. 0.36 or newer
  for the path-aware ranking; older builds work, with fzf's default ranking
- `find` (GNU findutils) — walks the roots into the index
- `xdg-open` (xdg-utils) — opens results with the MIME association
- `mktemp`, `mv`, `wc`, `head`, `rm`, `date` — GNU coreutils, standard on any
  Linux desktop (`date` times the index walk for the footer)
- `lsblk` (util-linux) — lists the mounted USB/removable volumes; only run when
  the scope includes them. Missing, it falls back to `/proc/mounts` and the
  udisks2 layout (`/run/media/<user>/…`, `/media/…`)
- `gdbus` (glib2) — reveals a result in the file manager
  (`FileManager1.ShowItems`); only run on that right click. Missing, or with no
  file manager implementing it, the click opens the containing folder instead

## Install

Install **File Search** from Noctalia's plugin store (*Settings → Plugins*),
then add the widget to a bar from *Settings → Bar*. Plugin options live in
*Settings → Plugins*.

For local development, add your working copy as a path source instead
(`.luau` edits hot-reload):

```sh
noctalia msg plugins source add dev path /path/to/plugins
noctalia msg plugins enable nightwatch75/file-search
```

## Notes

- The index lives in the plugin's private data directory
  (`noctalia.pluginDataDir()`, by default
  `~/.local/state/noctalia/plugins/data/nightwatch75/file-search/` — honors
  `NOCTALIA_STATE_HOME`/`XDG_STATE_HOME`): `list-<scope>` is a plain list of
  paths, `meta-<scope>` records the scope, roots and exclusions that built it,
  `count-<scope>` its line count and the walk's duration in milliseconds, and
  `scope`, `row-action` and `ranking` the one word each
  header toggle cycles. A fingerprint that no longer matches — a settings
  change, a scope change, a disk plugged in or removed — rebuilds the
  search-folder index automatically and marks a disk index out of date.
- Several disks share one index, not one each: a rebuild walks every mounted
  volume in a single pass. Records are relative to the root when there is only
  one (the common case, and what keeps the rows short) and absolute when there
  are several — and they are always read the way the index was *written*, so
  unplugging one of two disks leaves the rest of the results openable.
- Volume metadata is pruned at every root, since a disk used on Windows or macOS
  otherwise contributes tens of thousands of records that are not your files:
  `lost+found`, `$RECYCLE.BIN`, `RECYCLER`, `System Volume Information`,
  `.Trash-*`, `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems`,
  `.DocumentRevisions-V100`, `Backups.backupdb`, `*.sparsebundle`,
  `*.backupbundle`, `._*`, `.DS_Store`, `.AppleDouble`, `.AppleDB`,
  `.AppleDesktop`, `Network Trash Folder`, `Temporary Items`,
  `TheVolumeSettingsFolder`.
- `find` is bound by metadata latency, so a spinning USB drive with a million
  files runs for minutes — hence on-demand only. A walk covering disks gets 30
  minutes against 3 for the search folder, and the panel stays usable
  throughout, scope button included: a second walk is never queued.
- Cheap by design elsewhere too: the mount scan is cached 30 seconds and never
  concurrent, and the line count comes from a `count-<scope>` sidecar instead of
  re-reading a >100 MB index.
- Detection reads the transport and removable flags of the parent disk, not of
  the mounted partition — a USB partition reports neither. NVMe and SATA drives
  advertising hot-plug are deliberately not treated as removable.
- Both files are written to `mktemp`-created private files and renamed into
  place, so a rebuild never writes through a symlink planted at the cache
  path.
- Names containing a newline are excluded from the index (they would break
  the one-record-per-line format), and every record is validated against the
  roots it claims to come from before being opened.
- Excluded entries match by folder/file *name* (`find -name`), not by path;
  entries containing `/` are skipped and logged.
- With hidden entries off, anything starting with a dot is pruned — both
  hidden folders (not descended into) and hidden files.
- Unreadable subtrees are silently skipped (permission errors don't fail the
  index).

## License

MIT.
