from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from pathlib import Path


PLUGIN_DIR = Path(__file__).resolve().parents[1]
CONTROL = PLUGIN_DIR / "bridge-control.py"
UNIT = "noctalia-niri-media-idle.service"
_control_spec = importlib.util.spec_from_file_location("niri_media_idle_control", CONTROL)
assert _control_spec and _control_spec.loader
control = importlib.util.module_from_spec(_control_spec)
_control_spec.loader.exec_module(control)
ACTIVE_ENTER_CALL = {
    "command": "systemctl",
    "argv": [
        "--user",
        "show",
        "--property=ActiveEnterTimestampMonotonic",
        "--value",
        UNIT,
    ],
}


class BridgeControlTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.runtime_dir = self.root / "runtime"
        self.runtime_dir.mkdir()
        self.status_dir = self.runtime_dir / "noctalia-niri-media-idle"
        self.status_path = self.status_dir / "status.json"
        self.state_path = self.root / "unit-state"
        self.active_enter_path = self.root / "active-enter-usec"
        self.calls_path = self.root / "calls.jsonl"
        self.state_path.write_text("missing\n", encoding="utf-8")
        self.active_enter_path.write_text("", encoding="utf-8")
        self._write_fake_commands()
        self.env = {
            **os.environ,
            "PATH": str(self.bin_dir),
            "FAKE_UNIT_STATE": str(self.state_path),
            "FAKE_ACTIVE_ENTER": str(self.active_enter_path),
            "FAKE_CALLS": str(self.calls_path),
            "FAKE_MAIN_PID": "4242",
            "XDG_RUNTIME_DIR": str(self.runtime_dir),
        }

    def _write_fake_commands(self) -> None:
        systemctl = f"""#!{sys.executable}
import json
import os
import sys
import time
from pathlib import Path

UNIT = {UNIT!r}
args = sys.argv[1:]
with Path(os.environ["FAKE_CALLS"]).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps({{"command": "systemctl", "argv": args}}) + "\\n")

state_path = Path(os.environ["FAKE_UNIT_STATE"])
state = state_path.read_text(encoding="utf-8").strip()
if args == ["--user", "is-active", UNIT]:
    if os.environ.get("FAKE_STATUS_ERROR") == "1":
        print("user service manager unavailable", file=sys.stderr)
        raise SystemExit(1)
    print(state if state in ("active", "inactive", "failed") else "unknown")
    raise SystemExit(0 if state == "active" else 4 if state == "missing" else 3)
if args == ["--user", "show", "--property=MainPID", "--value", UNIT]:
    if os.environ.get("FAKE_MAIN_PID_ERROR") == "1":
        print("injected MainPID lookup failure", file=sys.stderr)
        raise SystemExit(1)
    print(os.environ.get("FAKE_MAIN_PID", "4242"))
    raise SystemExit(0)
if args == ["--user", "show", "--property=ActiveEnterTimestampMonotonic", "--value", UNIT]:
    if os.environ.get("FAKE_ACTIVE_ENTER_ERROR") == "1":
        print("injected ActiveEnterTimestampMonotonic lookup failure", file=sys.stderr)
        raise SystemExit(1)
    enter_path = Path(os.environ["FAKE_ACTIVE_ENTER"])
    entered = enter_path.read_text(encoding="utf-8").strip()
    if not entered:
        age_usec = int(os.environ.get("FAKE_UNIT_AGE_USEC", "5000000"))
        entered = str(time.monotonic_ns() // 1000 - age_usec)
    print(entered)
    raise SystemExit(0)
if args == ["--user", "reset-failed", UNIT]:
    if os.environ.get("FAKE_RESET_ERROR") == "1":
        print("injected reset-failed failure", file=sys.stderr)
        raise SystemExit(1)
    state_path.write_text("inactive\\n", encoding="utf-8")
    raise SystemExit(0)
if args == ["--user", "stop", UNIT]:
    if os.environ.get("FAKE_STOP_ERROR") == "1":
        print("injected stop failure", file=sys.stderr)
        raise SystemExit(1)
    if os.environ.get("FAKE_STOP_NO_CHANGE") == "1":
        raise SystemExit(0)
    state_path.write_text("inactive\\n", encoding="utf-8")
    raise SystemExit(0)
print("unexpected systemctl arguments", file=sys.stderr)
raise SystemExit(2)
"""
        systemd_run = f"""#!{sys.executable}
import json
import os
import sys
import time
from pathlib import Path

args = sys.argv[1:]
with Path(os.environ["FAKE_CALLS"]).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps({{"command": "systemd-run", "argv": args}}) + "\\n")
if os.environ.get("FAKE_SYSTEMD_RUN_ERROR") == "1":
    print("injected systemd-run failure", file=sys.stderr)
    raise SystemExit(1)
if not any(arg.startswith("--unit=") for arg in args):
    print("missing unit argument", file=sys.stderr)
    raise SystemExit(2)
if os.environ.get("FAKE_SYSTEMD_RUN_NO_CHANGE") != "1":
    Path(os.environ["FAKE_UNIT_STATE"]).write_text("active\\n", encoding="utf-8")
    Path(os.environ["FAKE_ACTIVE_ENTER"]).write_text(
        str(time.monotonic_ns() // 1000), encoding="utf-8"
    )
"""
        for name, contents in (("systemctl", systemctl), ("systemd-run", systemd_run)):
            executable = self.bin_dir / name
            executable.write_text(contents, encoding="utf-8")
            executable.chmod(0o755)

    def _run(self, action: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CONTROL), action],
            cwd=PLUGIN_DIR,
            env={**self.env, **env},
            capture_output=True,
            text=True,
            check=False,
        )

    def _write_status(
        self,
        media: str,
        state: str,
        *,
        logind_idle_held: bool = False,
        screensaver_held: bool = False,
        sleep_held: bool = False,
        pid: int = 4242,
        version: int = 2,
    ) -> None:
        self._write_status_record(
            {
                "version": version,
                "pid": pid,
                "media": media,
                "state": state,
                "logind_idle_held": logind_idle_held,
                "screensaver_held": screensaver_held,
                "sleep_held": sleep_held,
            }
        )

    def _write_status_record(self, record: dict[str, object]) -> None:
        self.status_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.status_path.write_text(
            json.dumps(record) + "\n",
            encoding="utf-8",
        )
        self.status_path.chmod(0o600)

    def _write_status_text(self, contents: str) -> None:
        self.status_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.status_path.write_text(contents, encoding="utf-8")
        self.status_path.chmod(0o600)

    def _calls(self) -> list[dict[str, object]]:
        if not self.calls_path.exists():
            return []
        return [
            json.loads(line)
            for line in self.calls_path.read_text(encoding="utf-8").splitlines()
        ]

    def _run_service_widget_harness(
        self,
        auto_start: bool | None,
    ) -> subprocess.CompletedProcess[str]:
        luau = shutil.which("luau")
        if luau is None:
            raise RuntimeError("Luau runtime is unavailable")

        config_value = "nil" if auto_start is None else str(auto_start).lower()
        translations = json.loads(
            (PLUGIN_DIR / "translations" / "en.json").read_text(encoding="utf-8")
        )["tooltip"]
        translation_table = "local translations = {\n" + ",\n".join(
            f"[{json.dumps(f'tooltip.{key}')}] = {json.dumps(value)}"
            for key, value in translations.items()
        ) + "\n}"
        harness = (
            (PLUGIN_DIR / "tests" / "service_harness.luau.in").read_text(
                encoding="utf-8"
            )
            .replace("@@AUTO_START@@", config_value)
            .replace("@@TRANSLATIONS@@", translation_table)
            .replace(
                "-- SERVICE ENTRY SOURCE",
                (PLUGIN_DIR / "service.luau").read_text(encoding="utf-8"),
            )
            .replace(
                "-- WIDGET ENTRY SOURCE",
                (PLUGIN_DIR / "widget.luau").read_text(encoding="utf-8"),
            )
        )
        harness_path = self.root / "service_harness.luau"
        harness_path.write_text(harness, encoding="utf-8")
        return subprocess.run(
            [luau, str(harness_path)],
            cwd=PLUGIN_DIR,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_manifest_settings_and_state_tooltips(self) -> None:
        manifest = tomllib.loads((PLUGIN_DIR / "plugin.toml").read_text(encoding="utf-8"))
        self.assertEqual(manifest["version"], "1.2.0")
        setting = next(
            item for item in manifest["setting"] if item["key"] == "auto_start"
        )
        self.assertEqual(setting["type"], "bool")
        self.assertIs(setting["default"], True)

        translations = json.loads(
            (PLUGIN_DIR / "translations" / "en.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            translations["settings"]["auto_start"]["label"],
            "Start bridge automatically",
        )
        tooltip_keys = (
            "busy",
            "failed",
            "inactive",
            "incomplete",
            "loading",
            "music_sleep",
            "music_sleep_incomplete",
            "normal",
            "protection_unknown",
            "protected",
            "status_error",
            "unknown",
        )
        for key in tooltip_keys:
            with self.subTest(tooltip=key):
                text = translations["tooltip"][key]
                self.assertIn("Source: this bridge only.", text)

    @unittest.skipUnless(shutil.which("luau"), "Luau runtime is not installed")
    def test_service_widget_setting_lifecycle_and_private_tooltips(self) -> None:
        for auto_start in (False, None):
            with self.subTest(auto_start=auto_start):
                result = self._run_service_widget_harness(auto_start)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_status_reports_protected_only_for_a_current_complete_record(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")
        self._write_status(
            "video",
            "protected",
            logind_idle_held=True,
            screensaver_held=True,
            sleep_held=True,
        )

        result = self._run("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active protected\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            {
                "command": "systemctl",
                "argv": ["--user", "show", "--property=MainPID", "--value", UNIT],
            },
        ])

    def test_start_reports_the_current_protection_state_for_an_active_unit(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")
        self._write_status(
            "video",
            "protected",
            logind_idle_held=True,
            screensaver_held=True,
            sleep_held=True,
        )

        result = self._run("start")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active protected\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            {
                "command": "systemctl",
                "argv": ["--user", "show", "--property=MainPID", "--value", UNIT],
            },
        ])

    def test_status_rejects_duplicate_record_fields(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")
        self._write_status_text(
            '{"version":2,"pid":4242,"media":"video","state":"incomplete",'
            '"state":"protected","logind_idle_held":true,"screensaver_held":true,'
            '"sleep_held":true}\n'
        )

        result = self._run("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            ACTIVE_ENTER_CALL,
        ])

    def test_status_reports_unknown_when_active_record_is_missing(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")

        result = self._run("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            ACTIVE_ENTER_CALL,
        ])

    def test_status_shows_loading_only_within_three_seconds_of_unit_start(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")

        result = self._run("status", FAKE_UNIT_AGE_USEC="2000000")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active loading\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            ACTIVE_ENTER_CALL,
        ])

        self.calls_path.unlink()
        result = self._run("status", FAKE_UNIT_AGE_USEC="4000000")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active unknown\n")

    def test_status_surfaces_unit_age_lookup_errors(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")

        result = self._run("status", FAKE_ACTIVE_ENTER_ERROR="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("ActiveEnterTimestampMonotonic lookup failure", result.stderr)

    def test_status_maps_every_valid_v2_state(self) -> None:
        for media, state, logind_idle_held, screensaver_held, sleep_held in (
            ("none", "normal", False, False, False),
            ("music", "music_sleep", False, False, True),
            ("music", "music_sleep_incomplete", False, False, False),
            ("video", "incomplete", True, False, True),
        ):
            with self.subTest(media=media, state=state):
                self.state_path.write_text("active\n", encoding="utf-8")
                self._write_status(
                    media,
                    state,
                    logind_idle_held=logind_idle_held,
                    screensaver_held=screensaver_held,
                    sleep_held=sleep_held,
                )

                result = self._run("status")

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"active {state}\n")
                self.calls_path.unlink(missing_ok=True)

    def test_status_does_not_infer_protection_from_held_flags(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")
        self._write_status(
            "unknown",
            "unknown",
            logind_idle_held=True,
            screensaver_held=True,
            sleep_held=True,
        )

        result = self._run("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active unknown\n")

    def test_status_schema_rejects_unknown_state_with_any_held_inhibitor(self) -> None:
        record: dict[str, object] = {
            "version": 2,
            "pid": 4242,
            "media": "unknown",
            "state": "unknown",
            "logind_idle_held": False,
            "screensaver_held": False,
            "sleep_held": False,
        }
        self.assertTrue(control.valid_status_record(record))

        for field in ("logind_idle_held", "screensaver_held", "sleep_held"):
            with self.subTest(field=field):
                impossible = {**record, field: True}
                self.assertFalse(control.valid_status_record(impossible))

    def test_status_rejects_malformed_and_impossible_records(self) -> None:
        base: dict[str, object] = {
            "version": 2,
            "pid": 4242,
            "media": "video",
            "state": "protected",
            "logind_idle_held": True,
            "screensaver_held": True,
            "sleep_held": True,
        }
        missing_pid = {key: value for key, value in base.items() if key != "pid"}
        invalid_records = (
            ("missing field", missing_pid),
            ("extra field", {**base, "title": "private media"}),
            ("version mismatch", {**base, "version": 1}),
            ("boolean version", {**base, "version": True}),
            ("boolean pid", {**base, "pid": True}),
            ("zero pid", {**base, "pid": 0}),
            ("invalid media type", {**base, "media": []}),
            ("invalid media value", {**base, "media": "browser"}),
            ("invalid state type", {**base, "state": []}),
            ("invalid state value", {**base, "state": "music"}),
            ("non-boolean inhibitor", {**base, "logind_idle_held": 1}),
            ("no media with inhibitors", {
                **base,
                "media": "none",
                "state": "normal",
                "logind_idle_held": False,
                "screensaver_held": False,
                "sleep_held": True,
            }),
            ("normal state with an inhibitor held", {
                **base,
                "media": "none",
                "state": "normal",
                "logind_idle_held": True,
                "screensaver_held": False,
                "sleep_held": False,
            }),
            ("protected without every inhibitor", {
                **base,
                "sleep_held": False,
            }),
            ("protected for music", {
                **base,
                "media": "music",
                "state": "protected",
            }),
            ("music sleep with extra idle inhibitor", {
                **base,
                "media": "music",
                "state": "music_sleep",
                "logind_idle_held": True,
                "screensaver_held": False,
                "sleep_held": True,
            }),
            ("music sleep without sleep inhibitor", {
                **base,
                "media": "music",
                "state": "music_sleep",
                "logind_idle_held": False,
                "screensaver_held": False,
                "sleep_held": False,
            }),
            ("incomplete music with idle inhibitor", {
                **base,
                "media": "music",
                "state": "music_sleep_incomplete",
                "logind_idle_held": True,
                "screensaver_held": False,
                "sleep_held": False,
            }),
            ("incomplete music with ScreenSaver inhibitor", {
                **base,
                "media": "music",
                "state": "music_sleep_incomplete",
                "logind_idle_held": False,
                "screensaver_held": True,
                "sleep_held": False,
            }),
            ("incomplete video with every inhibitor", {
                **base,
                "state": "incomplete",
            }),
            ("unknown media with a known state", {
                **base,
                "media": "unknown",
                "state": "normal",
                "logind_idle_held": False,
                "screensaver_held": False,
                "sleep_held": False,
            }),
        )
        self.state_path.write_text("active\n", encoding="utf-8")
        for name, record in invalid_records:
            with self.subTest(record=name):
                self._write_status_record(record)
                self.calls_path.unlink(missing_ok=True)

                result = self._run("status")

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "active unknown\n")
                self.assertEqual(self._calls(), [
                    {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
                    ACTIVE_ENTER_CALL,
                ])

        with self.subTest(record="malformed JSON"):
            self._write_status_text("{\n")
            self.calls_path.unlink(missing_ok=True)

            result = self._run("status")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "active unknown\n")
            self.assertEqual(self._calls(), [
                {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
                ACTIVE_ENTER_CALL,
            ])

    def test_status_treats_a_stale_pid_as_unknown(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")
        self._write_status(
            "video",
            "protected",
            logind_idle_held=True,
            screensaver_held=True,
            sleep_held=True,
            pid=4241,
        )

        result = self._run("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            {
                "command": "systemctl",
                "argv": ["--user", "show", "--property=MainPID", "--value", UNIT],
            },
            ACTIVE_ENTER_CALL,
        ])

    def test_status_surfaces_mainpid_lookup_errors(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")
        self._write_status(
            "video",
            "protected",
            logind_idle_held=True,
            screensaver_held=True,
            sleep_held=True,
        )

        result = self._run("status", FAKE_MAIN_PID_ERROR="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("injected MainPID lookup failure", result.stderr)

    def test_start_requires_an_absolute_runtime_directory(self) -> None:
        result = self._run("start", XDG_RUNTIME_DIR="")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("XDG_RUNTIME_DIR", result.stderr)
        self.assertEqual([call["command"] for call in self._calls()], ["systemctl"])

    def test_start_uses_fixed_argument_arrays_and_confirms_running_unit(self) -> None:
        files_before = {
            path.relative_to(PLUGIN_DIR): path.read_bytes()
            for path in PLUGIN_DIR.rglob("*")
            if path.is_file()
        }

        result = self._run("start")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active loading\n")
        calls = self._calls()
        self.assertEqual([call["command"] for call in calls], [
            "systemctl",
            "systemd-run",
            "systemctl",
            "systemctl",
        ])
        self.assertEqual(calls[0]["argv"], ["--user", "is-active", UNIT])
        self.assertEqual(
            calls[1]["argv"],
            [
                "--user",
                "--quiet",
                "--collect",
                f"--unit={UNIT}",
                "--description=Noctalia Niri Media Idle Bridge",
                "--property=PartOf=graphical-session.target",
                "--property=After=niri.service",
                "--property=Restart=on-failure",
                "--property=RestartSec=3s",
                "--property=RuntimeDirectory=noctalia-niri-media-idle",
                "--property=RuntimeDirectoryMode=0700",
                sys.executable,
                str(PLUGIN_DIR / "media-idle-bridge"),
                "--config",
                str(PLUGIN_DIR / "media-idle-rules.toml"),
                "--status-file",
                str(self.status_path),
            ],
        )
        self.assertEqual(calls[2]["argv"], ["--user", "is-active", UNIT])
        self.assertEqual(calls[3], ACTIVE_ENTER_CALL)
        files_after = {
            path.relative_to(PLUGIN_DIR): path.read_bytes()
            for path in PLUGIN_DIR.rglob("*")
            if path.is_file()
        }
        self.assertEqual(files_after, files_before)

    def test_start_is_idempotent_when_unit_is_already_active(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")

        result = self._run("start")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            ACTIVE_ENTER_CALL,
        ])

    def test_start_resets_an_explicitly_failed_unit(self) -> None:
        self.state_path.write_text("failed\n", encoding="utf-8")

        result = self._run("start")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "active loading\n")
        self.assertEqual([call["argv"] for call in self._calls()], [
            ["--user", "is-active", UNIT],
            ["--user", "reset-failed", UNIT],
            [
                "--user",
                "--quiet",
                "--collect",
                f"--unit={UNIT}",
                "--description=Noctalia Niri Media Idle Bridge",
                "--property=PartOf=graphical-session.target",
                "--property=After=niri.service",
                "--property=Restart=on-failure",
                "--property=RestartSec=3s",
                "--property=RuntimeDirectory=noctalia-niri-media-idle",
                "--property=RuntimeDirectoryMode=0700",
                sys.executable,
                str(PLUGIN_DIR / "media-idle-bridge"),
                "--config",
                str(PLUGIN_DIR / "media-idle-rules.toml"),
                "--status-file",
                str(self.status_path),
            ],
            ["--user", "is-active", UNIT],
            ACTIVE_ENTER_CALL["argv"],
        ])

    def test_reset_failure_is_reported_without_running_the_unit(self) -> None:
        self.state_path.write_text("failed\n", encoding="utf-8")

        result = self._run("start", FAKE_RESET_ERROR="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("injected reset-failed failure", result.stderr)
        self.assertEqual([call["command"] for call in self._calls()], ["systemctl", "systemctl"])

    def test_status_treats_missing_unit_as_stopped(self) -> None:
        result = self._run("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "inactive unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]}
        ])

    def test_status_reports_failed_unit_without_claiming_it_is_running(self) -> None:
        self.state_path.write_text("failed\n", encoding="utf-8")

        result = self._run("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "failed unknown\n")

    def test_status_surfaces_user_manager_errors_instead_of_reporting_stopped(self) -> None:
        result = self._run("status", FAKE_STATUS_ERROR="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("user service manager unavailable", result.stderr)

    def test_stop_is_idempotent_for_an_inactive_unit(self) -> None:
        self.state_path.write_text("inactive\n", encoding="utf-8")

        result = self._run("stop")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "inactive unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]}
        ])

    def test_stop_reports_a_failed_unit_as_failed_and_unknown(self) -> None:
        self.state_path.write_text("failed\n", encoding="utf-8")

        result = self._run("stop")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "failed unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]}
        ])

    def test_stop_stops_and_verifies_an_active_unit(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")

        result = self._run("stop")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "inactive unknown\n")
        self.assertEqual(self._calls(), [
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
            {"command": "systemctl", "argv": ["--user", "stop", UNIT]},
            {"command": "systemctl", "argv": ["--user", "is-active", UNIT]},
        ])

    def test_start_failure_is_reported_without_claiming_active(self) -> None:
        result = self._run("start", FAKE_SYSTEMD_RUN_ERROR="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("injected systemd-run failure", result.stderr)
        self.assertEqual(self.state_path.read_text(encoding="utf-8").strip(), "missing")

    def test_stop_failure_is_reported_without_claiming_inactive(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")

        result = self._run("stop", FAKE_STOP_ERROR="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("injected stop failure", result.stderr)
        self.assertEqual(self.state_path.read_text(encoding="utf-8").strip(), "active")

    def test_start_does_not_claim_active_if_systemd_run_did_not_activate_unit(self) -> None:
        self.state_path.write_text("inactive\n", encoding="utf-8")

        result = self._run("start", FAKE_SYSTEMD_RUN_NO_CHANGE="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("did not become active", result.stderr)
        self.assertEqual(self.state_path.read_text(encoding="utf-8").strip(), "inactive")

    def test_stop_does_not_claim_inactive_if_unit_remains_active(self) -> None:
        self.state_path.write_text("active\n", encoding="utf-8")

        result = self._run("stop", FAKE_STOP_NO_CHANGE="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("still active", result.stderr)
        self.assertEqual(self.state_path.read_text(encoding="utf-8").strip(), "active")


if __name__ == "__main__":
    unittest.main()
