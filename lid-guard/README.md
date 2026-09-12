# Lid Guard

Lid Guard keeps a laptop awake when its lid is closed, allowing AI agents,
builds, downloads, and other background jobs to continue without changing the
system-wide lid policy.

## Plugin

| Field | Value |
| --- | --- |
| ID | `8bury/lid-guard` |
| Entries | Bar widget: `lid-guard`; shortcut: `lid-guard-toggle`; service: `lid-guard-service` |

## Requirements

One of these backends must be available:

- **Dinit:** `dinitctl`, `elogind-inhibit`, and `sleep`. The active user session
  must have a working user Dinit manager and `elogind`.
- **systemd:** `systemctl`, `systemd-run`, `systemd-inhibit`, and `sleep`. The
  active user session must use `systemd-logind` and have a working user service
  manager.

Dinit is preferred automatically when both backends are installed.

## Usage

Add the `lid-guard` widget to a bar. Left-click the shield to toggle the mode;
right-click it to refresh the detected state. A highlighted shield means the
lid-close inhibitor is active.

To use the same toggle from the Control Center, add the `lid-guard-toggle`
shortcut in Settings → Control Center → Shortcuts.

The service entry `lid-guard-service` owns the inhibitor and can also be
controlled through IPC:

```sh
noctalia msg plugin 8bury/lid-guard:lid-guard-service all enable
noctalia msg plugin 8bury/lid-guard:lid-guard-service all disable
noctalia msg plugin 8bury/lid-guard:lid-guard-service all toggle
noctalia msg plugin 8bury/lid-guard:lid-guard-service all refresh
```

## IPC

The `enable`, `disable`, and `toggle` events change the inhibitor state.
`refresh` and `status` re-check the transient user service without changing it.
IPC events take no payload.

## Dinit setup

For Dinit, install the included service description into the user service
 directory:

```sh
mkdir -p "$XDG_CONFIG_HOME/dinit.d"
cp dinit/noctalia-lid-guard "$XDG_CONFIG_HOME/dinit.d/"
```

When installed from the Noctalia plugin store, copy the file from the plugin's
local directory. The service is not enabled at boot; the plugin starts and
stops it on demand.

## Notes

Lid Guard makes no network requests. It starts the inhibitor as the current
user. With Dinit it controls the persistent user service
`noctalia-lid-guard`; with systemd it creates the transient user service
`noctalia-lid-guard.service`; disabling the mode stops the selected service.

The inhibitor covers only `handle-lid-switch`. It does not prevent suspension
requested by an idle daemon, a power menu, or another explicit command, and it
does not modify `logind.conf`. The mode ends when the user session or user
service manager stops. If Noctalia is unavailable, restore the normal lid
behavior with:

```sh
dinitctl --user stop noctalia-lid-guard  # Dinit
systemctl --user stop noctalia-lid-guard.service  # systemd
```
