# Gocryptfs

Mount, unmount, initialize, and auto-mount [gocryptfs](https://github.com/rfjakob/gocryptfs) encrypted volumes from Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/gocryptfs` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service` |

## Requirements

Install `gocryptfs` on `PATH`. A FUSE unmount helper (`fusermount3` or `fusermount`) is also required at runtime.

## Usage

Add the **status** bar widget from Settings → Bar (type `davemhammer/gocryptfs:status`). Click the widget to open the manager panel.

In the panel you can:

- Select a registered volume and **Mount** / **Unmount** / **Open** the mount point
- **Add** or **Edit** volume paths (cipher dir, mount point, optional passfile)
- **Init** a new cipher directory with `gocryptfs -init`
- Mount with a passfile or a one-shot password prompt

Open the panel from IPC:

```sh
noctalia msg panel-toggle davemhammer/gocryptfs:manager
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `3` | Seconds between mount-status polls. |
| `notify_on_action` | `bool` | `true` | Notify after mount/unmount/init. |
| `create_mountpoint` | `bool` | `true` | Create the mount directory if missing. |
| `auto_mount` | `bool` | `true` | On service start, mount volumes that have auto-mount + passfile. |
| `show_count` | `bool` (widget) | `true` | Show mounted/total on the bar. |

## IPC

```sh
noctalia msg panel-toggle davemhammer/gocryptfs:manager
noctalia msg plugin davemhammer/gocryptfs:service all refresh
noctalia msg plugin davemhammer/gocryptfs:service all automount
```

## Notes

- Volume definitions are stored under the plugin data directory (`volumes.json`), not in the vault or home path you encrypt.
- Optional passfiles live under the plugin data dir when “save passfile” is used during init.
- The service reads `/proc/mounts` and shells out to `gocryptfs` and `fusermount`/`fusermount3`.
- Passwords entered in the panel are written to a temporary passfile for the mount process, then removed.
