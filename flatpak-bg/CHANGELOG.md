# Changelog

## 1.1.0

- The icon is now a bar widget setting, so each bar widget can have its own.
  The panel header always uses the plugin icon.
- New bar widget settings **Always show** (off by default) to keep the icon
  in the bar while no app runs in the background, and **Show count** (on by
  default). The count is left out while it is 0.
- The tooltip lists the background apps with bullets.
- The panel's maximum height is 360px (was 480px); more than 5 apps scroll.
- Stopping an app that exits on its own just before the forced stop no longer
  reports a failure.
- While niri is unavailable, restarts of the event stream back off from 3 up
  to 60 seconds instead of retrying every 3 seconds.
- New setting **Ignored apps**: Flatpak app ids that are never listed or
  counted, for apps that are meant to run in the background.

## 1.0.0

- First release: a bar widget, a panel and a service that list Flatpak apps
  running without a window in niri and stop them (SIGTERM first, `flatpak kill`
  after a configurable timeout).
- IPC events `refresh`, `stop <app-id>` and `list` on the service.
