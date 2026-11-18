# Gocryptfs

Mount, unmount, initialize, and auto-mount [gocryptfs](https://github.com/rfjakob/gocryptfs) encrypted volumes from Noctalia — bar status, manager panel, and optional auto-mount after login.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/gocryptfs` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service` |

## Requirements

Install these on `PATH` (declared in `plugin.toml` `dependencies`):

- `gocryptfs` — mount and `gocryptfs -init`
- `fusermount3` or `fusermount` — FUSE unmount (first found wins)
- `keyctl` — kernel user-keyring session cache for remembered passwords (package `keyutils`)
- `secret-tool` — Freedesktop Secret Service client for reboot-persistent passwords (package `libsecret` / `libsecret-tools`)
- `chmod` — mode bits on short-lived temp password files
- `xdg-open` — open the mount point in the file manager
- `cat` — read `/proc/mounts` for mount status

**Desktop keyring:** persistent “Remember” needs a Secret Service backend (GNOME Keyring, KeePassXC as Secret Service, etc.) running and unlocked after login. If only `keyctl` is available, remember still works for the current login session.

## Usage

Add the **status** bar widget from Settings → Bar (`davemhammer/gocryptfs:status`).

- **Left-click** — open the manager panel
- **Right-click** — refresh mount status

In the panel you can:

- Select a volume → **Mount** / **Unmount** / **Open** (file manager via `xdg-open`)
- **Edit → Remember / Forget** — store or clear the volume password (desktop keyring + session cache)
- **Add** an existing cipher directory, or **Init** a new one (`gocryptfs -init`)
- Mount with a remembered keyring password, an optional advanced passfile path, or a one-shot password prompt (optional “also remember”)

```sh
noctalia msg panel-toggle davemhammer/gocryptfs:manager
```

### Auto-mount on login

Requires all of:

1. Plugin setting **Auto-mount on login** (default on)
2. Per-volume **Auto-mount** enabled
3. A remembered keyring password (**Remember**) or an advanced passfile path

After reboot, the desktop keyring must unlock (normal login) so `secret-tool` can supply the password. The kernel session key is refilled automatically on mount.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `3` | Seconds between `/proc/mounts` polls. |
| `notify_on_action` | `bool` | `true` | Notify after mount, unmount, init, remember, and forget. |
| `create_mountpoint` | `bool` | `true` | Create the mount directory if missing before mount. |
| `auto_mount` | `bool` | `true` | Global switch: on service start, queue volumes that have auto-mount + keyring/passfile. |
| `show_count` | `bool` (widget) | `true` | Show `mounted/total` on the bar. |
| `glyph_color` | `select` (widget) | `on_surface` | Lock icon color when nothing is mounted. |
| `mounted_color` | `select` (widget) | `tertiary` | Icon/dot color when at least one volume is mounted. |
| `unmounted_color` | `select` (widget) | `on_surface_variant` | Status-dot color when nothing is mounted. |

## IPC

```sh
noctalia msg panel-toggle davemhammer/gocryptfs:manager
noctalia msg plugin davemhammer/gocryptfs:service all refresh
noctalia msg plugin davemhammer/gocryptfs:service all reload
noctalia msg plugin davemhammer/gocryptfs:service all automount
```

- `refresh` — re-read `/proc/mounts` and refresh the snapshot
- `reload` — reload `volumes.json` from the plugin data dir, clear the auto-mount queue, then refresh
- `automount` — reset the auto-mount schedule and refresh (eligible volumes are queued again on the next status pass)

## Notes

### Data and filesystem

- Volume definitions live under the plugin data directory as `volumes.json` (not inside the cipher directory).
- With **Create mount points** on, the service may `mkdir` the configured mount path before mounting.
- Cipher, mount, and passfile paths reject empty values, NUL, and `..` segments. Symlinks on those paths are followed by design (user-chosen paths).

### Secrets (no long-lived plaintext under plugin data)

**Remember password** does **not** write a long-lived password file under the plugin data dir. It stores the secret in:

1. **Desktop keyring** via `secret-tool` — attributes `service=noctalia-gocryptfs`, `volume-id=<volume-id>`. Survives reboot while the login keyring is unlocked.
2. **Kernel session keyring** via `keyctl` — description `noctalia-gocryptfs:<volume-id>`. Fast cache for this login only; cleared on reboot/logout.

On mount / auto-mount, the service prefers the session key; if missing, it hydrates from `secret-tool` into `keyctl`, then runs `gocryptfs -extpass keyctl pipe <id>`. Fallback: `gocryptfs -extpass secret-tool lookup …`.

- One-shot typed passwords use a short-lived file under a **private** tmpfs dir (`/dev/shm/noctalia-gocryptfs.$USER`, mode `0700`) when available, then delete it. Parent mode blocks other local users even if the file briefly inherits umask.
- Optional **advanced** passfile paths remain supported for users who manage their own files (plaintext by user choice; not recommended).
- **Forget** and volume remove clear both the desktop keyring entry and the session key.
- Passwords are not logged.

### Processes and network

- Spawns: `gocryptfs`, `fusermount3` or `fusermount`, `keyctl`, `secret-tool`, `chmod`, `cat` (`/proc/mounts`), `xdg-open`.
- **Network:** none.
