# DNF Updater

DNF Updater monitors and manages pending DNF5 and Flatpak updates directly from the Noctalia bar. It provides a lightweight update badge in the bar, per-package selection to skip or apply specific upgrades, download size estimation, and safe execution through Polkit (`pkexec`) or an interactive terminal.

## Plugin

| Field | Value |
| --- | --- |
| ID | `strob3/dnf-updater` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements

The plugin expects the following dependencies on `$PATH`:

- `dnf5` - required for DNF, COPR, and RPM package management. Fedora 41+ uses DNF5 by default.
- `flatpak` - optional, Flatpak application manager
- `pkexec` - (Polkit authentication for non-interactive privileged package installation)

### Passwordless Background Upgrades (Optional)

To enable seamless background upgrades without a password prompt (matching Flatpak's default behavior for `wheel` users), install the included Polkit rule:

```sh
sudo install -Dm644 polkit/50-dnf-updater.rules /etc/polkit-1/rules.d/50-dnf-updater.rules
```

To remove it later:

```sh
sudo rm /etc/polkit-1/rules.d/50-dnf-updater.rules
```

## Usage

Add the DNF Updater widget to the bar using Noctalia's bar widget picker. Left-click the widget to open the updates panel. You can also toggle the panel or bind it to a compositor shortcut:

```sh
noctalia msg panel-toggle strob3/dnf-updater:panel
```

### Shortcuts & Keybindings

You can also toggle the panel with a hotkey or shell alias:

**Niri** (`~/.config/niri/config.kdl`):
```kdl
binds {
    Mod+U { spawn "noctalia" "msg" "panel-toggle" "strob3/dnf-updater:panel"; }
}
```

**Hyprland** (`hyprland.conf`):
```conf
bind = $mainMod, U, exec, noctalia msg panel-toggle strob3/dnf-updater:panel
```

**Shell Alias** (`~/.bashrc` or `~/.zshrc`):
```sh
alias dnf-updater="noctalia msg panel-toggle strob3/dnf-updater:panel"
alias dnf-check="noctalia msg plugin strob3/dnf-updater:service service check"
```

### Controls

| Action | Target | Description |
| --- | --- | --- |
| **Left Click** | Bar Widget | Open or close the updates panel |
| **Right Click** | Bar Widget | Refresh the updates |
| **Middle Click** | Bar Widget | Open plugin settings in *Settings → Plugins* |
| **Click Row** | Package Row | Toggle package selection (include or exclude from update) |
| **Chevron Click** | Section Header | Collapse or expand DNF or Flatpak package section |
| **Check Click** | Section Header | Select all or deselect all packages in section |
| **Update Button** | Panel Bottom | Apply updates for all selected packages |
| **Check Now** | Panel Bottom | Re-check repositories for latest updates |

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `check_interval` | `int` | `30` | Interval in minutes between automatic checks (`0` disables scheduled checks). |
| `enable_dnf` | `bool` | `true` | Enable checking and upgrading DNF5 system packages. |
| `enable_flatpak` | `bool` | `true` | Enable checking and upgrading Flatpak applications. |
| `show_widget_when_clean` | `bool` | `true` | Show the widget icon in the bar even when system is up to date. |
| `notify_on_updates` | `bool` | `true` | Send a desktop notification when new pending updates are found. |
| `update_in_terminal` | `bool` | `true` | Launch update commands inside your terminal emulator instead of background Polkit execution. |
| `glyph` | `glyph` | `package` | Widget icon glyph displayed in the bar. |

## IPC

Trigger background service operations using `noctalia msg`:

```sh
# Check for updates immediately
noctalia msg plugin strob3/dnf-updater:service service check

# Apply updates for all pending packages
noctalia msg plugin strob3/dnf-updater:service service update
```

## Notes

- **Privilege Separation**: Noctalia never runs as root. System upgrades invoke `pkexec dnf5 upgrade` with explicit arguments, or launch inside the user's terminal emulator when configured.
- **Selective Upgrades**: When packages are deselected, DNF5 is invoked with `--exclude=<pkg>` arguments and Flatpak is invoked with only selected application IDs.
- **Background Checks**: Update queries use non-blocking JSON queries (`dnf5 check-upgrade --json` and `flatpak remote-ls --updates -j`) to prevent freezing the shell.

## License
MIT
