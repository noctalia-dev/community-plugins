#!/usr/bin/env python3
"""Tests for the daemon state snapshot.

The panel refreshes every 500 ms with a `status` request and copies
`state.local_actions.rules` into its own rule list. If the daemon hands back
its cached copy of the engine state instead of a fresh one, the UI reverts
every toggle half a second after the user flips it.

Runs without Bluetooth or sockets: the engine is a stub and the daemon object
is built around it.
"""

import argparse
import copy
import json
import os
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import budsctl


class FakeEngine:
    """Minimal stand-in for LocalActionEngine: a mutable rule list."""

    def __init__(self, rules):
        self.rules = [dict(rule) for rule in rules]

    def upsert(self, rule):
        for index, existing in enumerate(self.rules):
            if existing.get("id") == rule.get("id"):
                self.rules[index] = rule
                return rule
        self.rules.append(rule)
        return rule

    def delete(self, rid):
        self.rules = [rule for rule in self.rules if rule.get("id") != rid]
        return self.rules

    def snapshot(self):
        return {
            "rules": copy.deepcopy(self.rules),
            "last_event": {},
            "last_action": {},
            "modifiers": [],
            "modifiers_available": False,
        }


def make_daemon(engine, cached_rules):
    daemon = object.__new__(budsctl.BudsDaemon)
    daemon.local = engine
    daemon.lock = threading.RLock()
    daemon.state = {"connected": False, "local_actions": {"rules": copy.deepcopy(cached_rules)}}
    daemon.log = lambda msg: None
    return daemon


class SnapshotTests(unittest.TestCase):
    def test_snapshot_returns_current_rules_not_the_cached_copy(self):
        rules = [{"id": "rule-1", "enabled": True}, {"id": "rule-2", "enabled": True}]
        engine = FakeEngine(rules)
        daemon = make_daemon(engine, rules)

        # The user turns rule-1 off; the engine persists it immediately.
        engine.rules[0]["enabled"] = False

        snap = daemon.snapshot()
        self.assertFalse(snap["local_actions"]["rules"][0]["enabled"])
        self.assertTrue(snap["local_actions"]["rules"][1]["enabled"])

    def test_snapshot_reflects_added_and_deleted_rules(self):
        engine = FakeEngine([{"id": "rule-1", "enabled": True}])
        daemon = make_daemon(engine, [{"id": "rule-1", "enabled": True}])

        engine.rules.append({"id": "rule-2", "enabled": True})
        self.assertEqual(len(daemon.snapshot()["local_actions"]["rules"]), 2)

        del engine.rules[0]
        rules = daemon.snapshot()["local_actions"]["rules"]
        self.assertEqual([rule["id"] for rule in rules], ["rule-2"])

    def test_snapshot_keeps_daemon_state_fields(self):
        engine = FakeEngine([{"id": "rule-1", "enabled": True}])
        daemon = make_daemon(engine, [{"id": "rule-1", "enabled": True}])

        engine.rules[0]["enabled"] = False
        snap = daemon.snapshot()

        self.assertFalse(snap["connected"])
        # The cached copy is the monitor's to refresh; snapshot() only reads it.
        self.assertTrue(daemon.state["local_actions"]["rules"][0]["enabled"])

    def test_snapshot_survives_a_failing_engine(self):
        class Broken:
            def snapshot(self):
                raise RuntimeError("engine gone")

        daemon = make_daemon(Broken(), [{"id": "rule-1", "enabled": True}])
        snap = daemon.snapshot()
        self.assertEqual(snap["local_actions"]["rules"], [])

    def test_snapshot_without_engine(self):
        daemon = make_daemon(None, [])
        self.assertEqual(daemon.snapshot()["local_actions"]["rules"], [])


class RuleWriteTests(unittest.TestCase):
    """A rule written by the panel has to reach state.json at once.

    The panel re-seeds its rule list from the state file twice a second: if
    the file keeps the previous version of the rule, the toggle jumps back
    half a second after the click and the stale value is saved again by the
    next change.
    """

    def make(self, rules):
        directory = tempfile.mkdtemp(prefix="cmf-buds-state-")
        args = argparse.Namespace(
            state=os.path.join(directory, "state.json"),
            socket=os.path.join(directory, "daemon.sock"),
            log=os.path.join(directory, "daemon.log"),
            poll=20,
            idle_timeout=300,
            device_mac="",
            device_name="",
        )
        daemon = budsctl.BudsDaemon(args)
        daemon.local = FakeEngine(rules)
        return daemon, args.state

    def rules_in_file(self, path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)["local_actions"]["rules"]

    def test_a_saved_rule_is_written_to_the_state_file(self):
        daemon, path = self.make([{"id": "r1", "enabled": True}])
        daemon.handle_rpc(
            {"cmd": "local_rule_set", "rule": {"id": "r1", "enabled": False}}
        )
        rules = self.rules_in_file(path)
        self.assertEqual(len(rules), 1)
        self.assertFalse(
            rules[0]["enabled"],
            "the state file keeps the old value: the panel would revert the toggle",
        )

    def test_a_deleted_rule_disappears_from_the_state_file(self):
        daemon, path = self.make([{"id": "r1"}, {"id": "r2"}])
        daemon.handle_rpc({"cmd": "local_rule_delete", "id": "r2"})
        ids = [rule["id"] for rule in self.rules_in_file(path)]
        self.assertEqual(ids, ["r1"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
