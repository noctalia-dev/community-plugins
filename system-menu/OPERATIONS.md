# Operations and privacy

## Package actions

| Action | Command |
| --- | --- |
| Repository install | `sudo pacman -S --needed -- repo/package ...` |
| AUR install | `HELPER -S --needed --aur -- package ...` |
| Remove | `sudo pacman -Rns -- package ...` |
| Update | `HELPER -Syu` |
| Downgrade | `sudo downgrade --cached-only --ignore=never ...` |

Mixed installs run repositories first, then AUR; failure stops the next command,
without rollback. Duplicate package names are rejected. Downgrade retains pacman
caches plus standard paru/yay caches, not archives or custom-helper cache discovery.
Only confirmed package actions use sudo. No services, system settings or scanner
configuration are installed or changed.

Alt+T runs `traur scan NAME --json` for AUR selections. It is a manual report,
not the makepkg wrapper or an installation gate. Existing helper/makepkg gates
are preserved, not detected or guaranteed. Traur is a heuristic, not a sandbox.

## Network and files

- AUR: `aur.archlinux.org/rpc/v5/` for name search, preview metadata and exact
  installed-source lookup (up to 100 names per request). Source fallback prefers
  recorded provenance, then local sync repositories (exact version first;
  repository priority breaks ties), then AUR. Offline/unmatched names stay unknown.
- Alt+B retrieves the current PKGBUILD from AUR cgit, as text only. It is never
  sourced or executed; it is not a claim about a cached/local build's exact recipe.
- Preview metadata/recipes and selector state are cached only in private temporary
  files under `XDG_RUNTIME_DIR` or Python's temporary directory, cleaned on exit.
- Explicit Traur reports and package operations use their tools' normal upstreams.
- VirusTotal receives a locally computed SHA-256 and API key for an existing-report
  GET (`www.virustotal.com/api/v3/files/`); files are never uploaded. Unknown/stale
  reports and zero detections are not safety guarantees. Optional keys are stored
  at `~/.config/package-menu/virustotal.key` with mode 0600, never in arguments.
- Fzf theme color declarations are read, never executed. Acknowledging an action
  clears that terminal's screen/scrollback. External tools retain their own logs.

Luau launches terminal/Python with argument arrays. Python invokes fzf, its own
callbacks, cat and the selected tools. About uses fastfetch, lsblk and Noctalia's
version plus curated proc/sysfs/OS-release data: no IP/MAC addresses, serials or
machine IDs. Copy includes hostname/hardware. Logo lookup reads OS-release as
data and resolves installed icons locally. No polling or About network requests.
The catalog thumbnail is artwork, not a live screenshot. Plugins are unsandboxed.
