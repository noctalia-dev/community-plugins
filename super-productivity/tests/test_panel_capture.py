"""Exercise panel capture against the real service and synchronous state watchers."""

import unittest
import test_service_launcher


class PanelCaptureTests(unittest.TestCase):
    def test_capture_runtime(self):
        for scenario in ("panel-success", "panel-error", "panel-rejection"):
            with self.subTest(scenario=scenario):
                test_service_launcher.ServiceLauncherTests.run_scenario(self, scenario)
