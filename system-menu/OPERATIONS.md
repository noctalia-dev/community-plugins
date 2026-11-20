# Operations and privacy

## Application launchers

- **Direct:** starts the configured program and arguments.
- **Terminal:** wraps the program in the configured terminal and its arguments.
- **Desktop entry:** `python3 desktop-launch.py` starts `gtk-launch ID.desktop`
  in a separate session with `/dev/null` streams, then reports launch errors.
  The desktop entry controls Exec, Terminal and D-Bus activation.

Launches use argument arrays. The optional `quoted` terminal format passes a
POSIX-quoted child command as one argument. Executables are checked on Noctalia's
PATH; `~/` is expanded in executable paths. Runtime errors in detached applications
are handled by those applications.

## About

Opening or refreshing About runs `python3 collect.py`, which invokes `fastfetch`,
`lsblk` and `noctalia --version`, and reads local OS, proc and sysfs data. Logo
lookup reads OS-release and installed icon files. The widget version comes from
`plugin.toml`. Copy Information writes the system report to the clipboard.

The plugin makes no network requests or persistent file writes. Applications
chosen by the user have their own behavior and permissions.
