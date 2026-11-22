# Upstream

`backend/` is a copy of the Python helper from
[omarchy-mxcontrol](https://github.com/zachwilke/omarchy-mxcontrol) by **Zach Wilke**,
which drives Logitech HID++ devices through Solaar's libraries. The hard part of this
plugin is that helper, and it is his. One local change is listed below.

| | |
|---|---|
| Upstream | https://github.com/zachwilke/omarchy-mxcontrol |
| Copied at | `0968d77`, 2026-09-08 (v1.6.0) |
| Licence | GPL-2.0-or-later, see `LICENSE` |
| Files | `mxctl.py`, `mxactions.py`, `mxpointer.py` |

SHA-256 of the copied files. `mxctl.py` differs from upstream by the local change below;
the other two are byte-identical:

```
978b149caaaf96435a8bdb3ff96d821abde5eb5a7fa6c63e4d7c548544774a91  backend/mxctl.py
6f14325f8710bb185adf19712d0acfb7dc2440ea58bbe8c793fcbdd02467a767  backend/mxactions.py
f22cb52bb21e399e40f13fd00f38f661252dd9759013d82b89e03277bfaa3157  backend/mxpointer.py
```

## What is new here

Everything outside `backend/`: the Noctalia service, bar widget and panel (`*.luau`),
the manifest and translations. The upstream QML/JS UI is not used.

## Local change in `mxctl.py`

`reapply_saved()` writes the saved Solaar settings back when a device resets (power
switch, battery swap). The Solaar app does this on device activation; `serve` did not, so
without the app running a mouse fell back to its default DPI. `serve` checks every
`RESET_CHECK_SEC` through the HID++ ConfigChange cookie, which a reset clears. Re-apply
this change when copying a newer upstream `mxctl.py`.

## Kept on purpose

- The helper still uses `$XDG_RUNTIME_DIR/omarchy-mx/` and `~/.config/omarchy-mx/`, so
  profiles and actions saved with the Omarchy plugin carry over.
- Commands reach the helper as spool files (`cmd-*.json`) that the service writes
  directly, instead of `mxctl.py write-cmd` on stdin, because Noctalia's `runAsync`
  cannot feed stdin. The file format is the one `write-cmd` produces.

## Updating

Copy the three files from a newer upstream commit, re-apply the local change, update the
table and hashes above,
then re-check the `status.json` shape and command ops against `shared.luau`.
