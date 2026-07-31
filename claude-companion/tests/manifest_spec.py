#!/usr/bin/env python3
"""Manifest invariants for plugin.toml — the settings contract.

Covers the one class of defect neither `noctalia plugins lint` nor the luau specs
can see: `lint` only cross-checks declared settings against getConfig() calls, and
the widget code never observes a slider's step, so a wrong step is invisible to
both. Run: python3 tests/manifest_spec.py

The load-bearing invariant is STEP. Noctalia's manifest parser defaults an
omitted step to 1.0 (plugin_manifest.h: `double step = 1.0`), so a fractional
range silently degenerates to min + n*1.0 clamped to max — a handful of preset
stops instead of a slider. Shipped exactly that way once: pulse_glow_floor
(0.0-0.9) could only reach 0.0 and 0.9. Every double MUST declare step.
"""
import os
import unittest

try:
    import tomllib
except ModuleNotFoundError:  # py<3.11
    import tomli as tomllib  # type: ignore

ROOT = os.environ.get("PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NUMERIC = ("double", "number", "float")


def _settings(manifest):
    """Every declared setting, plugin-level and entry-level, as (origin, dict)."""
    out = [("[[setting]]", s) for s in manifest.get("setting", [])]
    for kind in ("widget", "desktop_widget", "panel", "service", "launcher"):
        for entry in manifest.get(kind, []):
            for s in entry.get("setting", []):
                out.append((f"[[{kind}.setting]] {entry.get('id', '?')}", s))
    return out


class Manifest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(os.path.join(ROOT, "plugin.toml"), "rb") as fh:
            cls.manifest = tomllib.load(fh)
        cls.settings = _settings(cls.manifest)

    def test_has_settings(self):
        self.assertTrue(self.settings, "expected at least one declared setting")

    def test_every_numeric_declares_explicit_step(self):
        """The regression guard. An omitted step means 1.0, not 'continuous'."""
        for origin, s in self.settings:
            if s.get("type") in NUMERIC:
                with self.subTest(setting=s.get("key"), origin=origin):
                    self.assertIn(
                        "step", s,
                        f"{s.get('key')} ({origin}) is type={s.get('type')} with no explicit "
                        "step; the parser would default it to 1.0 and snap the slider",
                    )

    def test_step_is_positive(self):
        """step <= 0 is a hard parse error in noctalia (rejects the whole manifest)."""
        for origin, s in self.settings:
            if "step" in s:
                with self.subTest(setting=s.get("key"), origin=origin):
                    self.assertGreater(s["step"], 0, f"{s.get('key')} step must be > 0")

    def test_step_is_finer_than_range(self):
        """A step >= the span leaves only the two clamped endpoints reachable."""
        for origin, s in self.settings:
            if "step" in s and "min" in s and "max" in s:
                with self.subTest(setting=s.get("key"), origin=origin):
                    span = s["max"] - s["min"]
                    self.assertLess(
                        s["step"], span,
                        f"{s.get('key')} step {s['step']} is not finer than its range {span}",
                    )

    def test_default_lands_on_a_step_boundary(self):
        """Otherwise the shipped default is a value the slider cannot return to."""
        for origin, s in self.settings:
            if {"step", "min", "default"} <= s.keys() and s.get("type") in NUMERIC:
                with self.subTest(setting=s.get("key"), origin=origin):
                    steps = (s["default"] - s["min"]) / s["step"]
                    self.assertAlmostEqual(
                        steps, round(steps), places=6,
                        msg=f"{s.get('key')} default {s['default']} is not an integer number "
                            f"of {s['step']} steps from min {s['min']}",
                    )

    def test_default_within_range(self):
        for origin, s in self.settings:
            if {"min", "max", "default"} <= s.keys():
                with self.subTest(setting=s.get("key"), origin=origin):
                    self.assertGreaterEqual(s["default"], s["min"])
                    self.assertLessEqual(s["default"], s["max"])

    def test_label_and_description_use_key_form(self):
        """Raw `label`/`description` are REJECTED by the parser; only *_key works."""
        for origin, s in self.settings:
            with self.subTest(setting=s.get("key"), origin=origin):
                self.assertNotIn("label", s, f"{s.get('key')}: use label_key, not label")
                self.assertNotIn("description", s, f"{s.get('key')}: use description_key")
                self.assertIn("label_key", s, f"{s.get('key')} is missing label_key")


class Translations(unittest.TestCase):
    """Every *_key must resolve in translations/en.json, or the UI shows a raw key."""

    @classmethod
    def setUpClass(cls):
        import json
        with open(os.path.join(ROOT, "plugin.toml"), "rb") as fh:
            cls.settings = _settings(tomllib.load(fh))
        with open(os.path.join(ROOT, "translations", "en.json"), encoding="utf-8") as fh:
            cls.en = json.load(fh)

    def _resolve(self, dotted):
        node = self.en
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return None
            node = node[part]
        return node

    def test_every_key_resolves(self):
        for origin, s in self.settings:
            for field in ("label_key", "description_key"):
                if field in s:
                    with self.subTest(setting=s.get("key"), field=field, origin=origin):
                        self.assertIsInstance(
                            self._resolve(s[field]), str,
                            f"{s[field]} does not resolve to a string in translations/en.json",
                        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
