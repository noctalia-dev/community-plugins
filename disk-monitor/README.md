# Disk Monitor

A bar widget and panel that monitors all connected disks and displays free space. The bar shows disk space at a glance, while the detailed panel provides usage bars, SSD detection, and disk selection.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rael2pac/disk-monitor` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `disk-poller` |

## Usage

The bar widget shows free space for each disk. Click it to open the panel with detailed usage information including capacity bars, mount points, and SSD/HDD detection.

```sh
noctalia msg panel-toggle rael2pac/disk-monitor:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refreshInterval` | `int` | `30` | Seconds between disk usage polls (min 10, max 300). |
| `displayFormat` | `string` | `name_free` | Bar display format: `name_free`, `percent`, or `size`. |
| `hideOnEmpty` | `bool` | `false` | Hide the bar widget when no disks are detected. |

## Notes

- Uses `lsblk` to detect all block devices and `df` for filesystem usage.
- Automatically detects SSD vs HDD using the `ROTA` flag.
- Supports ext4, btrfs, xfs, ntfs, and vfat filesystems.
