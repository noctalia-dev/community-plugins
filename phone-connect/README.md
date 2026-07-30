<!-- 语言切换 · Language Switch -->
<p align="right">
  <a href="#chinese">中文</a> · <a href="#english">English</a>
</p>

---

<h1 id="chinese">📱 Phone Connect</h1>

[Noctalia](https://docs.noctalia.dev) v5 插件 —— 在桌面 bar 上控制你的手机。

## 功能

- **设备状态** — 电量百分比、充电状态、网络类型(5G/LTE/…)、配对状态
- **快捷操作** — 响铃找手机、Ping 通知、发送剪贴板、分享文字/文件/链接、短信、SFTP 浏览手机文件
- **媒体控制** — 播放/暂停/切歌/进度拖动、专辑封面、正在播放信息(MPRIS)
- **个性化** — 自定义设备头像和显示名称、三种面板弹出位置(贴合 bar / 悬浮居中 / 部件下方)
- **语言** — 英文 / 简体中文,设置中随时切换

## 环境要求

| 依赖 | 说明 |
|------|------|
| `kdeconnect` | KDE Connect 守护进程 + 命令行工具 |
| `gdbus` | glib2 自带,DBus 调用工具 |
| `sshfs` | 浏览手机文件所需 |
| 手机端 KDE Connect App | Android / iOS |

```bash
# Arch
sudo pacman -S kdeconnect sshfs

# Debian/Ubuntu
sudo apt install kdeconnect sshfs
```

## 安装

```bash
git clone https://github.com/CSY2569/phone-connect ~/noctalia-plugins/phone-connect
noctalia msg plugins source add phone-connect path ~/noctalia-plugins
noctalia msg config-reload
noctalia msg plugins enable icefish/phone-connect
```

然后在 Noctalia 设置中添加 bar 部件和控制中心磁贴。

## 设置项

| 设置 | 说明 |
|------|------|
| 状态刷新间隔 | 自动刷新设备状态的秒数 |
| 充电高亮 | 充电时 bar 部件变主题色 |
| 设备头像 | 为当前选中设备设置自定义图片 |
| 设备别名 | 自定义显示名称(默认:Your-Phone) |
| 界面语言 | English / 简体中文 |
| 面板弹出方式 | 贴合栏 / 悬浮居中 / 部件下方悬浮 |

## 使用技巧

- **左键点击** bar 部件 → 打开详情面板
- **右键点击** bar 部件 → 打开插件设置
- **选中设备后去设置** → 可自定义头像和别名

---

<h1 id="english">📱 Phone Connect</h1>

A [Noctalia](https://docs.noctalia.dev) v5 plugin for controlling your phone from the desktop bar.

## Features

- **Device status** — battery level, charging state, network type (5G/LTE/…), pairing status
- **Quick actions** — ring, ping, send clipboard, share text/files/URLs, SMS, SFTP file browser
- **Media control** — play/pause/skip/seek, album art, now-playing info (MPRIS)
- **Customization** — per-device image and alias, three panel placements (attached / floating / below-widget)
- **Language** — English / Simplified Chinese, switchable in settings

## Requirements

| Dependency | Notes |
|------------|-------|
| `kdeconnect` | KDE Connect daemon + CLI |
| `gdbus` | Ships with glib2 |
| `sshfs` | For phone file browsing |
| Phone KDE Connect App | Android / iOS |

```bash
# Arch
sudo pacman -S kdeconnect sshfs

# Debian/Ubuntu
sudo apt install kdeconnect sshfs
```

## Install

```bash
git clone https://github.com/CSY2569/phone-connect ~/noctalia-plugins/phone-connect
noctalia msg plugins source add phone-connect path ~/noctalia-plugins
noctalia msg config-reload
noctalia msg plugins enable icefish/phone-connect
```

Then add the bar widget and control-center tile from Settings.

## Settings

| Setting | Description |
|---------|-------------|
| State Update Interval | Seconds between device refreshes |
| Show Charging Fill | Highlight the bar widget when charging |
| Device Image | Custom image for the selected device |
| Device Alias | Custom display name (default: Your-Phone) |
| Language | English / 简体中文 |
| Panel Placement | Attached to bar / Floating center / Below widget |

## Tips

- **Left-click** bar widget → open details panel
- **Right-click** bar widget → open plugin settings
- **Select a device, then go to Settings** → customize its image and alias

---

<p align="center">MIT · <a href="https://github.com/CSY2569/phone-connect">GitHub</a></p>
