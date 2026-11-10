import unittest
from unittest.mock import patch
from pathlib import Path
import tomllib

import collect


class SystemProfileTests(unittest.TestCase):
    def test_about_persists_but_menu_remains_transient(self):
        manifest = tomllib.loads(Path(__file__).with_name("plugin.toml").read_text())
        panels = {panel["id"]: panel for panel in manifest["panel"]}
        self.assertTrue(panels["about"]["persistent"])
        self.assertFalse(panels["about"]["dismiss_on_outside_click"])
        self.assertEqual(panels["about"]["keyboard_focus"], "on_demand")
        self.assertEqual(panels["about"]["placement"], "floating")
        self.assertFalse(panels["menu"].get("persistent", False))

    def test_sizes_are_explicit_about_units(self):
        self.assertEqual(collect.size_label(16 * 1024**3, True), "16 GiB")
        self.assertEqual(collect.size_label(1000204886016), "1 TB")
        self.assertEqual(collect.size_label(33540079616, True), "31.2 GiB")

    def test_english_cpu_topology(self):
        words = ("thread", "threads")
        for count, expected in [(1, "1 thread"), (4, "4 threads"), (12, "12 threads"), (32, "32 threads")]:
            self.assertEqual(collect.plural(count, *words), expected)

    def test_oem_placeholders_are_not_computer_models(self):
        self.assertEqual(collect.usable("To Be Filled By O.E.M."), "")
        self.assertEqual(collect.usable("System Product Name"), "")
        self.assertEqual(collect.usable("Useful model"), "Useful model")

    @patch.object(collect, "run", return_value="")
    @patch.object(collect, "read", return_value="")
    @patch.object(collect, "json_command", side_effect=[[], {}])
    def test_missing_collectors_degrade_without_crashing(self, *_):
        profile = collect.collect()
        self.assertTrue(profile["hostname"])
        self.assertTrue(profile["warnings"])
        self.assertNotIn("Storage", [section["title"] for section in profile["sections"]])
        self.assertIn("Linux Kernel:", profile["report"])

    @patch.object(collect, "run", return_value="")
    @patch.object(collect, "read", return_value="")
    def test_physical_disks_not_zram_or_partitions(self, *_):
        devices = {"blockdevices": [
            {"name": "zram0", "type": "disk", "size": 32000000000},
            {"name": "loop0", "type": "loop", "size": 1000000000},
            {"name": "nvme0n1p1", "type": "part", "size": 1000000000},
            {"name": "nvme0n1", "type": "disk", "size": 1000000000000, "model": "Example SSD", "tran": "nvme", "rota": False},
        ]}
        with patch.object(collect, "json_command", side_effect=[[], devices]):
            profile = collect.collect()
        disks = next(section for section in profile["sections"] if section["title"] == "Storage")
        self.assertEqual(len(disks["rows"]), 1)
        self.assertEqual(disks["rows"][0]["value"], "Example SSD")
        self.assertEqual(disks["rows"][0]["detail"], "1 TB · SSD NVMe")

    def test_report_uses_only_curated_fields(self):
        profile = {
            "hostname": "desktop", "subtitle": "Linux", "serial": "secret-serial", "ip": "secret-ip",
            "sections": [{"title": "Hardware", "rows": [{"label": "Processor", "value": "CPU", "detail": "8 cores"}]}],
            "details": {"title": "Details", "rows": []},
        }
        report = collect.make_report(profile)
        self.assertIn("Processor: CPU (8 cores)", report)
        self.assertNotIn("secret", report)


if __name__ == "__main__":
    unittest.main()
