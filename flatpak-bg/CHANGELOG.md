# Changelog

## 0.4.0

- Removed the `/bg` launcher provider.
- Windows are tracked from `niri msg -j event-stream` instead of polling
  `niri msg -j windows`, so the list follows window changes immediately.
  Title and focus changes are ignored without decoding.
- Running instances are read from `$XDG_RUNTIME_DIR/.flatpak/` instead of
  running `flatpak ps`, so a refresh tick starts no process.
- If the event stream ends, the service polls niri and restarts the stream.
- Failed desktop file and icon lookups are retried every 30 seconds instead
  of on every scan.
- The panel now shrinks and grows with the list while it is open. The list
  only uses a scroll container when it has more than 8 apps, since a
  `flexGrow` scroll kept the content-sized panel at its tallest height.

## 0.3.0

- Stopping now sends SIGTERM first and only uses `flatpak kill` after a
  configurable timeout, so apps can save their state.
- Stopping is handled by the service, so the panel's "Stopping…" state can no longer get stuck.
- X11 windows (xwayland-satellite) are matched by `StartupWMClass` and the
  app id's last part, so these apps are no longer listed as background apps.
- Desktop files are found in `$XDG_DATA_HOME` and in every installation
  `flatpak --installations` reports, and `~` is expanded.
- A failed `flatpak ps` or `niri msg` no longer clears the list or leaves it
  stale without notice: the widget and panel show a scan error.
- Freshly started apps get 5 seconds to open a window before they are listed.
- Changing the icon setting updates the bar widget right away.
- Missing names and icons are retried instead of being cached forever.
- Window pid lookups are cached between scans.

## 0.2.0

- Initial version.
