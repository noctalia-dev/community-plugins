# SSH Agent

Manage your SSH keys and saved sessions directly from the Noctalia bar. This plugin keeps a small SSH agent running in the background, lets you add or remove keys, and provides a panel for quick session management.

## Plugin

| Field | Value |
| --- | --- |
| ID | `martasskv5/ssh-agent` |
| Entries | Bar widget: `ssh-agent-widget`; panel: `ssh-agent-panel`; service: `ssh-agent-service` |

## Requirements

Install the following on `PATH` for the plugin to work correctly:

- `ssh`
- `ssh-agent`
- `ssh-add`
- `zenity`

For passphrase prompts, install one of these programs as well:

- `ksshaskpass`
- `ssh-askpass`
- `lxqt-openssh-askpass`

The plugin also uses `pkill`, `mkdir`, and the standard SSH agent socket pattern under `/tmp` to manage the agent lifecycle and temporary files.

To make SSH tools available outside the plugin process, set `SSH_AUTH_SOCK` in your shell or desktop environment. For example:

```sh
export SSH_AUTH_SOCK="/tmp/ssh-agent-$USER.sock"
```

For a compositor or window manager configuration, add the same value there as well so applications launched from the desktop environment can find the agent.

### Example Niri config

```kdl
environment {
    SSH_ASKPASS "/usr/bin/ksshaskpass"
    SSH_ASKPASS_REQUIRE "prefer"
    SSH_AUTH_SOCK "/tmp/ssh-agent-<replace with your username>.sock"
}
```

### Example Hyprland config

```conf
env = SSH_ASKPASS,/usr/bin/ksshaskpass
env = SSH_ASKPASS_REQUIRE,prefer
env = SSH_AUTH_SOCK,/tmp/ssh-agent-<replace with your username>.sock
```

## Usage

Add the `SSH Agent` widget under Settings → Bar.

To open the panel manually, run:

```sh
noctalia msg panel-toggle martasskv5/ssh-agent:ssh-agent-panel
```

The panel lets you add SSH keys, remove them, and manage saved SSH sessions. If no SSH agent is running yet, the plugin will start one automatically and connect to it using the configured socket.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `socket_path` | `string` | `""` | The path to the SSH agent socket. Leave empty to use the default per-user agent socket location. |
| `sessions_file` | `string` | `"~/.ssh/sessions.json"` | The path to the JSON file used to store saved SSH sessions. |
| `default_key_browse_path` | `string` | `"~/.ssh"` | The default folder shown when browsing for SSH private keys. |
| `terminal_command` | `string` | `""` | The terminal command used to launch SSH sessions. Leave empty to use the system default terminal. |
| `show_saved_sessions` | `boolean` | `true` | Whether saved SSH sessions are shown in the panel. |
| `show_notifications` | `boolean` | `true` | Whether the plugin shows success and failure notifications for SSH operations. |
| `auto_start_mode` | `string` | `"connect_existing"` | How the plugin decides whether to reuse an existing agent or start a new one. Supported values are `"connect_existing"`, `"ask_each_time"`, and `"create_new"`. |

## IPC

Refresh the plugin state and update the bar widget by sending the following IPC message:

```sh
noctalia msg plugin martasskv5/ssh-agent:ssh-agent-service all refresh
```

Stop the SSH agent and remove the socket by sending:

```sh
noctalia msg plugin martasskv5/ssh-agent:ssh-agent-service all stop-agent
```

Start a new SSH agent and connect to it by sending:

```sh
noctalia msg plugin martasskv5/ssh-agent:ssh-agent-service all start-agent
```

## Notes

The plugin creates and manages the SSH agent socket and stores saved connection data in a JSON file under the configured `sessions_file` path. It may spawn `ssh-agent`, `ssh-add`, and the configured askpass helper to prompt for passphrases or manage keys, and it writes temporary files in `/tmp` while creating and switching SSH agent sockets.

If your environment does not export `SSH_AUTH_SOCK`, applications outside the plugin may not see the agent even when it is running, so it is often helpful to set it in both the shell and the window manager or compositor config.