# Phone Connect verification

## Automated checks

Run from the repository root:

```sh
python3 -m unittest discover -s phone-connect/tests -p 'test_*.py'
lua phone-connect/tests/messaging.lua phone-connect
lua phone-connect/tests/panel.lua phone-connect
lua phone-connect/tests/regressions.lua phone-connect service
lua phone-connect/tests/regressions.lua phone-connect panel
noctalia plugins lint phone-connect
python3 .github/workflows/scripts/validate-plugins.py
git diff --check
```

The suites use synthetic data and mocked process/D-Bus interfaces. They never
send SMS messages, dismiss notifications, or change phone settings.

| Suite | Coverage |
|-------|----------|
| `test_bridge.py` | Current and legacy typed message tuples, Unicode, attachments, pagination, thread replies, expired notifications, offline actions and sanitized errors. |
| `test_bridge.py` contacts | Folded vCards, quoted-printable soft lines, base64 names, legacy charsets, multiple numbers and device-scoped caches. Embedded photos cover raster validation, size limits, remote URI rejection, private runtime files, replacement/removal and fallback. |
| `test_bridge.py` transport | Large Unicode watch events reconstruct from bounded stream frames. Large one-shot request replies remain a single JSON object. |
| `messaging.lua` | Duplicate/out-of-order messages, loaded-message search, failed-send draft retention, duplicate sends, device changes, reconnection, subscription ordering and late notification snapshots. A 700-message signal burst publishes once per tick; pending sends publish immediately; incomplete frames are discarded. |
| `panel.lua` | Default-page options and fallback, collapsed/expanded contacts, number selection, inline device address, compact navigation and bounded history rendering. Large fixtures cover 1,000 contacts and 2,000 conversations, full-cache search, watched snapshot reuse and frame-coalesced updates. |
| `regressions.lua` | Existing device controls, media interactions, persistence and panel behavior. |

Dependency coverage forces the `gi` import to fail and checks the JSON package
guidance. Lua tests cover missing Python, a failed dependency probe, prompt
command failure with draft retention, successful recovery, the notice on all
three enhanced tabs, and Device actions while the helper is unavailable.

All 15 Python tests and the Lua suites pass. Repository validation passes for
299 manifests. Plugin lint reports no errors and one existing unused-setting
warning for `migrated_notice`.

## Completed native checks

Environment: Noctalia 5.4.0, KDE Connect 26.08.2, Hyprland and 1.333 display scale.

- All four tabs, the compact composer, wide/compact layouts and all three panel
  placements were inspected with synthetic preview data. The screenshots in
  `screenshots/` contain only sample content.
- A synthetic stress fixture with 302 contacts, 102 conversations and 102 loaded
  messages allowed repeated tab switching without callback timeouts.
- The live contact cache supplied 265 contacts with phone numbers and 32 embedded
  photos. Twenty quoted-printable names decoded without raw hex sequences in
  displayed names. Tab switching produced no image-load errors or timeouts.
- With 700 cached conversations and 13 active notifications, all three
  placements passed wide/compact checks: nine open/close cycles, 90 search
  changes and 36 tab changes, with no new callback timeouts. Conversation search
  and rendering used retained watch snapshots and bounded display pages.
- Removing only the local override symlink restored community version 0.2.1.
  Restoring the symlink loaded local 0.3.0. The settings file remained unchanged,
  and exactly one bridge watcher ran after restoration.
- Small-display checks used a separate Hyprland 0.56.2 compositor with a
  1366×768 headless output at 1.25× and 1.5×, a 38-logical-pixel bar, and Noctalia
  5.4.0. All three placements rendered all tabs and wide/compact Messages with
  synthetic data. The host clamped the 800×640 request to the smaller display;
  the composer, Send and Device action labels remained visible. These are
  native rendering checks, not physical-display or manual keyboard tests.
- Starting the isolated shell with `python3 -S` reproduced a missing PyGObject
  import without uninstalling packages. The panel displayed the dependency
  notice and package names, with an Open Device controls action.

## Live verification checklist

Contacts, conversation summaries and active notifications load from KDE Connect.
These display checks do not verify SMS delivery or notification actions. The
following checks remain unverified on the phone:

- [ ] Receive an SMS and verify that its conversation and preview update.
- [ ] Send an SMS to a designated test recipient and confirm it on the phone.
- [ ] Open a real conversation, load beyond the first 50 messages, and verify
  ordering, page boundaries and duplicates against the phone.
- [ ] Reply to an app notification that supplies a reply action; verify the reply.
- [ ] Dismiss a mirrored notification and confirm its removal on the phone.
- [ ] Disconnect/reconnect the phone with populated caches and verify recovery.
- [ ] Restart the KDE Connect daemon and verify that subscriptions recover.
- [ ] Observe incoming and missed-call events while the plugin is running.
- [ ] Check keyboard focus, scrolling and multiline composing in every placement
  at increased display and font scaling.

## Layout and preview checks

Open a panel and load the bundled synthetic fixture:

```sh
noctalia msg panel-open icefish/phone-connect:details
noctalia msg plugin icefish/phone-connect:details all preview "$(cat phone-connect/tests/preview.json)"
noctalia msg plugin icefish/phone-connect:details all view '{"tab":"notifications","compact":false}'
```

Repeat with `details_floating` and `details_widget`. The `view` event accepts
`tab` (`messages`, `notifications`, `contacts`, `device`), `compact` and `search`.
Preview blocks phone commands, uses separate view preferences, and ends when
the panel closes.

Check long names, multiple phone numbers, Unicode and multiline content, empty
lists and large lists. Navigation and the composer should stay visible while
lists scroll; action labels should stay readable. Switch layouts, tabs and
devices, then close/reopen the panel to verify selection and draft retention.
Use preview fixtures for screenshots to avoid including personal content.

See [DEVELOPMENT.md](DEVELOPMENT.md) for formatter checks and the implementation
invariants behind these tests.
