# Upstream

`backend/` is an unmodified copy of the Python helper from
[omarchy-mxcontrol](https://github.com/zachwilke/omarchy-mxcontrol) by **Zach Wilke**,
which drives Logitech HID++ devices through Solaar's libraries. The hard part of this
plugin is that helper, and it is his.

| | |
|---|---|
| Upstream | https://github.com/zachwilke/omarchy-mxcontrol |
| Copied at | `0968d77`, 2026-09-08 (v1.6.0) |
| Licence | GPL-2.0-or-later, see `LICENSE` |
| Files | `mxctl.py`, `mxactions.py`, `mxpointer.py` |

SHA-256 of the copied files, to check they are still byte-identical:

```
a7328ece21608055f3faa1d8404e8e9c786cb456dc8cb5ffe4e15712263fcca2  backend/mxctl.py
6f14325f8710bb185adf19712d0acfb7dc2440ea58bbe8c793fcbdd02467a767  backend/mxactions.py
f22cb52bb21e399e40f13fd00f38f661252dd9759013d82b89e03277bfaa3157  backend/mxpointer.py
```

## What is new here

Everything outside `backend/`: the Noctalia service, bar widget and panel (`*.luau`),
the manifest and translations. The upstream QML/JS UI is not used.

## Kept on purpose

- The helper still uses `$XDG_RUNTIME_DIR/omarchy-mx/` and `~/.config/omarchy-mx/`, so
  profiles and actions saved with the Omarchy plugin carry over.
- Commands reach the helper as spool files (`cmd-*.json`) that the service writes
  directly, instead of `mxctl.py write-cmd` on stdin, because Noctalia's `runAsync`
  cannot feed stdin. The file format is the one `write-cmd` produces.

## Updating

Copy the three files from a newer upstream commit, update the table and hashes above,
then re-check the `status.json` shape and command ops against `shared.luau`.
