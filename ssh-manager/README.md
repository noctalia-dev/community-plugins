# SSH Manager

View and edit `~/.ssh/config` hosts, manage keys, and control the SSH agent from Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/ssh-manager` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service` |

## Requirements

Install OpenSSH client tools on `PATH` (manifest dependency: `openssh`). Used tools include `ssh`, `ssh-keygen`, `ssh-add`, and `ssh-agent`.

## Usage

Add the **status** bar widget (`davemhammer/ssh-manager:status`). Click it to open the manager panel.

In the panel:

- Browse SSH config hosts and open an interactive session (`ssh host`)
- Copy host names or connection strings
- List keys under your SSH directory; generate, remove, or add keys to the agent

```sh
noctalia msg panel-toggle davemhammer/ssh-manager:manager
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `config_path` | `file` | `~/.ssh/config` | SSH config file to parse and edit. |
| `ssh_dir` | `folder` | `~/.ssh` | Directory scanned for keys. |
| `refresh_interval` | `int` | `5` | Seconds between status refreshes. |
| `notify_on_action` | `bool` | `true` | Notify after key/host actions. |
| `backup_on_write` | `bool` | `true` | Backup config before writing. |
| `default_key_type` | `select` | `ed25519` | Default type for key generation. |
| `rsa_bits` | `int` | `4096` | RSA size when type is `rsa`. |
| `show_counts` | `bool` (widget) | `true` | Show host/key counts on the bar. |

## IPC

```sh
noctalia msg panel-toggle davemhammer/ssh-manager:manager
noctalia msg plugin davemhammer/ssh-manager:service all refresh
```

## Notes

- Reads and may rewrite your SSH config; enable `backup_on_write` when editing hosts.
- Key generation and agent operations spawn OpenSSH CLI tools as your user.
- Does not transmit host keys or private key material over the network by itself; `ssh` sessions use your normal OpenSSH configuration.
