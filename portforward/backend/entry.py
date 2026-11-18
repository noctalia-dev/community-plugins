"""Entry point for the stable installed CLI; independent of the plugin source."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from portforward_manager.cli import main  # noqa: E402

sys.exit(main())
