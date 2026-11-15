# File Search

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: fuzzy
search files and folders as you type, matched with
[fzf](https://github.com/junegunn/fzf). Click the bar glyph to open a search
panel; picking a result opens it with the system MIME association
(`xdg-open`) — directories open in the file manager. A `/fs` launcher entry
gives the same search with native keyboard navigation. The panel can widen
the search to folders you add and to mounted USB/removable disks, and show a
disk-usage donut for the search folder. A second panel tab, **Space**, browses disk usage with
`ncdu`: a donut, a sortable folder list and a file-type view.

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

| Action      | Effect                                     |
|-------------|---------------------------------------------|
| Left click  | Open/close the search panel                |
| Right click | Open the search folder in the file manager |

Middle click is not handled: every bar widget carries a built-in binding for
it that opens the widget's own settings, so a bound gesture never reaches the
plugin. Use the panel's settings button, or the command below.

### The panel

| Key     | Action                                                  |
|---------|---------------------------------------------------------|
| ↑ / ↓   | Move the selection through the results (hold to repeat) |
| `Enter` | Open the selected result (the top match until moved)    |
| `Esc`   | Close the panel (noctalia default)                      |

The list scrolls to keep the selection in view. The mouse wheel still scrolls
freely; the next ↑ or ↓ brings the selection back.

Under the search box, three exclusive buttons choose where to search (see
*Where to search*), followed by **Re-index**, which rebuilds the index (and
re-measures disk usage). A row of toggles comes next:

| Button | Effect |
|---|---|
| Chart | Shows/hides the disk-usage donut |
| Ranking | Switches how matches are scored (see *Search syntax*) |
| USB disks | Adds the mounted removable disks to the search (see *Searching external disks*) |

Header buttons, left to right:

| Glyph | Button | Effect |
|---|---|---|
| ⚙ | Settings | Opens this plugin's page in *Settings → Plugins* (same as `noctalia msg settings-open-plugin nightwatch75/file-search`) |
| ✕ | Close | Closes the panel |

Every choice made from these buttons (ranking, mode, USB disks, usage
chart shown or not) survives a restart. The plugin version sits next to the panel title; the
footer shows how many results are listed, how many entries are indexed, and
how long the last index build took.

On a result row:

| Action      | Effect                                    |
|-------------|--------------------------------------------|
| Left click  | Open it with the system MIME association  |
| Right click | Open the row menu                         |

| Row menu entry        | Effect                                            |
|------------------------|----------------------------------------------------|
| Open                   | Same as a left click                              |
| Show in file manager   | Open the containing folder with the item selected |
| Copy full path         | Put the absolute path on the clipboard            |
| Copy name              | Put just the file or folder name on the clipboard |

Everything but *Open* leaves the panel up, so several rows can be picked off
in a row. A path too long for one row is shortened in the middle, keeping the
file name (the part the query matched) readable:
`.local/share/flatpak/repo/tmp/cache/…dolphin.idx.sig`.

### Search syntax

The query goes to `fzf` as-is, so its extended-search operators work here.
The panel keeps a one-line reminder of them above the results.

| Query | Matches |
|---|---|
| `panel luau` | both terms, in any order (space is AND) |
| `'panel.luau` | **exact**, not fuzzy — a single quote, not double quotes |
| `^src` | at the start |
| `.webp$` | at the end |
| `luau !src` | `luau`, excluding anything with `src` |
| `.toml$ \| .json$` | either one (spaces around the `\|` are required) |

A lowercase query is case-insensitive; one uppercase letter anywhere makes it
case-sensitive. There is no regex — fzf does not have one.

The ranking button switches how matches are scored:

| Ranking | Effect |
|---|---|
| **Path-aware** *(default)* | A match starting a file or folder name wins, so `config` finds `.ssh/config`, not `…/Steam Controller Configs/` |
| Generic | fzf's own scoring, which mostly rewards the shortest path |

Path-aware needs fzf 0.36 or newer; on an older build the button stays on
generic and its tooltip says why.

### Where to search

| Mode | Covers |
|---|---|
| Home only *(default)* | The `search_folder` setting |
| Home + folders | The search folder and the folders you add |
| Whole system | All of `/` (see *Whole-system search*) |

The *Add search path* button next to the search box works in *Home + folders*
only (it is greyed out otherwise). It opens a path field under the box: type an
absolute path (or `~/…`) and press Enter. The added folders are listed there,
each with a ✕. The folder must exist. Use it for a second partition, for example `/media/data`.
The list is kept in the plugin data directory (`extra_roots`, one path per
line) because a plugin cannot write its own settings. Adding or removing a
folder rebuilds the index. It stays saved when you switch to another mode.

### Searching external disks

The *USB disks* toggle adds the mounted removable volumes to whichever mode is
on, in the same index.

An *external disk* is a mounted volume that came from a USB port or reports
itself removable: sticks, bus-powered SSDs, LUKS-encrypted drives, SD cards,
optical media. Internal drives never count — put those in `search_folder`
instead. The plugin mounts nothing; it only sees what your desktop already
mounted. With the toggle on, its tooltip also shows free space across them.

The mode and the toggle are shared with the `/fs` launcher, and each
combination keeps its own index — switching and switching back never re-walks
the search folder.

**External disks are only ever indexed on command.** Opening the panel,
switching mode, changing a setting or plugging a disk in never starts a
walk with USB disks on — the index stays as-is and the footer says *out of
date*. Press *Re-index* (or *Rebuild search index* in the launcher) to walk it.
With USB disks off, the index keeps re-indexing itself automatically, since
that takes seconds rather than minutes.

### Disk usage chart

A donut left of the results shows what fills the search folder: its biggest
direct children, the rest folded into *other*, and loose files that belong
to no subfolder. Each legend row gives the size and share of the total. It
is offered in every mode except *Whole system*; it always measures the search
folder, never an added folder or a disk.

Click a folder in the legend to search inside it: results narrow to that
folder, a strip above them names it, and clicking the strip's ✕ (or the same
row again) lifts the restriction. It combines with whatever you type — pick
`winboat`, type `img`, get `winboat/data.img`.

Sizes come from `du -x -d1`, measured once and cached for a day, so restarts
and reopens cost nothing (`du` over a home directory takes a few seconds).
The *Re-index* button re-measures immediately. Other filesystems are never
walked — a mount point under the search folder is skipped and named in the
legend as *not counted: … (other filesystem)*. The `usage_exclude_dirs`
setting keeps `du` out of specific, slow-but-same-filesystem folders instead.

### Space tab

You can turn this tab off with the `space_enabled` setting.

The *Space* tab shows what fills the disk. It starts with your home folder;
the `/` button switches to the whole system. A donut and a clickable legend show the biggest
items of the current folder; click a folder to go in, use the up arrow to go
back, or the top arrow to jump to the top of the home folder. The buttons are under the
donut; the list on the right sorts by size or name. In the file list of a type,
*Name* sorts by the file name and *Path* by the full path. *Folders | Types* switches to a
view by file type (video, images, audio…) and lists the 10 biggest files of a
type; a line above the list says when it shows only those 10. When all the
files listed are in one folder, that folder is shown once above the list. The search button goes back to the Search tab and
restricts the search to the current folder, if it is inside the search folder;
for any other folder it shows a notice. Right-click a row of the list for
open / show in file manager / copy path / copy name.

### Launcher

```
/fs <text>
```

| Key       | Action                                   |
|-----------|--------------------------------------------|
| ↑ / ↓     | Move through the results                  |
| `Enter`   | Open the selected result (MIME/`xdg-open`) |

An empty `/fs` query also offers *Rebuild search index* and the USB disks
toggle; the index is shared with the panel. *Rebuild search index* walks the
tree right away, keeping the launcher open, and is offered next to the
results whenever the index is out of date.

## Features

- Live results while you type: the search folder is walked once with `find`
  into a cache, then every keystroke is fuzzy-matched with `fzf --filter`
- Configurable search folder (defaults to `~`), excluded folder names, hidden
  entries on/off, max results, and bar glyph
- Folder results are marked with a trailing `/` and a folder glyph
- Reveal in file manager uses `org.freedesktop.FileManager1.ShowItems`
  (Thunar, Nautilus, Dolphin, Nemo, Caja, PCManFM-Qt); falls back to opening
  the containing folder if no file manager implements it
- Panel placement (attached/floating), position and open-near-click are the
  standard per-panel settings noctalia exposes in *Settings → Plugins*

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `search_folder` | `folder` | *(empty)* | Root folder the search indexes. Empty = your home folder. |
| `exclude_dirs` | `string` | `.git, node_modules, .cache, .venv` | Folder names skipped while indexing, separated by `,` or `;`, matched anywhere in the tree. |
| `show_hidden` | `bool` | `false` | Index files and folders whose name starts with a dot. |
| `usage_exclude_dirs` | `string` | *(empty)* | Folders left out of the usage chart and the Space scan, separated by `,` or `;`. A name matches anywhere below the search folder. An absolute or `~` path skips that one folder, e.g. a disk under `/mnt`. |
| `space_enabled` | `bool` | `true` | Show the Space tab. Turn it off to use only the search: the tab bar is hidden and nothing is scanned. The panel keeps its width. |
| `space_skip_network` | `bool` | `true` | Space tab: do not scan network mounts (NFS, SMB…) and FUSE mounts (rclone, sshfs, OneDrive…). |
| `space_skip_external` | `bool` | `true` | Space tab: do not scan external (removable) disks. |
| `max_results` | `int` | `50` | How many matches the panel lists at most (10–200). |
| `glyph` (widget) | `glyph` | `search` | Icon shown on the bar. |

## Requirements

- noctalia with `plugin_api = 33` (the release after v5.2.1 that adds
  `revealKey` on `ui.scroll`, which keeps the keyboard selection in view; an
  older shell keeps being served the last version it can load) — also for
  the row context menu, relative Luau imports (the three entries share
  `shared.luau`) and direct argv process execution, so `du`, `xdg-open` and
  the reveal call take their arguments with no shell parsing them
- [`fzf`](https://github.com/junegunn/fzf) — the fuzzy matcher. 0.36 or newer
  for path-aware ranking; older builds work with fzf's default ranking
- `find` (GNU findutils) — walks the roots into the index
- `xdg-open` (xdg-utils) — opens results with the MIME association
- `mktemp`, `mv`, `wc`, `head`, `rm`, `date`, `du` — GNU coreutils, standard
  on any Linux desktop. Missing `du`, the usage chart says so; everything
  else still works
- [`ncdu`](https://dev.yorhel.nl/ncdu) 2.0 or newer — scans the disk for the
  Space tab (needed only for the Space tab)
- [`jq`](https://jqlang.github.io/jq/) — reduces the scan to the Space index
  (needed only for the Space tab)
- `nice` (GNU coreutils) — runs the scan at low priority (needed only for the
  Space tab)
- `lsblk` (util-linux) — lists mounted USB/removable volumes, only run when
  USB disks are on. Missing, it falls back to `/proc/mounts` and the
  udisks2 layout (`/run/media/<user>/…`, `/media/…`)
- `gdbus` (glib2) — reveals a result in the file manager. Missing, or with no
  file manager implementing `FileManager1`, *Show in file manager* opens the
  containing folder instead

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

### Whole-system search

The *Whole system* mode searches all of `/` instead of the search folder. It
is off by default. `/proc`, `/sys`, `/dev`, `/run`, remote and FUSE mounts (NFS, CIFS,
sshfs, rclone, OneDrive…) and removable disks stay excluded. Unreadable
folders are skipped.

## Notes

- The Space tab scans your home folder with `ncdu` on its first use; a scan
  of `/` takes about 45 s on a fast PC. `jq` can use up to about 1.5 GB RAM for a moment. Both run at low
  priority. The index is cached for one day; refresh forces a rescan.
- The Space progress bar is an estimate from the duration of the last scan of
  the same folder and settings. The first scan shows only the elapsed time.
- The Space list shows how many files each folder holds (links and symlinks
  count once per name).
- Network, FUSE and external mounts are skipped by default
  (`space_skip_network`, `space_skip_external`). Pseudo filesystems (`/proc`,
  overlay, squashfs…) are always skipped.
- The Space scan also leaves out the folders in "Disk usage: excluded
  folders". Each combination of these three settings has its own cached
  index: after a change, the Space tab starts a new scan when it opens.
- Folders under 1 MiB, or under 0.05% of their parent folder, are counted in
  "(files and small folders)". Drill-down stops at depth 6.
- If the disk index is too big for the plugin (very large disks), the tab
  asks you to skip more folders in the settings. A normal index is about
  4 MB and takes about 25 MB of plugin memory while it loads.
- `ncdu`, `jq` and `nice` are searched in `/usr/bin`, `/usr/local/bin`, `/bin`
  and `~/.local/bin` only: a detached run has no login PATH. Tested with
  `jq` 1.8.
- Hard-linked files have their size split between the links, so a folder total
  can differ from the `ncdu` screen. The root total stays exact.
- A folder that `ncdu` cannot read (permission denied) counts as 0 bytes. The
  Space tab shows how many such folders the current folder contains.
- The index lives in the plugin's private data directory
  (`noctalia.pluginDataDir()`, by default
  `~/.local/state/noctalia/plugins/data/nightwatch75/file-search/`):
  `list-<tag>` is the plain list of paths, `meta-<tag>` the fingerprint
  it was built with, `count-<tag>` its entry count and build time, and
  `scope`/`whole-system`/`folders`/`ranking`/`usage-chart` the one-word header
  choices and `extra_roots` the added folders. The disk usage
  measurement is cached in `usage.json`, rendered as one of two alternating
  SVG files. The Space tab keeps one index per folder and settings
  tag, `space-<root>-<tag>.json`, and its chart in `space-a.svg` / `space-b.svg`. A fingerprint mismatch (a settings change, a mode change, a
  disk plugged in or removed) rebuilds the search-folder index automatically
  and marks a disk index out of date.
- Several disks share one index, not one each: a rebuild walks every mounted
  volume in a single pass, unplugging one still leaves the rest openable.
- Volume metadata from other operating systems is pruned at every root
  (`lost+found`, `$RECYCLE.BIN`, `System Volume Information`, `.Trash-*`,
  macOS Spotlight/Time Machine/AppleDouble leftovers, and similar), since it
  is never a user file and can otherwise add tens of thousands of records.
- `find` is bound by metadata latency, so a spinning USB drive with a
  million files can run for minutes — hence indexed on command only. A walk
  covering disks gets 30 minutes against 3 for the search folder; the panel
  stays usable throughout.
- Both the index and its fingerprint are written to temp files and renamed
  into place, so a rebuild never writes through a symlink at the cache path.
- Names containing a newline are excluded from the index, and every record
  is validated against the roots it claims to come from before being opened.
- Excluded entries match by folder/file name (`find -name`), not by path;
  entries containing `/` are skipped and logged. Unreadable subtrees are
  silently skipped.

## License

MIT.
