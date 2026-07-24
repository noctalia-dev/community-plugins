# Locate Files

A Noctalia v5 launcher provider that maintains a private index of the user's
home directory, searches it with `plocate`, falls back to `fzf` for typos, and
opens results with `xdg-open`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `yihao/locate-files` |
| Entries | Launcher provider: `files`; service: `indexer` |
| Launcher prefix | `/f` |

## Requirements

- Noctalia 5.0.0 or newer
- `locate` and `updatedb` from `plocate`
- `fzf`
- `flock` from `util-linux`
- `xdg-open`

The plugin creates and refreshes its own database; it does not use the system
database under `/var/lib/plocate/`.

## Usage

1. Enable `yihao/locate-files` in **Settings > Plugins**.
2. Open the launcher and type `/f` followed by part of a path or file name.
3. Select a result to open it in its default application.

Dot-paths are hidden by default. Add search options after a `--` separator:

```text
/f invoice -- --hidden
/f project -- --type file
/f cache -- --type directory
/f config -- --hidden --type=directory
/f invioce -- --fuzzy
```

Supported options are `-h`/`--hidden`, `--fuzzy`, and
`-t`/`--type file|directory`. Type aliases `f`, `d`, and `dir` are accepted.

Use the launcher action below to rebuild the index immediately:

```text
/f --reindex
```

Searches run asynchronously with a 250 ms debounce and return at most 50 paths
by default. Stale responses are discarded by Noctalia when the query changes.
Change the result limit from the plugin settings in **Settings > Plugins**.

Substring search through `plocate` remains the default. Fuzzy search runs after
an exact query has no usable results, can be selected as the default backend, or
can be disabled except for `--fuzzy`. Fuzzy search needs at least three
characters and uses a bounded 150-candidate `fzf` result set by default. The
launcher scores those candidates with filename-first Noctalia fuzzy scores, a
small `fzf` rank bonus, optional file/directory weights, and a global-search
bias. It does not attempt to read an internal `fzf` score.

The provider is disabled from unprefixed global search by default. Enable it in
Noctalia's launcher-provider configuration if desired; the **Global search score
bias** setting keeps weak file matches below applications. Advanced plugin
settings also expose the fuzzy candidate limit and file/directory score weights.

The same settings page provides **Pruned paths**, **Pruned directory names**, and
an **Index refresh interval**. Pruned paths are omitted when the database is
built, so changing them triggers a rebuild. Relative prune paths are resolved
from the home directory; home-relative paths such as `~/Downloads` are also
supported.

Pruned directory names apply at every depth and are literal, not regex or glob
patterns. Add `node_modules`, `.git`, or `__pycache__` to omit every matching
directory's contents. Names containing slashes or spaces are ignored; use
**Pruned paths** for a specific directory such as `Projects/example/bin`.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Maximum results | `50` | Maximum launcher rows returned per query. |
| Pruned paths | `[]` | Home-relative or absolute directories excluded during indexing. |
| Pruned directory names | `[]` | Literal directory names excluded at every depth. |
| Index refresh interval | `60` minutes | Time between automatic index refreshes, from 1 minute to 7 days. |
| Fuzzy search | `fallback` | Fallback after no exact result, always fuzzy, or only `--fuzzy`. |
| Fuzzy candidate limit | `150` | Advanced: fzf candidates scored by the launcher, from 100 to 200. |
| Global search score bias | `-100` | Advanced: score adjustment when global launcher search is enabled. |
| File and directory score weights | `0` | Advanced: type-specific ranking adjustments. |

## Private Index

The `indexer` service builds the database automatically when it is missing and
refreshes it every 60 minutes by default. The frequency is configurable from the
plugin settings between 1 and 10080 minutes (7 days).

## IPC

Rebuild the private index immediately:

```sh
noctalia msg plugin yihao/locate-files:indexer all reindex
```

The database, NUL-delimited `paths.cache`, lock, log, status, and metadata files
live under the directory returned by `noctalia.pluginDataDir()`. Index builds use
`umask 077`, enforce mode `0600` on both search artifacts, run detached, and are
serialized with `flock`. The cache is exported from the staged private database
and atomically replaced after every successful build. A previous generation
remains usable during routine refreshes. Searches pause during a
prune-configuration rebuild so removed paths are not served from an old index.

## Implementation

- `plugin.toml` declares the launcher, index service, dependencies, and settings.
- `indexer.luau` schedules builds and shares index status with the launcher.
- `update-index.sh` stages `updatedb` output and exports `paths.cache` outside
  Noctalia's callback timeout.
- `launcher.luau` runs the private `locate` database by default, then uses
  `fzf --read0 --print0 --scheme=path --filter` on `paths.cache` when selected.
  It applies query options, ranks bounded candidates, and publishes launcher rows.
- Selecting a row opens its safely shell-quoted absolute path with `xdg-open`.
- `translations/en.json` supplies the settings and launcher text required by
  the v5 manifest API.
