#!/usr/bin/env python3
"""Run the bundled EncoBuds CLI from the plugin directory.

The plugin's service calls this with the system Python:

    python3 <pluginDir>/scripts/encobuds.py --json status

`enco/` next to this file is the same code as the upstream EncoBuds project, so
the plugin is self-contained: nothing outside the plugin directory is needed to
talk to the earbuds. The CLI keeps its own config file at
~/.config/encobuds/config.json.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from enco.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
