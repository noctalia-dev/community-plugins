# archup

Noctalia desktop widget that shows pending Arch Linux repo and AUR updates in a compact single-column card.

![Widget](assets/widget.png)

![Desktop](assets/desktop.png)

## Plugin

| Field | Value |
| --- | --- |
| ID | `7sarus/archup` |
| Entries | Desktop widget: `updates-desktop` |

## Requirements

- Noctalia v5 (plugin API 43)
- `pacman-contrib` for `checkupdates`
- `yay` for AUR queries

Install `pacman-contrib` from the official Arch repositories:

```sh
sudo pacman -S pacman-contrib
```

Install `yay` from the AUR if not already installed:

```sh
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si
```

## Usage

Add `7sarus/archup:updates-desktop` to your desktop from the Noctalia desktop widget picker.

Click the refresh button on the widget to check for updates, or send an IPC message:

```sh
noctalia msg plugin 7sarus/archup:updates-desktop all refresh
```

## Behavior

- `checkupdates` syncs against a temporary database to check repo updates without root access.
- `yay -Qua` checks AUR updates.
- The list shows up to 10 pending packages, allocating slots between repo and AUR updates.
- The subtitle shows the time of the last check and the last transaction timestamp from `/var/log/pacman.log`.
- Runtime state saves to `~/.local/state/noctalia/plugins/data/7sarus/archup/state.json`.

## License

MIT
