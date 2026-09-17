"""Run real service/launcher sources against an isolated fake Noctalia runtime."""

import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
LUAU = os.environ.get("LUAU_BIN") or shutil.which("luau")


class ServiceLauncherTests(unittest.TestCase):
    def test_production_requires_use_noctalia_paths(self):
        for source_path in PLUGIN.glob("*.luau"):
            source = source_path.read_text()
            for required_path in re.findall(r'require\("([^"]+)"\)', source):
                self.assertTrue(
                    required_path.startswith("./") and required_path.endswith(".luau"),
                    f"{source_path.name}: invalid Noctalia require path {required_path!r}",
                )

    def run_scenario(self, scenario):
        if LUAU is None:
            self.skipTest("luau is not installed")
        with tempfile.TemporaryDirectory(prefix="sp-service-launcher-") as directory:
            root = Path(directory)
            sources = []
            for name in ("common", "rest", "rest_state", "operation", "service", "launcher", "panel"):
                source = (PLUGIN / f"{name}.luau").read_text()
                sources.append(f'["{name}"] = [====[{source}]====],')
            (root / "service-launcher-sources.luau").write_text(
                "return {\n" + "\n".join(sources) + "\n}\n"
            )
            shutil.copyfile(
                PLUGIN / "tests" / "service-launcher-test.luau",
                root / "service-launcher-test.luau",
            )
            result = subprocess.run(
                [LUAU, "service-launcher-test.luau", "-a", scenario],
                cwd=root, text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"{scenario} passed", result.stdout)

    def test_launch_resolution_and_process_probes(self):
        for scenario in (
            "launch-default", "launch-custom", "launch-path", "launch-wrapper",
            "launch-stopped", "launch-missing-path", "launch-invalid",
            "launch-flatpak", "launch-auto-flatpak",
        ):
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)

    def test_timer_confirmation(self):
        for scenario in (
            "timer-start-success", "timer-stop-success",
            "timer-start-failed", "timer-stop-failed",
            "timer-start-contradictory", "timer-stop-contradictory",
            "timer-start-missing", "timer-start-queued", "timer-stop-queued",
            "timer-stop-unresolved",
            "timer-start-queued-failed", "timer-stop-queued-contradictory",
        ):
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)

    def test_operation_integration(self):
        for scenario in ("selection-pinning", "confirmation-timeout", "terminal-refresh-reentrancy", "selection-synchronous"):
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)

    def test_busy_selection_capture(self):
        self.run_scenario("busy-select")

    def test_queued_rejection(self):
        self.run_scenario("queued-rejection")

    def test_synchronous_success(self):
        self.run_scenario("sync-success")

    def test_synchronous_error(self):
        self.run_scenario("sync-error")

    def test_package_build_intent(self):
        self.run_scenario("package-build")

    def test_connection_expiry(self):
        self.run_scenario("expiry")

    def test_quiet_service_loop(self):
        for scenario in (
            "idle-ticks", "response-scanning", "time-publication", "rest-timeout-ticks",
        ):
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)

    def test_change_metadata_recovers_after_clock_skew(self):
        self.run_scenario("change-clock-skew")


if __name__ == "__main__":
    unittest.main()
