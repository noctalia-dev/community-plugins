# Arch Update

A bar widget and panel for managing system, AUR, and Flatpak updates on Arch Linux. Shows the number of available updates in the bar and provides a full update manager in the panel with batch update support.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rael2pac/arch-updater` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `updater`; launcher: `launcher` |
| Launcher Prefix | `/au` |

## Requirements

Install `checkupdates` (from `pacman-contrib`) and `yay` (AUR helper) on `PATH`.

Flatpak updates require `flatpak` to be installed and enabled in settings.

## Usage

The bar widget shows the count of available updates. Click it to open the panel with a detailed list of packages.

Use the launcher by typing `/au <query>` to search for available updates.

```sh
noctalia msg panel-toggle rael2pac/arch-updater:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refreshInterval` | `int` | `120` | Seconds between update checks (min 10, max 720). |
| `flatpakEnabled` | `bool` | `true` | Include Flatpak updates in the check. |
| `showToasts` | `bool` | `true` | Show desktop notifications when updates are found. |
| `noctaliaDetection` | `bool` | `true` | Detect and highlight Noctalia updates. |
| `cleanupAfterUpdate` | `bool` | `false` | Run `yay -Sc` after updating to clean the cache. |
| `hideOnEmpty` | `bool` | `false` | Hide the bar widget when no updates are available. |
| `boldText` | `bool` | `true` | Use bold text in the bar widget. |
| `noctaliaHighlight` | `bool` | `true` | Highlight Noctalia updates in the panel. |

## Notes

- Requires `sudo` access for system updates (`pacman -Syu`).
- The launcher provider searches through available updates matching your query.
