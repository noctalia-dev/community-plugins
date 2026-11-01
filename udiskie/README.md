# Udiskie Manager

Manage USB drives and media with notifications in just one panel.

## Features

- Real-time device discovery and status monitoring via UDisks2 event streaming.
- Storage capacity and partition usage indicators with formatted bytes and percentage.
- Automatic detection and dedicated unlock action for LUKS encrypted volumes (`crypto_LUKS`).
- 管理面板按硬盘与分区分组，提供打开、挂载、卸载，以及根据设备能力选择操作的安全移除。
- Copy mount path to clipboard action.
- Configurable bar widget with mounted device counter and auto-hide when empty option.
- Native desktop notifications for drive connections, disconnections, mounts, unmounts, and errors.
- Quick refresh and native settings integration.

## Plugin

| Field   | Value                                                      |
| ------- | ---------------------------------------------------------- |
| ID      | `aristides/udiskie`                                        |
| Entries | Bar widget: `status`; panel: `manager`; service: `service` |

## Requirements

Install `udiskie`, `udisks2`, and `xdg-open` on `PATH`:

- `udiskie`: Device mount operations and device info queries.
- `udisks2`: Provides `udisksctl` for real-time DBus event streaming.
- `xdg-open`: Launcher binary for opening mounted folders in the file manager.

> **`udiskie-info -o` fields**: the service queries `udiskie-info -o` with the
> device attributes listed under `VALID_PARAMETERS` (e.g. `is_drive`,
> `is_partition`, `is_luks`, `mount_path`, `is_detachable`). If your `udiskie` is
> old enough to lack any of them, the device list will come back empty — upgrade
> `udiskie` in that case. A recent release (2.x) is recommended.

## Usage

- **Bar Widget (`status`)**: Add `status` to the bar configuration in Noctalia settings. Left-click to open the Udiskie Manager Panel. Right-click to trigger an immediate plugin refresh.
- **Panel (`manager`)**: Open via the bar widget or run:

```sh
noctalia msg panel-toggle aristides/udiskie:manager
```

### 卸载与安全移除

- 已挂载的分区显示 **Unmount / 卸载**，只卸载文件系统，保留设备连接。
- 支持弹出或断电的整盘显示 **Safely Remove / 安全移除**；不支持这两种操作时不显示该按钮。直接在整盘上建立文件系统的设备也使用相同规则。
- 安全移除会重新读取设备能力，先递归卸载子设备，成功后再执行 Eject；不支持 Eject、但支持 PowerOff 时执行断电。悬停提示显示所选操作。
- 任一卸载步骤失败时不执行弹出或断电。操作期间禁用插件内的设备变更按钮；超时后不自动重试，需先确认设备当前状态。
- 递归卸载使用 udiskie 的 `--force`，含义是处理子设备，不会强制或延迟卸载忙碌文件系统。该流程遵循 udiskie 的设备过滤配置，最终移除仍由 UDisks 检查权限及占用。
- 设备提供 `device_id` 时使用 `/dev/disk/by-id/` 路径，减少两阶段操作之间设备节点名称被复用的风险；未提供时使用查询时的设备路径。

## Settings

| Setting                 | Type     | Default      | Description                                                            |
| ----------------------- | -------- | ------------ | ---------------------------------------------------------------------- |
| `enable_notifications`  | `bool`   | `true`       | Show desktop notifications on drive events and errors.                 |
| `auto_open_filemanager` | `bool`   | `false`      | Automatically open mounted drives in the file manager upon connection. |
| `file_manager_cmd`      | `string` | `xdg-open`   | File manager launcher command.                                         |
| `glyph`                 | `glyph`  | `device-usb` | Icon glyph shown for the widget on the bar.                            |
| `show_count`            | `bool`   | `true`       | Display the count of mounted devices on the bar widget.                |
| `hide_when_empty`       | `bool`   | `false`      | Hide the bar widget when no USB drives are connected.                  |

## IPC

```sh
# Toggle panel
noctalia msg panel-toggle aristides/udiskie:manager

# Service actions
noctalia msg plugin aristides/udiskie:service all mount /dev/sdX
noctalia msg plugin aristides/udiskie:service all unmount /dev/sdX
noctalia msg plugin aristides/udiskie:service all safe_remove /dev/sdX
noctalia msg plugin aristides/udiskie:service all eject /dev/sdX
noctalia msg plugin aristides/udiskie:service all detach /dev/sdX
noctalia msg plugin aristides/udiskie:service all mount_all
noctalia msg plugin aristides/udiskie:service all unmount_all
noctalia msg plugin aristides/udiskie:service all refresh
```

`safe_remove` 接收整盘路径并自动选择支持的移除方式。旧的 `eject` 和 `detach` IPC 保留其明确的操作含义，但也先检查整盘能力、递归卸载；请求不支持的操作时直接报错。

## Performance

The plugin eliminates the standalone Python `udiskie` daemon by using an event-driven `udisksctl monitor` subprocess managed by Noctalia. Both approaches activate `udisksd` via D-Bus on first use.

| Component                            | RSS        | VSZ      | CPU  |
| ------------------------------------ | ---------- | -------- | ---- |
| `udisksctl monitor` (this plugin)    | ~12 MB     | ~170 MB  | 0.0% |
| `udiskie` Python daemon (standalone) | ~84–110 MB | ~1183 MB | 0.2% |
| `udisksd` (shared, D-Bus activated)  | ~22 MB     | ~688 MB  | 0.2% |

**Total footprint**: plugin ~34 MB vs standalone ~106–132 MB. **Saves ~72–98 MB RAM** and avoids a persistent Python process.

> Measurements are local to a given system/kernel and udiskie version; actual
> RSS/VSZ/CPU values vary by hardware and environment.

## Development

Run plugin validation and tests using the workspace Makefile:

```sh
make test
```

## Notes

- Requires plugin API level 9 or newer.
