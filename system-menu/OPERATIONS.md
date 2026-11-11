# Operations and privacy

## Package actions

- Repositories: `sudo pacman -S --needed -- repo/package ...`.
- AUR: `HELPER -S --needed --aur -- package ...`, using the configured executable
  (`paru` by default; `yay` or another compatible helper can be selected).
- Remove: `sudo pacman -Rns -- package ...`; review dependency removals.
- Downgrade: `sudo downgrade --cached-only --ignore=never`, retaining configured
  system caches and adding existing paru/yay caches. No Arch Linux Archive
  fallback or automatic IgnorePkg edits. Old builds may break dependencies.
- Update: `HELPER -Syu`, not a partial database refresh.

Mixed installs run repositories first, then AUR. Failure stops subsequent
transactions but does not undo completed ones. Duplicate package names from
different sources are rejected. All package-manager confirmations remain.

Alt+T runs `traur scan NAME --json`. This is manual, not an automatic makepkg
gate. No wrapper or helper configuration is installed; existing gates are left
untouched. Remote Traur checks may fail to fetch/decode AUR metadata. Missing,
invalid or incomplete reports are not clean verdicts. Review PKGBUILDs yourself.

Installed sources prefer pacman's recorded `Installed From`. When missing, the
frontend checks local sync databases (exact installed version first, then current
availability; ties follow pacman's repository priority). Names absent from those
databases are checked in AUR with batched exact-name RPC info requests. These
fallback labels describe availability, not proven installation provenance; the
preview explains the basis. AUR is colored/grouped last also in installed lists.
`local/unknown` remains for unmatched names or unavailable lookups, never as an
automatic synonym for AUR. A lookup failure does not block remove/downgrade.

## Network

Name searches use `https://aur.archlinux.org/rpc/v5/`. Installed lists also send
names lacking recorded provenance and absent from configured repositories to
its exact-name info endpoint (batches of up to 100). Explicit Traur audits may
contact Traur's configured upstream services. Package managers use their normal
configured repositories and helper behavior, including downloads and AUR builds.

VirusTotal hashes files locally and retrieves existing reports from
`https://www.virustotal.com/api/v3/files/`; browser links use `/gui/file/`.
Only the digest and user-supplied API key are sent; files are never uploaded.
Reports can be stale, public API quotas apply, and unknown hashes, request failures
or zero detections do not mean a file is safe. No automatic package scanning occurs.

## Local files and processes

Private temporary catalog/status/preview-size files live under `XDG_RUNTIME_DIR`
or Python's temporary directory and are removed on normal selector exit.
Optional VT setup writes `~/.config/package-menu/virustotal.key` with mode 0600.
Existing fzf theme color declarations are read from
`~/.config/fzf/themes/noctalia.sh`, never sourced as shell code. External tools
retain their usual caches/logs. Acknowledging action results clears the terminal's
screen and scrollback, not redirected output or saved logs.

Luau launches the configured terminal/Python with direct argument arrays. Terminal
options and run-program arguments are separate lists, not shell commands. The
configured AUR helper is passed as one executable name/path and preserved in fzf
callbacks; failed commands never switch helpers. Custom helper caches are not
automatically discovered beyond the standard paru/yay cache paths above.
The frontend invokes fzf, its own search/preview/resize
helpers, cat and the tools for the chosen action. About invokes fastfetch, lsblk
and `noctalia --version`. Only confirmed package actions invoke sudo; the plugin
itself is not run as root. It creates no services, timers, repository settings,
scanner installation, or terminal/btop configuration.

The bar button, menu and About panel read `LOGO`, `ID` and `ID_LIKE` from
`/etc/os-release` (falling back to `/usr/lib/os-release`), resolve installed
icons through Noctalia's icon theme and standard system icon directories, and
use a generic icon when none matches. This uses no subprocesses or network;
os-release values are parsed as data, never evaluated as shell commands.

About reads curated fastfetch JSON, hostname, session environment, OS-release,
selected proc/sysfs fields and physical disk models/capacities. It does not collect
IP/MAC addresses, serial numbers, machine IDs or package inventories. Copy
Information includes hostname and hardware details: review before sharing.
About makes no network calls and does not poll resources.

The thumbnail uses the official Noctalia generator's artwork mode, not a user's
system screenshot. Plugins are trusted, unsandboxed code; inspect before enabling.
