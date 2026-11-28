# Wallpaper Carousel

A full-screen, animated carousel of the wallpapers in a folder. Preview thumbnails
are generated once and cached, the focused card is enlarged, the cards fade out
towards the edges, and the whole strip scrolls with the keyboard, the wheel or a
click. The same plugin also renders as a vertical column that uses the screen
height.

Deleting a card moves the file to the XDG trash, so a mistyped key is recoverable.

## Plugin

| Field | Value |
| --- | --- |
| ID | `type3demo/wallpaper-carousel` |
| Entries | Layer: `carousel`; panel: `keys`; control-center shortcut: `toggle` |

## Requirements

- `ffmpeg` for thumbnail generation. If ImageMagick is installed instead, its
  `magick` or `convert` binary is used and `ffmpeg` is not needed.
- `gio` (GLib) to move a deleted wallpaper to the trash. Without it the file is
  renamed to `<name>.trashed` next to the original instead of being deleted, and
  an already parked copy is never overwritten: `mv -n` claims the new name with a
  no-replace rename, and the next free `<name>.trashed.N` is used if the name is
  taken.
- `realpath` and `mv` (coreutils) run on a delete. The wallpaper and the folder
  are resolved with NUL-delimited output before anything is moved, because a
  subfolder of the scan can be a symlink pointing elsewhere: a wallpaper whose
  real path leaves the configured folder is listed but not deletable, and the
  move acts on the resolved path, so a link retargeted after the check cannot
  redirect it.

## Usage

The plugin renders through a layer surface, driven by an invisible panel that
holds the keyboard while the carousel is open. Toggle it with:

```sh
noctalia msg panel-toggle type3demo/wallpaper-carousel:keys
```

The control-center shortcut `toggle` does the same from the shortcut tiles. Bind
the command above to a compositor shortcut for quick access.

While the carousel is open:

| Key | Action |
| --- | --- |
| `Left` / `Up` | move one card back |
| `Right` / `Down` | move one card forward |
| `Return` | apply the focused wallpaper |
| `Space` | apply a random wallpaper |
| `Alt+D` | move the focused wallpaper to the trash |
| `Escape` | close the carousel |

Clicking a card applies it when it is the focused card and scrolls to it
otherwise. The mouse wheel scrolls the strip. The folder is rescanned every time
the carousel opens.

The panel placement (`position` in Noctalia's plugin settings) decides where the
layer is anchored, and the carousel animates in from the nearest screen edge and
out again when it closes.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `wallpaper_dir` | `folder` | empty | Folder to scan, up to three levels deep. Empty uses Noctalia's own wallpaper directory. |
| `orientation` | `select` | `horizontal` | `horizontal` is a row of cards; `vertical` is a column that uses the full output height. |
| `animation_ms` | `int` | `320` | Slide duration of the carousel in milliseconds, 120 to 1200. |
| `close_on_apply` | `bool` | `false` | Close the carousel after a wallpaper is applied. |
| `notify_on_change` | `bool` | `true` | Show a desktop notification when the wallpaper changes. |

## IPC

The panel entry accepts the same actions the keyboard emits, so the carousel can
be driven from a script:

```sh
noctalia msg plugin type3demo/wallpaper-carousel:keys all prev
noctalia msg plugin type3demo/wallpaper-carousel:keys all next
noctalia msg plugin type3demo/wallpaper-carousel:keys all apply
noctalia msg plugin type3demo/wallpaper-carousel:keys all random
noctalia msg plugin type3demo/wallpaper-carousel:keys all delete
noctalia msg plugin type3demo/wallpaper-carousel:keys all toggle
```

Panel entries are created lazily, so these events only answer once the panel has
been opened at least once since Noctalia started.

## Notes

- **Processes spawned**: `ffmpeg` (or `magick`/`convert`) once per wallpaper that
  has no cached preview yet, with the output written to the plugin data
  directory; `realpath -z -e -- <wallpaper> <folder>` and `gio trash -- <path>`
  when a wallpaper is deleted, or `mv -n -- <path> <path>.trashed` when `gio` is
  not installed.
- **Files written**: JPEG previews (640×360) in the plugin data directory, and
  the file system's trash directory when a wallpaper is deleted. Preview files of
  deleted wallpapers are removed with them.
- **Files read**: the configured wallpaper folder, and the wallpaper path of each
  output from the Noctalia API.
- No network access.
- The layer surface is click-through only when hidden; while the carousel is open
  it covers the anchored strip on one output.
