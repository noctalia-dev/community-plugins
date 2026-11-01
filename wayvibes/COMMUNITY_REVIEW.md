# Community plugin review

Checked against the [community plugin guidelines](https://github.com/noctalia-dev/community-plugins/blob/main/README.md), [README template](https://github.com/noctalia-dev/community-plugins/blob/main/README_TEMPLATE.md), [submission template](https://github.com/noctalia-dev/community-plugins/blob/main/.github/PULL_REQUEST_TEMPLATE.md), and [Noctalia API declarations](https://github.com/noctalia-dev/official-plugins/blob/main/noctalia.d.luau) on 2026-11-01.

## Reviewer fixes

- The service reads environment variables through `noctalia.getenv`; it does not use Luau's unavailable `os.getenv`.
- Keyboard discovery reads Linux device metadata. Selection writes the upstream configuration directly. Neither `--list-devices` nor `--write-file` is invoked.
- Current `input_device` records support `NAME:` and `PATH:` under `XDG_CONFIG_HOME`, with the standard HOME fallback. Legacy configurations migrate without deleting the original after a failed write.
- Device discovery uses the upstream `KEY_A` check. Duplicate keyboard names and synthetic by-id display labels are saved as paths so upstream resolves the selected keyboard correctly.
- Panel and widget initialization reads the current shared state before rendering. Noctalia state watchers only deliver subsequent changes, so opening these surfaces after the service starts must not reset the visible pack, volume, device, or playback status.

Upstream interfaces were checked against [device.cpp](https://github.com/sahaj-b/wayvibes/blob/main/src/device.cpp) and [main.cpp](https://github.com/sahaj-b/wayvibes/blob/main/src/main.cpp).

## Packaging and code checks

- Submit these plugin files under exactly `wayvibes/` in the community repository; the standalone development repository itself is the plugin directory.
- Canonical id is `viksit-garg/wayvibes`. Entry ids are `wayvibes`, `panel`, and `daemon`.
- Version is bumped to `1.0.1`; API level remains `43`.
- Required manifest, README, English translations, and 960×540 WebP thumbnail are present. Tags, description length, entry paths, settings, and manifest translation keys pass the community validator.
- All plugin UI uses Noctalia's Luau API. There are no QML files, alternate UI runtimes, bundled audio packs, or remote-code downloads.
- Every command spawned by the plugin is declared in `dependencies` and documented in README Requirements: `wayvibes`, `pkill`, `pgrep`, and `sleep`.
- Only English translations are shipped; existing non-English translations are not edited or generated.
- `catalog.toml` is not included or edited. The plugin is below the 200-file limit.

## Side effects for the PR description

- Network calls: none from the plugin.
- Filesystem reads: soundpack directories and their `config.json` files; `/proc/bus/input/devices`; `/dev/input/by-id`; WayVibes device configuration; plugin playback state.
- Filesystem writes: create the WayVibes configuration directory if needed; write `input_device` on selection or migration; remove a successfully migrated legacy device file; write `state.json` under the host-provided plugin data directory.
- Processes: launch the configured WayVibes binary with a soundpack, volume, and background flag; stop or restart same-user `wayvibes` processes through `pkill`; check startup with `sleep` and `pgrep`. String commands run through the host's `/bin/sh -c` interface.
- Hardware: the external daemon reads the selected keyboard through libevdev and plays audio. The plugin itself only reads device metadata. Input-device permissions must already be configured by the user.

## Verification

- Current community `validate-plugins.py`, run against a temporary source layout containing only `wayvibes/`.
- `noctalia plugins lint /home/viksit/wayvibes` on installed Noctalia v5.2.1.
- `python3 tests/run.py --luau /path/to/luau`: service startup, command registration, discovery, XDG/HOME configuration, current and legacy records, migration failures, device selection, duplicate names, and failed writes.
- The tests reproduce the committed revision's `attempt to call a nil value` at service line 58, confirming the startup regression is covered.
- Fresh CachyOS base container: install dependencies through pacman, compile upstream WayVibes as a new unprivileged user, run its real `--help`, lint with Noctalia v5.4.1, and run the Luau regression suite. The suite has 15 service tests and 2 UI tests. `tests/cachyos.Dockerfile` reproduces the build without a preinstalled host Luau executable.
- Fresh-install instructions in `CACHYOS.md` cover the minimum Noctalia v5.4.0/API 43 requirement, standalone plugin installation, soundpacks, input-group login, and desktop playback checks. The installed host's v5.2.1 settings linter alone is not evidence of API 43 runtime compatibility.

These are automated checks with host fixtures, not a live compositor or audio playback test.

## Required evidence before marking a PR ready

- [ ] Exercise the bar widget, both panel tabs, selection, playback, volume, stop, and auto-start in a running Noctalia session. Record the actual compositor, Noctalia version, and API level in the PR template.
- [ ] Attach a screenshot or video of the running plugin. The existing thumbnail is a title card; it does not show the panel. Confirm that it was produced with the required thumbnail generator, or export a replacement with that generator.
- [ ] Confirm the right to publish under MIT and the existing `Copyright (c) 2026 Mohammed Shareef` attribution in LICENSE. Git history and manifest identify VIKSIT-GARG, but they do not establish the provenance of the copyright notice. Preserve it until provenance is established.

Keep the PR as a draft until the applicable submission attestations are true. The checks above do not imply maintainer approval.
