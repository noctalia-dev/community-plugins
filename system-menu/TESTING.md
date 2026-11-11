# Tests

From the repository root:

```sh
python3 -B -m unittest test_catalog -v
python3 -B -m unittest discover -s system-menu/packages -p 'test_*.py' -v
python3 -B -m unittest discover -s system-menu -p 'test_collect.py' -v
(cd system-menu && lua test_ui.lua)
noctalia plugins lint system-menu
```

Transactions and API responses are mocked. Real fzf filter tests need fzf 0.74.5+
but no root access, graphical session or network. Tests cover terminal argument
arrays, configurable helpers (paru, yay and custom executable paths), propagation
to fzf callbacks and unchanged pacman operations. A temporary stub checks direct
helper execution; no real packages are installed or updated. Real terminal windows
and live paru/yay transactions still need graphical/manual testing.
Lua tests also cover CachyOS/Arch/Artix and arbitrary distro icons, themed and
system-file resolution, parent-distro and generic fallbacks, missing/malformed
os-release files, and matching logos across the bar, menu and About panel.
The community PR remains a draft
until portable-build screenshots, compositor testing and human review are complete.
