# Tests

From the repository root:

```sh
python3 -B -m unittest discover -s system-menu/packages -p 'test_*.py' -v
python3 -B -m unittest discover -s system-menu -p 'test_collect.py' -v
(cd system-menu && lua test_ui.lua)
noctalia plugins lint system-menu
```

Transactions and API responses are mocked. Real fzf filter tests need fzf 0.74.5+
but no root access, graphical session or network. The community PR remains a draft
until portable-build screenshots, compositor testing and human review are complete.
