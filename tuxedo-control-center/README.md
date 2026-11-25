# TUXEDO Control Center

Switch every TUXEDO Control Center (TCC) power profile from Noctalia. The
plugin adds a compact bar entry that opens a dynamically sized selector, with
the active TCC profile highlighted.

It complements Noctalia's built-in Power Profiles Daemon controls instead of
replacing them: use the built-in control for the standard power-saver,
balanced, and performance policies, and this plugin for TCC-specific profiles.

> [!NOTE]
> If you prefer using Noctalia's built-in power profile switcher with TUXEDO Control Center, you can install my lightweight C adapter: https://github.com/detluck/tuxedo-power-profiles-adapter. It implements the standard power-profiles-daemon D-Bus interface and lets you map the three standard modes (power-saver, balanced, performance) directly to three custom TUXEDO profiles.

## Plugin

| Field | Value |
| --- | --- |
| ID | `detluck/tuxedo-control-center` |
| Entries | Bar widget: `bar`; panel: `profiles`; service: `service` |

## Requirements

- `busctl` must be available on `PATH`.
- TUXEDO Control Center's `tccd` service must be installed and running.
- The signed-in user must be allowed to read and change TCC profiles on the
  system D-Bus.

## Usage

Enable **TUXEDO Control Center** in Noctalia's plugin settings, then add the
`detluck/tuxedo-control-center:bar` widget to a bar. Click its CPU icon to open
the profile selector and click a profile to activate it.

You can also open or close the panel directly:

```sh
noctalia msg panel-toggle detluck/tuxedo-control-center:profiles
```

The panel grows with the number of profiles and becomes scrollable when the
list reaches its maximum height.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_default_profiles` | `bool` | `true` | Show TCC's built-in profiles. Disable it to hide the stock legacy profiles, including TUXEDO Defaults, and show only custom profiles. |

## Notes

The plugin calls TCC's `GetProfilesJSON`, `GetActiveProfileJSON`, and
`SetTempProfileById` D-Bus methods through `busctl`. It runs no network calls
and writes no files.

TCC does not publish a profile-change signal, so the service refreshes the
active profile every two seconds. A profile application can take several
seconds; the plugin keeps the last known active selection during a transient
read delay.
