# Pomodoro Timer

A Pomodoro timer plugin for Noctalia for productivity. Initially ported from the legacy v4 plugin [Pomodoro Timer](https://github.com/noctalia-dev/legacy-v4-plugins/tree/main/pomodoro).

## Features
- **Sessions**: Configurable sessions based on the standard format (work - short break - long break). Durations can be configured in the settings.
- **Cycles**: Configurable number of (work - short break) cycles before a long break.
- **Auto-start**: Optionally auto-start breaks and/or work sessions.
- **Bar Widget**: Shows status and remaining time on the bar widget when the panel is closed.
- **Notifications**: Toast notification when work/break finishes.

## TODO 
- Sound notification (currently the toast is shown silently)
- IPC

## Plugin

| Field | Value |
| --- | --- |
| ID | `thepunkoff/pomodoro` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `pomodoro` |

## Usage
1. Enable plugin in settings
2. Add bar widget `Pomodoro Timer`
3. Widget appears on the bar, clicking it will toggle the panel.

To open the panel with a command:
```sh
noctalia msg panel-toggle thepunkoff/pomodoro:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `work-duration` | `int` | `25` | Duration of each work session in minutes. |
| `short-break-duration` | `int` | `5` | Duration of short breaks in minutes. |
| `long-break-duration` | `int` | `15` | Duration of long breaks in minutes. |
| `sessions-before-long-break` | `int` | `4` | Number of sessions before a long break (min=1). |
| `auto-start-work` | `bool` | `false` | Automatically start the work timer after a break. |
| `auto-start-breaks` | `bool` | `false` | Automatically start the break timer after a work session. |

## IPC
```sh
noctalia msg panel-toggle thepunkoff/pomodoro:panel
```

## Licensing

This project is licensed under the MIT License.

It bundles the JetBrains Mono font, which is licensed separately under the SIL Open Font License 1.1 (OFL-1.1). See `THIRD_PARTY_LICENCES/OFL.txt` for the full license text.
