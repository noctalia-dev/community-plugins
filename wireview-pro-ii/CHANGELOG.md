# Changelog

## 0.3.0 - 2026-08-24

- Add an immediate device-screen selector while keeping the persisted default screen separate.

## 0.2.0 - 2026-07-31

- Default the dashboard to an attached panel that opens near its bar widget.
- Distinguish urgent active alarms from lower-emphasis recorded history.
- Show session-observed fault timing without claiming device event timestamps.
- Show per-alarm clear progress, success, failure, and reassertion feedback.
- Freeze and dim stale telemetry with an explicit connection-loss banner.
- Add a configurable stacked Faults layout for constrained displays.
- Add editable electrical and thermal fault thresholds and compact device clear actions.

## 0.1.0 - 2026-07-30

- Initial live telemetry, conductor, graph, fault, and device-configuration dashboard.
- Direct Unix-socket communication with `wireviewd` through the bundled transport.
