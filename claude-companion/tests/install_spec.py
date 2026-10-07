#!/usr/bin/env python3
"""Unit tests for the hook installer (hooks/install.py).

It edits the user's ~/.claude/settings.json, which also carries every OTHER tool's
hooks, so the properties that matter are: foreign hooks survive byte-for-byte, a stale
path is repaired in place rather than duplicated, a second run changes nothing, and
malformed or read-only settings are refused without a write.

main() takes argv explicitly (see .memory/mistakes.md, 2026-09-06 sys.argv trap).
Run: python3 tests/install_spec.py
"""
import importlib.util
import io
import json
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
_spec = importlib.util.spec_from_file_location("install", os.path.join(_ROOT, "hooks", "install.py"))
install = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(install)

MEMD = {"type": "command", "command": "memd hook session-start"}
RTK = {"type": "command", "command": "rtk hook claude"}


def commands(settings, event):
    return [h["command"] for g in settings["hooks"].get(event, []) for h in g["hooks"]]


class Harness(unittest.TestCase):
    """A private HOME / XDG / Claude config root per test."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.home = os.path.join(t, "home")
        os.makedirs(self.home)
        self.env = mock.patch.dict(os.environ, {
            "HOME": self.home,
            "XDG_STATE_HOME": os.path.join(self.home, ".local", "state"),
            "XDG_DATA_HOME": os.path.join(self.home, ".local", "share"),
        })
        self.env.start()
        for var in ("NOCTALIA_STATE_HOME", "NOCTALIA_DATA_HOME", "CLAUDE_CONFIG_DIR"):
            os.environ.pop(var, None)
        self.base = os.path.join(self.home, ".local", "share", "noctalia", "plugins", "claude-companion")
        os.makedirs(os.path.join(self.base, "hooks"))
        for script in ("pulse.py", "consent.py"):
            open(os.path.join(self.base, "hooks", script), "w").close()
        self.settings = os.path.join(self.home, ".claude", "settings.json")

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def write(self, obj, mode=0o600):
        os.makedirs(os.path.dirname(self.settings), exist_ok=True)
        with open(self.settings, "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))
        os.chmod(self.settings, mode)

    def read(self):
        with open(self.settings) as f:
            return f.read()

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = install.main(list(argv) + ["--settings", self.settings])
        return rc, out.getvalue(), err.getvalue()


class Plan(Harness):
    def test_fresh_settings_get_every_entry(self):
        out, problems = install.plan({}, self.base)
        self.assertEqual(len(problems), len(install.ENTRIES))
        self.assertTrue(all(p.startswith("missing: ") for p in problems))
        for ev, matcher, script, arg, timeout in install.ENTRIES:
            want = install.command_for(self.base, script, arg)
            hits = [(g, h) for g in out["hooks"][ev] for h in g["hooks"] if h["command"] == want]
            self.assertEqual(len(hits), 1, want)
            group, hook = hits[0]
            self.assertEqual(group["matcher"], matcher)
            self.assertEqual(hook.get("timeout"), timeout)

    def test_commands_use_home_form_and_guard(self):
        cmd = install.command_for(self.base, "pulse.py", "idle")
        self.assertEqual(cmd, "python3 $HOME/.local/share/noctalia/plugins/claude-companion/hooks/pulse.py idle 2>/dev/null || true")

    def test_second_run_is_a_no_op(self):
        once, _ = install.plan({}, self.base)
        twice, problems = install.plan(once, self.base)
        self.assertEqual(problems, [])
        self.assertEqual(twice, once)

    def test_plan_does_not_mutate_its_input(self):
        src = {"hooks": {"Stop": [{"hooks": [dict(MEMD)]}]}}
        snapshot = json.dumps(src, sort_keys=True)
        install.plan(src, self.base)
        self.assertEqual(json.dumps(src, sort_keys=True), snapshot)

    def test_foreign_hooks_and_keys_survive(self):
        src = {
            "permissions": {"allow": ["Bash(git *)"]},
            "hooks": {
                "SessionStart": [{"hooks": [dict(MEMD)]}],
                "PreToolUse": [{"matcher": "Bash", "hooks": [dict(RTK)]}],
            },
        }
        out, _ = install.plan(src, self.base)
        self.assertEqual(out["permissions"], src["permissions"])
        self.assertEqual(out["hooks"]["SessionStart"][0], {"hooks": [MEMD]})
        self.assertEqual(out["hooks"]["PreToolUse"][0], {"matcher": "Bash", "hooks": [RTK]})

    def test_stale_path_is_repaired_in_place(self):
        old = "python3 $HOME/.local/state/noctalia/plugins/materialized/community/claude-companion/hooks/pulse.py tool_start 2>/dev/null || true"
        src = {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": old}]}]}}
        out, problems = install.plan(src, self.base)
        self.assertIn("stale: PreToolUse pulse.py tool_start -> " + old.split()[1], problems)
        groups = out["hooks"]["PreToolUse"]
        self.assertEqual(groups[0]["hooks"][0]["command"], install.command_for(self.base, "pulse.py", "tool_start"))
        self.assertEqual(sum("pulse.py tool_start" in c for c in commands(out, "PreToolUse")), 1)

    def test_repair_keeps_the_rest_of_the_command(self):
        old = "/usr/bin/python3 -u /gone/claude-companion/hooks/pulse.py turn_end"
        src = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": old}]}]}}
        out, _ = install.plan(src, self.base)
        self.assertEqual(
            commands(out, "Stop"),
            ["/usr/bin/python3 -u $HOME/.local/share/noctalia/plugins/claude-companion/hooks/pulse.py turn_end"],
        )

    def test_duplicates_are_dropped_and_empty_groups_removed(self):
        a = "python3 /old/claude-companion/hooks/pulse.py turn_end"
        b = install.command_for(self.base, "pulse.py", "turn_end")
        src = {"hooks": {"Stop": [
            {"hooks": [{"type": "command", "command": a}]},
            {"hooks": [{"type": "command", "command": b}]},
        ]}}
        out, problems = install.plan(src, self.base)
        self.assertIn("duplicate: Stop pulse.py turn_end", problems)
        self.assertEqual(len(out["hooks"]["Stop"]), 1)
        # first one wins and is repaired in place
        self.assertEqual(commands(out, "Stop"), [b.replace(install.GUARD, "")])

    def test_duplicate_removal_spares_a_shared_group(self):
        ours = install.command_for(self.base, "pulse.py", "idle")
        src = {"hooks": {"SessionStart": [
            {"hooks": [{"type": "command", "command": ours}]},
            {"hooks": [dict(MEMD), {"type": "command", "command": ours}]},
        ]}}
        out, _ = install.plan(src, self.base)
        self.assertEqual(out["hooks"]["SessionStart"][1], {"hooks": [MEMD]})

    def test_consent_timeout_is_enforced(self):
        cmd = install.command_for(self.base, "consent.py", None)
        src = {"hooks": {"PreToolUse": [{"matcher": "Bash|Write|Edit|NotebookEdit",
                                         "hooks": [{"type": "command", "command": cmd}]}]}}
        out, problems = install.plan(src, self.base)
        self.assertIn("timeout: PreToolUse consent.py needs >= 120s", problems)
        group = out["hooks"]["PreToolUse"][0]
        self.assertEqual(group["matcher"], "Bash|Write|Edit|NotebookEdit")  # user's matcher kept
        self.assertEqual(group["hooks"][0]["timeout"], 120)

    def test_other_tools_pulse_py_is_not_claimed(self):
        other = "python3 /opt/elsewhere/hooks/pulse.py idle"
        src = {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": other}]}]}}
        out, problems = install.plan(src, self.base)
        self.assertIn(other, commands(out, "SessionStart"))
        self.assertIn("missing: SessionStart pulse.py idle", problems)

    def test_redirect_is_not_read_as_the_event(self):
        cmd = "python3 /x/claude-companion/hooks/pulse.py 2>/dev/null"
        self.assertIsNone(install._match(cmd, self.base)[4])

    def test_chained_command_still_reads_its_event(self):
        cmd = "python3 /x/claude-companion/hooks/pulse.py idle; echo hi"
        src = {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": cmd}]}]}}
        out, problems = install.plan(src, self.base)
        self.assertFalse(any(p.startswith("missing: SessionStart") for p in problems))
        self.assertEqual(len(commands(out, "SessionStart")), 1)

    def test_backup_copy_of_a_script_is_not_ours(self):
        self.assertIsNone(install._match("python3 /x/claude-companion/hooks/pulse.py.bak idle", self.base))

    def test_lookalike_dir_is_not_ours(self):
        foreign = {"type": "command", "command": "python3 /opt/claude-companion-tools/hooks/pulse.py idle"}
        ours = {"type": "command", "command": install.command_for(self.base, "pulse.py", "idle")}
        src = {"hooks": {"SessionStart": [{"hooks": [ours]}, {"hooks": [foreign]}]}}
        out, problems = install.plan(src, self.base)
        self.assertEqual(problems, [p for p in problems if p.startswith("missing: ")])
        self.assertEqual(out["hooks"]["SessionStart"][1], {"hooks": [foreign]})

    def test_path_with_spaces_round_trips(self):
        base = os.path.join(self.tmp.name, "odd dir", "claude-companion")
        os.makedirs(os.path.join(base, "hooks"))
        open(os.path.join(base, "hooks", "pulse.py"), "w").close()
        cmd = install.command_for(base, "pulse.py", "idle")
        self.assertIn('"', cmd)
        out, _ = install.plan({}, base)
        self.assertEqual(install.plan(out, base)[1], [])

    def test_shell_special_path_round_trips(self):
        base = os.path.join(self.home, "x$HOME`y", "claude-companion")  # $HOME must stay literal
        os.makedirs(os.path.join(base, "hooks"))
        for script in ("pulse.py", "consent.py"):
            open(os.path.join(base, "hooks", script), "w").close()
        out, _ = install.plan({}, base)
        self.assertEqual(install.plan(out, base)[1], [])

    def test_unquotable_path_is_refused(self):
        with self.assertRaises(install.Refused):
            install.plan({}, os.path.join(self.tmp.name, "it's $odd", "claude-companion"))

    def test_non_object_hooks_are_refused(self):
        with self.assertRaises(install.Refused):
            install.plan({"hooks": []}, self.base)
        with self.assertRaises(install.Refused):
            install.plan({"hooks": {"Stop": "nope"}}, self.base)


class Base(Harness):
    def test_symlinked_dev_install_resolves_to_the_link(self):
        repo = os.path.join(self.tmp.name, "repo")
        os.rename(self.base, repo)
        os.symlink(repo, self.base)
        self.assertEqual(install.plugin_base(repo), self.base)

    def test_catalog_install_resolves_to_materialized_dir(self):
        cat = os.path.join(self.home, ".local", "state", "noctalia", "plugins", "materialized", "community", "claude-companion")
        os.makedirs(cat)
        self.assertEqual(install.plugin_base(cat), cat)

    def test_unknown_location_is_used_as_is(self):
        loose = os.path.join(self.tmp.name, "loose")
        os.makedirs(loose)
        self.assertEqual(install.plugin_base(loose), loose)


class Main(Harness):
    def test_check_on_missing_file_reports_and_writes_nothing(self):
        rc, out, _ = self.run_main("--check")
        self.assertEqual(rc, 1)
        self.assertIn("missing: " + self.settings, out)
        self.assertIn("fix: python3 ", out)
        self.assertFalse(os.path.exists(self.settings))

    def test_install_creates_0600_file_then_check_passes(self):
        rc, _, _ = self.run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(stat.S_IMODE(os.stat(self.settings).st_mode), 0o600)
        rc, out, _ = self.run_main("--check")
        self.assertEqual((rc, out.split(":")[0]), (0, "ok"))

    def test_install_backs_up_and_keeps_mode(self):
        original = json.dumps({"hooks": {"SessionStart": [{"hooks": [MEMD]}]}})
        self.write(original, mode=0o640)
        rc, out, _ = self.run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(stat.S_IMODE(os.stat(self.settings).st_mode), 0o640)
        folder = os.path.dirname(self.settings)
        backups = [f for f in os.listdir(folder) if ".bak.claude-companion-" in f]
        self.assertEqual(len(backups), 1)
        with open(os.path.join(folder, backups[0])) as f:
            self.assertEqual(f.read(), original)
        self.assertEqual(sorted(os.listdir(folder)), sorted(["settings.json", backups[0]]))

    def test_healthy_install_is_left_alone(self):
        self.run_main()
        before = self.read()
        folder = os.path.dirname(self.settings)
        count = len(os.listdir(folder))
        rc, out, _ = self.run_main()
        self.assertEqual((rc, self.read(), len(os.listdir(folder))), (0, before, count))
        self.assertTrue(out.startswith("ok: nothing to change"))

    def test_check_never_writes(self):
        stale = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "python3 /gone/claude-companion/hooks/pulse.py turn_end"}]}]}}
        self.write(stale)
        before = self.read()
        rc, out, _ = self.run_main("--check")
        self.assertEqual(rc, 1)
        self.assertIn("stale: Stop pulse.py turn_end -> /gone/claude-companion/hooks/pulse.py", out)
        self.assertEqual(self.read(), before)

    def test_malformed_json_is_refused(self):
        self.write('{"hooks": {,}')
        rc, _, err = self.run_main()
        self.assertEqual(rc, 2)
        self.assertIn("not valid JSON", err)
        self.assertEqual(self.read(), '{"hooks": {,}')

    @unittest.skipIf(os.geteuid() == 0, "root ignores file modes")
    def test_read_only_settings_are_refused(self):
        self.write({"model": "x"}, mode=0o400)
        folder = os.path.dirname(self.settings)
        os.chmod(folder, 0o500)
        try:
            rc, _, err = self.run_main()
        finally:
            os.chmod(folder, 0o700)
        self.assertEqual(rc, 2)
        self.assertIn("read-only", err)
        self.assertEqual(json.loads(self.read()), {"model": "x"})

    @unittest.skipIf(os.geteuid() == 0, "root ignores file modes")
    def test_read_only_folder_is_refused_cleanly(self):
        self.write({"model": "x"})
        folder = os.path.dirname(self.settings)
        os.chmod(folder, 0o500)
        try:
            rc, _, err = self.run_main()
        finally:
            os.chmod(folder, 0o700)
        self.assertEqual(rc, 2)
        self.assertIn("read-only", err)
        self.assertEqual(json.loads(self.read()), {"model": "x"})

    def test_write_failure_is_a_refusal_not_a_traceback(self):
        self.write({"model": "x"})
        with mock.patch.object(install.tempfile, "mkstemp", side_effect=OSError(28, "No space left on device")):
            rc, _, err = self.run_main()
        self.assertEqual(rc, 2)
        self.assertIn("No space left", err)
        self.assertEqual(json.loads(self.read()), {"model": "x"})

    def test_concurrent_edit_is_not_clobbered(self):
        self.write({"model": "x"})
        data, sig = install.load(self.settings)
        updated, _ = install.plan(data, self.base)
        with open(self.settings, "w") as f:
            f.write('{"model": "changed elsewhere"}')
        with self.assertRaises(install.Refused):
            install.save(self.settings, updated, sig)
        self.assertEqual(json.loads(self.read()), {"model": "changed elsewhere"})
        folder = os.path.dirname(self.settings)
        self.assertFalse([f for f in os.listdir(folder) if f.endswith(".tmp")])

    def test_same_second_backups_do_not_collide(self):
        self.write({"v": 1})
        with mock.patch.object(install.time, "strftime", return_value="20260919-120000"):
            data, sig = install.load(self.settings)
            install.save(self.settings, {"v": 2}, sig)
            data, sig = install.load(self.settings)
            install.save(self.settings, {"v": 3}, sig)
        folder = os.path.dirname(self.settings)
        backups = sorted(f for f in os.listdir(folder) if ".bak." in f)
        self.assertEqual(len(backups), 2)
        with open(os.path.join(folder, backups[0])) as f:
            self.assertEqual(json.load(f), {"v": 1})

    def test_symlinked_settings_stay_a_symlink(self):
        real = os.path.join(self.tmp.name, "dotfiles", "settings.json")
        os.makedirs(os.path.dirname(real))
        with open(real, "w") as f:
            f.write("{}")
        os.makedirs(os.path.dirname(self.settings))
        os.symlink(real, self.settings)
        rc, _, _ = self.run_main()
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.islink(self.settings))
        with open(real) as f:
            self.assertIn("hooks", json.load(f))


class Snippet(unittest.TestCase):
    """settings.snippet.json (the manual merge) must list exactly ENTRIES."""

    def test_snippet_matches_entries(self):
        with open(os.path.join(_ROOT, "hooks", "settings.snippet.json")) as f:
            snippet = json.load(f)
        found = set()
        for ev, groups in snippet["hooks"].items():
            for g in groups:
                for h in g["hooks"]:
                    words = h["command"].split()
                    script = os.path.basename(words[1])
                    arg = words[2] if script == "pulse.py" and len(words) > 2 else None
                    found.add((ev, g.get("matcher"), script, arg, h.get("timeout")))
        self.assertEqual(found, set(install.ENTRIES))


if __name__ == "__main__":
    unittest.main(verbosity=2)
