#!/usr/bin/env python3
"""Tests for the internationalization of the daemon errors.

The daemon sends stable error codes (not sentences): the panel translates
them with the "error.code.<code>" keys of the plugin translations and the
technical context travels separately in "error_detail".

These tests make sure that every code has a translation in every language,
that there are no codes without a translation (and no translations without a
code), and that the Luau side uses the same helper.

Run with: python3 bin/test_i18n.py
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import budsctl

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def flatten(table, prefix=""):
    """Flatten a nested translation table into dotted paths."""
    out = {}
    for key, value in table.items():
        path = prefix + key
        if isinstance(value, dict):
            out.update(flatten(value, path + "."))
        else:
            out[path] = value
    return out


def read_translations(lang):
    with open(
        os.path.join(ROOT, "translations", "%s.json" % lang), encoding="utf-8"
    ) as fh:
        return flatten(json.load(fh))


class ErrorCodeTests(unittest.TestCase):
    def setUp(self):
        self.en = read_translations("en")
        self.es = read_translations("es")

    def test_every_error_code_has_a_translation_in_every_language(self):
        for lang, table in (("en", self.en), ("es", self.es)):
            for code in budsctl.ERROR_CODES:
                key = "error.code." + code
                self.assertIn(key, table, "%s has no translation for %s" % (lang, code))
                self.assertNotEqual(
                    table[key].strip(), "", "%s has an empty translation for %s" % (lang, code)
                )

    def test_there_are_no_translations_without_a_code(self):
        expected = set(budsctl.ERROR_CODES)
        for lang, table in (("en", self.en), ("es", self.es)):
            found = {
                key[len("error.code.") :]
                for key in table
                if key.startswith("error.code.")
            }
            self.assertEqual(
                found, expected, "%s has error codes the daemon never sends" % lang
            )

    def test_both_languages_have_the_same_keys(self):
        self.assertEqual(set(self.en), set(self.es))

    def test_the_state_keeps_the_code_and_the_detail_apart(self):
        daemon = budsctl.BudsDaemon(self._args())
        daemon.save = lambda: None
        daemon._set_error("not_found")
        self.assertEqual(daemon.state["error"], "not_found")
        self.assertEqual(daemon.state["error_detail"], "")
        daemon._set_error("connect_failed", "bluetoothctl: Connection refused")
        self.assertEqual(daemon.state["error"], "connect_failed")
        self.assertEqual(
            daemon.state["error_detail"], "bluetoothctl: Connection refused"
        )
        daemon._clear_error()
        self.assertEqual(daemon.state["error"], "")
        self.assertEqual(daemon.state["error_detail"], "")

    def test_an_unknown_error_code_is_refused(self):
        daemon = budsctl.BudsDaemon(self._args())
        daemon.save = lambda: None
        with self.assertRaises(ValueError):
            daemon._set_error("there_is_no_such_code")

    def test_the_rpc_error_carries_a_code_and_a_detail(self):
        daemon = budsctl.BudsDaemon(self._args())
        daemon.save = lambda: None
        resp = daemon._rpc_error(
            budsctl.UserError("no audio sink", code="no_sink")
        )
        self.assertFalse(resp.get("ok"))
        self.assertEqual(resp.get("error"), "no_sink")
        self.assertEqual(resp.get("error_detail"), "")
        resp = daemon._rpc_error(RuntimeError("something broke"))
        self.assertEqual(resp.get("error"), "daemon_failed")
        self.assertIn("something broke", resp.get("error_detail", ""))

    def test_the_luau_side_translates_the_codes(self):
        with open(os.path.join(ROOT, "lib", "common.luau"), encoding="utf-8") as fh:
            common = fh.read()
        self.assertIn("function M.error_text(", common)
        with open(os.path.join(ROOT, "lib", "panel_ui.luau"), encoding="utf-8") as fh:
            panel = fh.read()
        self.assertIn("C.error_text(", panel)
        with open(os.path.join(ROOT, "widget.luau"), encoding="utf-8") as fh:
            widget = fh.read()
        self.assertIn("C.error_text(", widget)

    @staticmethod
    def _args():
        import argparse
        import tempfile

        directory = tempfile.mkdtemp(prefix="cmf-buds-i18n-")
        return argparse.Namespace(
            state=os.path.join(directory, "state.json"),
            socket=os.path.join(directory, "daemon.sock"),
            log=os.path.join(directory, "daemon.log"),
            poll=20,
            idle_timeout=300,
            device_mac="",
            device_name="",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
