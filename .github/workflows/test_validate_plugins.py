from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


VALIDATOR_PATH = Path(__file__).with_name("validate-plugins.py")
SPEC = importlib.util.spec_from_file_location("validate_plugins", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
validate_plugins = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validate_plugins)


class LauncherPrefixTests(unittest.TestCase):
    def validate_prefix(self, prefix: str) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"))
        validator.validate_launcher_fields(
            Path("/repo/example/plugin.toml"),
            "launcher_provider[0]",
            {"prefix": prefix},
        )
        return validator.errors

    def test_accepts_lowercase_ascii_letters(self) -> None:
        self.assertEqual(self.validate_prefix("bla"), [])

    def test_rejects_leading_symbol(self) -> None:
        self.assertNotEqual(self.validate_prefix("/bla"), [])

    def test_rejects_uppercase_letters(self) -> None:
        self.assertNotEqual(self.validate_prefix("Bla"), [])

    def test_rejects_digits(self) -> None:
        self.assertNotEqual(self.validate_prefix("bla2"), [])

    def test_rejects_other_symbols(self) -> None:
        self.assertNotEqual(self.validate_prefix("bla-bla"), [])


class AllowedTagsTests(unittest.TestCase):
    def validate_tags(self, tags: object) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"))
        validator.validate_tags(Path("/repo/example/plugin.toml"), tags)
        return validator.errors

    def test_accepts_every_allowed_tag(self) -> None:
        self.assertEqual(self.validate_tags(sorted(validate_plugins.ALLOWED_TAGS)), [])

    def test_rejects_unknown_tag(self) -> None:
        self.assertEqual(
            self.validate_tags(["utility", "unknown"]),
            [
                "example/plugin.toml: root: "
                "tags[1] 'unknown' is not an allowed tag"
            ],
        )

    def test_rejects_wrong_case(self) -> None:
        self.assertNotEqual(self.validate_tags(["Utility"]), [])

    def test_retains_string_list_validation(self) -> None:
        errors = self.validate_tags(["utility", "utility", ""])
        self.assertTrue(any("duplicate 'utility'" in error for error in errors))
        self.assertTrue(any("tags[2] must be a non-empty string" in error for error in errors))


class DescriptionTests(unittest.TestCase):
    def validate_description(self, description: object) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"))
        validator.validate_description(Path("/repo/example/plugin.toml"), description)
        return validator.errors

    def test_accepts_description_at_limit(self) -> None:
        self.assertEqual(
            self.validate_description("x" * validate_plugins.DESCRIPTION_MAX_CHARS),
            [],
        )

    def test_rejects_description_over_limit(self) -> None:
        errors = self.validate_description(
            "x" * (validate_plugins.DESCRIPTION_MAX_CHARS + 1)
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("is 121 characters", errors[0])
        self.assertIn("at or below 120", errors[0])


class PluginConfigAccessorTests(unittest.TestCase):
    def test_accepts_universal_accessor(self) -> None:
        self.assertEqual(
            validate_plugins.obsolete_config_accessors('local value = noctalia.getConfig("key")'),
            [],
        )

    def test_rejects_every_entry_specific_alias(self) -> None:
        source = "\n".join(
            [
                'barWidget.getConfig("one")',
                'desktopWidget.getConfig("two")',
                'panel . getConfig("three")',
                'launcher.getConfig("four")',
            ]
        )
        self.assertEqual(
            validate_plugins.obsolete_config_accessors(source),
            [
                ("barWidget.getConfig", 1),
                ("desktopWidget.getConfig", 2),
                ("panel.getConfig", 3),
                ("launcher.getConfig", 4),
            ],
        )

    def test_ignores_comments_and_strings(self) -> None:
        source = "\n".join(
            [
                '-- barWidget.getConfig("comment")',
                '--[[ panel.getConfig("block comment") ]]',
                'local text = "launcher.getConfig(\\\"string\\\")"',
                'local block = [[desktopWidget.getConfig("long string")]]',
            ]
        )
        self.assertEqual(validate_plugins.obsolete_config_accessors(source), [])


class TranslationKeyTests(unittest.TestCase):
    def test_accepts_valid_keys(self) -> None:
        for key in (
            "settings.translation_language.label",
            "settings.translation_language.options.zh-hans",
            "settings.translation_language.options.en",
            "a.b-c.d_e.f0",
        ):
            with self.subTest(key=key):
                self.assertTrue(validate_plugins.is_valid_translation_key(key))

    def test_rejects_invalid_keys(self) -> None:
        for key in (
            "settings.options.zh-Hans",  # uppercase segment
            "settings.options.zh-Hant",
            "settings.Label",
            "settings._leading",  # leading underscore in a segment
            "settings..options",  # empty segment
            "",
        ):
            with self.subTest(key=key):
                self.assertFalse(validate_plugins.is_valid_translation_key(key))

    def test_rejects_dotted_json_object_keys(self) -> None:
        # A flat dotted key is what the i18n platform expands into nested objects; the JSON
        # source must nest instead, so an object key with a dot is invalid.
        self.assertFalse(validate_plugins.is_valid_key_segment("settings.label"))
        self.assertTrue(validate_plugins.is_valid_key_segment("eyecare-active-duration"))
        translations = {"settings.eyecare-active-duration.label": "Active Duration"}
        self.assertEqual(
            validate_plugins.invalid_translation_keys(translations),
            ["settings.eyecare-active-duration.label"],
        )

    def test_walks_nested_keys_and_reports_full_paths(self) -> None:
        translations = {
            "settings": {
                "translation_language": {
                    "options": {"zh-Hans": "Simplified", "zh-Hant": "Traditional", "en": "English"}
                }
            }
        }
        self.assertEqual(
            validate_plugins.invalid_translation_keys(translations),
            [
                "settings.translation_language.options.zh-Hans",
                "settings.translation_language.options.zh-Hant",
            ],
        )

    def validate_keys(self, translations: object) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            plugin_dir = Path(directory) / "example"
            plugin_dir.mkdir()
            validator = validate_plugins.Validator(Path(directory))
            validator.validate_translation_keys(plugin_dir, translations)
            return validator.errors

    def test_reports_bad_json_keys_without_a_reference(self) -> None:
        errors = self.validate_keys({"settings": {"options": {"zh-Hans": "Simplified"}}})
        self.assertEqual(len(errors), 1)
        self.assertIn("settings.options.zh-Hans", errors[0])
        self.assertIn("invalid translation key format", errors[0])

    def test_accepts_valid_json_keys(self) -> None:
        self.assertEqual(self.validate_keys({"settings": {"options": {"zh-hans": "Simplified"}}}), [])

    def validate_reference(self, label_key: object) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"))
        validator.validate_translation_key(
            Path("/repo/example/plugin.toml"),
            {label_key: "x"} if isinstance(label_key, str) else {},
            "setting[0]",
            "label_key",
            label_key,
        )
        return validator.errors

    def test_rejects_badly_formatted_reference(self) -> None:
        errors = self.validate_reference("settings.options.zh-Hans")
        self.assertEqual(len(errors), 1)
        self.assertIn("is not a valid translation key", errors[0])

    def test_accepts_well_formatted_existing_reference(self) -> None:
        self.assertEqual(self.validate_reference("settings.options.zh-hans"), [])


class ReadmeTests(unittest.TestCase):
    MANIFEST = {
        "id": "me/example",
        "dependencies": ["example-cli"],
        "setting": [{"key": "interval"}],
        "widget": [{"id": "widget", "entry": "widget.luau"}],
        "panel": [{"id": "panel", "entry": "panel.luau"}],
        "launcher_provider": [
            {"id": "search", "entry": "launcher.luau", "prefix": "ex"}
        ],
    }

    VALID_README = """# Example

Example provides a useful widget, panel, and launcher for demonstration purposes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `me/example` |
| Entries | Widget: `widget`; panel: `panel`; launcher: `search` |
| Launcher Prefix | `/ex` |

## Requirements

Install `example-cli` on `PATH`.

## Usage

Add the widget, type `/ex`, or open the panel:

```sh
noctalia msg panel-toggle me/example:panel
```

## Settings

Configure the update interval in plugin settings.
"""

    def validate_readme(self, contents: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin_dir = root / "example"
            plugin_dir.mkdir()
            (plugin_dir / "README.md").write_text(contents, encoding="utf-8")
            validator = validate_plugins.Validator(root)
            validator.validate_readme(plugin_dir, self.MANIFEST)
            return validator.errors

    def test_accepts_official_plugin_readme_structure(self) -> None:
        self.assertEqual(self.validate_readme(self.VALID_README), [])

    def test_requires_core_sections_and_intro(self) -> None:
        errors = self.validate_readme("# Example\n\nToo short.\n")
        self.assertTrue(any("short introduction" in error for error in errors))
        self.assertTrue(any("## Plugin" in error for error in errors))
        self.assertTrue(any("## Usage" in error for error in errors))

    def test_headings_inside_code_fences_do_not_satisfy_sections(self) -> None:
        errors = self.validate_readme(
            "# Example\n\nA sufficiently descriptive introduction for this example plugin.\n\n"
            "```md\n## Plugin\n## Usage\n```\n"
        )
        self.assertTrue(any("## Plugin" in error for error in errors))
        self.assertTrue(any("## Usage" in error for error in errors))

    def test_derives_documented_values_from_manifest(self) -> None:
        readme = self.VALID_README
        replacements = {
            "`me/example`": "`me/wrong`",
            "`widget`": "`other-widget`",
            "noctalia msg panel-toggle me/example:panel": "noctalia msg panel-toggle me/example:wrong",
            "`/ex`": "`/wrong`",
            "`example-cli`": "`other-cli`",
        }
        for old, new in replacements.items():
            with self.subTest(missing=old):
                errors = self.validate_readme(readme.replace(old, new))
                self.assertTrue(errors)

    def test_requires_conditional_sections(self) -> None:
        without_requirements = self.VALID_README.replace(
            "## Requirements\n\nInstall `example-cli` on `PATH`.\n\n", ""
        )
        without_settings = self.VALID_README.replace(
            "## Settings\n\nConfigure the update interval in plugin settings.\n", ""
        )
        self.assertTrue(
            any("## Requirements" in error for error in self.validate_readme(without_requirements))
        )
        self.assertTrue(any("## Settings" in error for error in self.validate_readme(without_settings)))


class SettingUsageTests(unittest.TestCase):
    """plugin.toml and the Luau sources must agree on which settings exist."""

    def validate(self, manifest: dict, sources: dict[str, str]) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin_dir = root / "example"
            plugin_dir.mkdir()
            for name, contents in sources.items():
                path = plugin_dir / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")
            validator = validate_plugins.Validator(root)
            validator.validate_setting_usage(plugin_dir / "plugin.toml", plugin_dir, manifest)
            return validator.errors

    def test_accepts_matching_manifest_and_source(self) -> None:
        manifest = {"setting": [{"key": "interval"}, {"key": "notify"}]}
        source = 'local a = noctalia.getConfig("interval")\nlocal b = noctalia.getConfig("notify")\n'
        self.assertEqual(self.validate(manifest, {"main.luau": source}), [])

    def test_rejects_reading_an_undeclared_setting(self) -> None:
        manifest = {"setting": [{"key": "interval"}]}
        source = 'local a = noctalia.getConfig("interval")\nlocal b = noctalia.getConfig("intervl")\n'
        errors = self.validate(manifest, {"main.luau": source})
        self.assertTrue(any("intervl" in error for error in errors))

    def test_rejects_a_declared_setting_nothing_reads(self) -> None:
        manifest = {"setting": [{"key": "interval"}, {"key": "orphan"}]}
        source = 'local a = noctalia.getConfig("interval")\n'
        errors = self.validate(manifest, {"main.luau": source})
        self.assertTrue(any("orphan" in error for error in errors))

    def test_collects_entry_level_settings(self) -> None:
        manifest = {"widget": [{"id": "w", "entry": "w.luau", "setting": [{"key": "bar_width"}]}]}
        source = 'local w = noctalia.getConfig("bar_width")\n'
        self.assertEqual(self.validate(manifest, {"w.luau": source}), [])

    def test_reads_across_multiple_sources(self) -> None:
        manifest = {"setting": [{"key": "a"}, {"key": "b"}]}
        sources = {"one.luau": 'noctalia.getConfig("a")\n', "two.luau": 'noctalia.getConfig("b")\n'}
        self.assertEqual(self.validate(manifest, sources), [])

    def test_ignores_getconfig_inside_comments(self) -> None:
        manifest = {"setting": [{"key": "interval"}]}
        source = 'noctalia.getConfig("interval")\n-- noctalia.getConfig("ghost")\n'
        self.assertEqual(self.validate(manifest, {"main.luau": source}), [])

    def test_ignores_getconfig_inside_block_comments(self) -> None:
        manifest = {"setting": [{"key": "interval"}]}
        source = 'noctalia.getConfig("interval")\n--[[ noctalia.getConfig("ghost") ]]\n'
        self.assertEqual(self.validate(manifest, {"main.luau": source}), [])

    def test_skips_unused_check_when_a_key_is_dynamic(self) -> None:
        # A key read through a variable cannot be seen, so "declared but unread" would be a
        # false positive. The undeclared-read check still applies.
        manifest = {"setting": [{"key": "interval"}, {"key": "maybe_used"}]}
        source = 'local k = "interval"\nnoctalia.getConfig(k)\n'
        self.assertEqual(self.validate(manifest, {"main.luau": source}), [])

    def test_still_flags_undeclared_reads_when_a_key_is_dynamic(self) -> None:
        manifest = {"setting": [{"key": "interval"}]}
        source = 'noctalia.getConfig(k)\nnoctalia.getConfig("ghost")\n'
        errors = self.validate(manifest, {"main.luau": source})
        self.assertTrue(any("ghost" in error for error in errors))

    def test_accepts_a_plugin_with_no_settings(self) -> None:
        self.assertEqual(self.validate({}, {"main.luau": "local x = 1\n"}), [])


if __name__ == "__main__":
    unittest.main()
