# Command Runner

Save and execute CLI commands silently in the background with a single click and one-time sudo password cache.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nocode-96/cmd-runner` |
| Entries | Bar widget: `cmd-runner`; panel: `panel`; service: `cmd-service` |

## Requirements

No special system requirements. Requires Noctalia v5.

## Usage

Add the `cmd-runner` widget to a bar. Left-click it to open the command panel, where you can:
- **Run**: Execute custom CLI commands silently in the background.
- **Add**: Create a new command with a custom name, CLI command line, and optional sudo password.
- **Edit**: Edit an existing command. The sudo password is kept hidden and is not pre-populated in plain text.
- **Delete**: Remove a saved command.
- **Log**: Click the logs button on a command to view stdout/stderr output.

Open the panel directly with:

```sh
noctalia msg panel-toggle nocode-96/cmd-runner:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_toast` | `bool` | `true` | Shows a toast notification when a command completes or fails. |
| `show_label` | `bool` | `true` | Displays 'Commands' next to the icon in the top bar. |

## Notes

Command Runner runs custom CLI command lines in the background. If a command requires sudo (root) privileges, the password is encrypted locally in `commands.json` (inside the plugin's data folder) using base64 and character-shifting. The password is never sent in the public UI state, preventing other plugins from harvesting it.

