iio-lock — Orientation Lock for 2‑in‑1 Devices

iio-lock is a small bar widget and panel plugin for Noctalia that provides manual control over screen orientation.
It works by stopping and restarting the iio-hyprland service (or similar IIO rotation tools), preventing automatic rotation while the lock is active.

This is useful on 2‑in‑1 touch laptops, where automatic rotation may not always be desired — such as when using the device in tablet mode, drawing, or note‑taking.

Supported WM and Tools
Hyprland / iio‑hyprland — Working and tested
Sway / iio‑sway — Unverified (experimental)

External commands
This plugin shells out to:
    -pgrep
    -pkill
    -iio-hyprland (or the user‑configured tool)
