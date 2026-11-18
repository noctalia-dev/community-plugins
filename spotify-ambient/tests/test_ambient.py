import json
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path

from PIL import Image, ImageStat

from ambient import render, generate_palette, generate_and_apply_palette


class PaletteApplyTests(unittest.TestCase):
    def test_palette_generation_and_application_share_one_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            destination = root / "palette.json"
            lock_path = root / "palette.lock"
            completed = SimpleNamespace(returncode=0, stdout="", stderr="")
            with patch("ambient.generate_palette") as generate, patch(
                "ambient.subprocess.run", return_value=completed
            ) as run:
                generate_and_apply_palette(
                    "file:///tmp/cover.png", destination, "SpotifyAmbientDynamic-test", lock_path
                )

            generate.assert_called_once_with("file:///tmp/cover.png", destination)
            run.assert_called_once_with(
                [
                    "noctalia", "msg", "color-scheme-set",
                    "custom", "SpotifyAmbientDynamic-test",
                ],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            self.assertTrue(lock_path.is_file())

    def test_palette_apply_does_not_change_theme_when_generation_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch("ambient.generate_palette", side_effect=RuntimeError("generation failed")), patch(
                "ambient.subprocess.run"
            ) as run:
                with self.assertRaisesRegex(RuntimeError, "generation failed"):
                    generate_and_apply_palette(
                        "file:///tmp/cover.png",
                        root / "palette.json",
                        "SpotifyAmbientDynamic-test",
                        root / "palette.lock",
                    )
            run.assert_not_called()


class AmbientRenderTests(unittest.TestCase):
    def render_temp(self, image):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        source = Path(tmp.name) / "source.png"
        output = Path(tmp.name) / "output.jpg"
        image.save(source)
        render(source.as_uri(), 1280, 720, output)
        return output

    def test_renders_exact_output_dimensions(self):
        output = self.render_temp(Image.new("RGB", (640, 640), (120, 40, 200)))
        with Image.open(output) as result:
            self.assertEqual(result.size, (1280, 720))
            self.assertEqual(result.format, "JPEG")

    def test_monochrome_art_gets_ambient_colour(self):
        art = Image.new("RGB", (640, 640), (0, 0, 0))
        for y in range(640):
            shade = int(35 + 210 * y / 639)
            for x in range(640):
                art.putpixel((x, y), (shade, shade, shade))
        output = self.render_temp(art)
        with Image.open(output) as result:
            mean_sat = ImageStat.Stat(result.convert("HSV")).mean[1]
            self.assertGreater(mean_sat, 18)
            mean_value = ImageStat.Stat(result.convert("HSV")).mean[2]
            self.assertGreater(mean_value, 35)

    def test_blur_radius_is_reduced_but_still_atmospheric(self):
        from ambient import BLUR_FRACTION, MIN_BLUR_RADIUS
        radius = max(MIN_BLUR_RADIUS, round(min(1920, 1080) * BLUR_FRACTION))
        self.assertEqual(radius, 49)
        self.assertLess(BLUR_FRACTION, 0.065)
        self.assertGreater(BLUR_FRACTION, 0.03)

    def test_highlights_are_capped(self):
        output = self.render_temp(Image.new("RGB", (640, 640), (255, 255, 255)))
        with Image.open(output) as result:
            self.assertLess(max(result.getextrema()[i][1] for i in range(3)), 100)

    def test_colourful_art_keeps_its_chroma(self):
        art = Image.new("RGB", (640, 640), (190, 25, 35))
        for x in range(320, 640):
            for y in range(640):
                art.putpixel((x, y), (20, 95, 190))
        output = self.render_temp(art)
        with Image.open(output) as result:
            mean_sat = ImageStat.Stat(result.convert("HSV")).mean[1]
            self.assertGreater(mean_sat, 75)

    def test_oversized_image_is_rejected_before_pixel_decode(self):
        import ambient

        class OversizedImage:
            width = 10_000
            height = 10_000

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def load(self):
                raise AssertionError("pixel data must not be decoded")

        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "oversized.png"
            source.write_bytes(b"not decoded by the mocked opener")
            opened = OversizedImage()
            with patch("ambient.Image.open", return_value=opened):
                with self.assertRaisesRegex(ValueError, "pixel safety limit"):
                    ambient.load_artwork(source.as_uri())

    def test_file_uri_rejects_remote_authority(self):
        import ambient
        with self.assertRaisesRegex(ValueError, "local machine"):
            ambient.load_artwork("file://remote-host/tmp/cover.png")


    def test_http_artwork_rejects_loopback_addresses(self):
        import ambient
        with self.assertRaisesRegex(ValueError, "public IP addresses"):
            ambient._validate_artwork_http_url("http://127.0.0.1/cover.png")

    def test_http_artwork_rejects_private_dns_results(self):
        import ambient
        private_result = [
            (2, 1, 6, "", ("10.0.0.12", 443))
        ]
        with patch("ambient.socket.getaddrinfo", return_value=private_result):
            with self.assertRaisesRegex(ValueError, "public IP addresses"):
                ambient._validate_artwork_http_url("https://art.example/cover.png")

    def test_http_redirect_rejects_loopback_target(self):
        from urllib.request import Request
        from ambient import _SafeArtworkRedirectHandler
        handler = _SafeArtworkRedirectHandler()
        request = Request("https://art.example/cover.png")
        with self.assertRaisesRegex(ValueError, "public IP addresses"):
            handler.redirect_request(
                request, None, 302, "Found", {}, "http://127.0.0.1/internal"
            )


def ambient_hls_lightness(colour):
    import colorsys
    rgb = tuple(int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return colorsys.rgb_to_hls(*rgb)[1]


class PaletteGenerationTests(unittest.TestCase):
    def _palette(self, image):
        from ambient import build_noctalia_palette
        return build_noctalia_palette(image)["dark"]

    def _contrast(self, first, second):
        from ambient import _contrast_ratio
        return _contrast_ratio(first, second)

    def test_white_cover_still_generates_dark_surfaces(self):
        palette = self._palette(Image.new("RGB", (512, 512), (255, 255, 255)))
        self.assertLessEqual(max(int(palette["mSurface"][i:i+2], 16) for i in (1, 3, 5)), 40)
        self.assertGreater(self._contrast("#ffffff", palette["mSurface"]), 12.0)
        self.assertEqual(palette["terminal"]["background"], palette["mSurface"])

    def test_generated_role_text_has_wcag_contrast(self):
        palette = self._palette(Image.new("RGB", (512, 512), (246, 246, 246)))
        pairs = [
            ("mOnPrimary", "mPrimary"),
            ("mOnSecondary", "mSecondary"),
            ("mOnTertiary", "mTertiary"),
            ("mOnError", "mError"),
            ("mOnSurface", "mSurface"),
            ("mOnSurfaceVariant", "mSurfaceVariant"),
            ("mOnHover", "mHover"),
        ]
        for foreground, background in pairs:
            with self.subTest(pair=(foreground, background)):
                self.assertGreaterEqual(self._contrast(palette[foreground], palette[background]), 4.5)

    def test_palette_has_all_legacy_noctalia_roles(self):
        palette = self._palette(Image.new("RGB", (512, 512), (20, 120, 220)))
        expected = {
            "mPrimary", "mOnPrimary", "mSecondary", "mOnSecondary", "mTertiary", "mOnTertiary",
            "mError", "mOnError", "mSurface", "mOnSurface", "mSurfaceVariant", "mOnSurfaceVariant",
            "mOutline", "mShadow", "mHover", "mOnHover", "terminal",
        }
        self.assertEqual(set(palette), expected)
        self.assertEqual(set(palette["terminal"]["normal"]), {
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"
        })
        self.assertEqual(set(palette["terminal"]["bright"]), set(palette["terminal"]["normal"]))

    def test_coloured_cover_influences_primary_hue(self):
        from ambient import _extract_palette_colours
        art = Image.new("RGB", (512, 512), (16, 80, 205))
        palette = self._palette(art)
        # Source blue should remain recognisable as the primary hue.
        self.assertGreater(self._contrast(palette["mOnPrimary"], palette["mPrimary"]), 4.5)
        self.assertNotEqual(palette["mPrimary"], "#6f5bd3")

    def test_different_album_hues_produce_different_primary_accents(self):
        warm = self._palette(Image.new("RGB", (256, 256), (180, 80, 25)))
        teal = self._palette(Image.new("RGB", (256, 256), (20, 140, 145)))
        self.assertNotEqual(warm["mPrimary"], teal["mPrimary"])
        self.assertNotEqual(warm["mHover"], teal["mHover"])

    def test_accent_surfaces_are_muted_and_use_light_foregrounds(self):
        palette = self._palette(Image.new("RGB", (512, 512), (255, 255, 255)))
        pairs = [
            ("mPrimary", "mOnPrimary"),
            ("mSecondary", "mOnSecondary"),
            ("mTertiary", "mOnTertiary"),
            ("mError", "mOnError"),
        ]
        for background_key, foreground_key in pairs:
            background = palette[background_key]
            foreground = palette[foreground_key]
            with self.subTest(role=background_key):
                self.assertEqual(foreground, "#e9edf5")
                self.assertGreaterEqual(self._contrast(foreground, background), 4.5)
                # Prevent bright/pastel accents from being derived from light art.
                self.assertLess(ambient_hls_lightness(background), 0.51)


    def _noctalia_token_fixture(self):
        roles = (
            "primary", "on_primary", "secondary", "on_secondary", "tertiary", "on_tertiary",
            "error", "on_error", "surface", "on_surface", "surface_container", "on_surface_variant",
            "outline_variant", "shadow", "hover", "on_hover",
        )
        tokens = {key: "#223344" for key in roles}
        tokens.update({
            "terminal_background": "#101318",
            "terminal_foreground": "#e2e6ef",
            "terminal_cursor": "#77aadd",
            "terminal_cursor_text": "#101318",
            "terminal_selection_fg": "#101318",
            "terminal_selection_bg": "#77aadd",
        })
        for group in ("normal", "bright"):
            for index, name in enumerate(("black", "red", "green", "yellow", "blue", "magenta", "cyan", "white")):
                tokens[f"terminal_{group}_{name}"] = f"#{index + 1:02x}2233"
        return tokens

    def test_noctalia_token_map_rejects_malformed_hex_values(self):
        from ambient import palette_from_noctalia_tokens
        tokens = self._noctalia_token_fixture()
        tokens["primary"] = "#12GG56"
        with self.assertRaisesRegex(ValueError, "primary"):
            palette_from_noctalia_tokens(tokens, mode="dark")

    def test_noctalia_token_map_rejects_non_object_json(self):
        from ambient import palette_from_noctalia_tokens
        with self.assertRaisesRegex(ValueError, "JSON object"):
            palette_from_noctalia_tokens([], mode="dark")

    def test_noctalia_token_map_converts_to_v2_custom_palette(self):
        from ambient import palette_from_noctalia_tokens
        dark = palette_from_noctalia_tokens(self._noctalia_token_fixture(), mode="dark")
        light = palette_from_noctalia_tokens(self._noctalia_token_fixture(), mode="light")
        self.assertNotEqual(dark["primary"], "#223344")
        self.assertEqual(dark["surface"], "#223344")
        self.assertEqual(light["primary"], "#223344")
        self.assertEqual(dark["terminal"]["background"], "#101318")
        self.assertEqual(dark["terminal"]["normal"]["green"], "#032233")
        self.assertEqual(set(dark["terminal"]["bright"]), {
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"
        })
        self.assertGreaterEqual(self._contrast(dark["on_primary"], dark["primary"]), 4.5)

    def test_native_palette_generation_invokes_noctalia_on_original_cover(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "cover.png"
            destination = Path(tmp) / "palettes" / "SpotifyAmbient.json"
            Image.new("RGB", (128, 128), (255, 255, 255)).save(source)
            commands = []

            def fake_run(command, **kwargs):
                commands.append(command)
                output_path = Path(command[command.index("-o") + 1])
                tokens = self._noctalia_token_fixture()
                if "--light" in command:
                    tokens["surface"] = "#f4f1ec"
                    tokens["on_surface"] = "#211b17"
                output_path.write_text(json.dumps(tokens), encoding="utf-8")
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with patch("ambient.subprocess.run", side_effect=fake_run):
                palette = generate_palette(source.as_uri(), destination, scheme="m3-content")

            on_disk = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(on_disk, palette)
            self.assertEqual(on_disk["version"], 2)
            self.assertEqual(len(commands), 2)
            self.assertEqual(set(on_disk), {"version", "dark", "light"})
            self.assertEqual(on_disk["dark"]["surface"], "#223344")
            self.assertEqual(on_disk["light"]["surface"], "#f4f1ec")
            self.assertTrue(any("--dark" in command for command in commands))
            self.assertTrue(any("--light" in command for command in commands))
            for command in commands:
                self.assertEqual(command[0:2], ["noctalia", "theme"])
                self.assertIn("--scheme", command)
                self.assertEqual(command[command.index("--scheme") + 1], "m3-content")
                self.assertEqual(command[command.index("--terminal-colors") + 1], "palette")
            from ambient import save_palette_preview
            preview = Path(tmp) / "preview.png"
            preview_light = Path(tmp) / "preview-light.png"
            save_palette_preview(on_disk, preview)
            save_palette_preview(on_disk, preview_light, mode="light")
            self.assertTrue(preview.is_file())
            self.assertTrue(preview_light.is_file())

    def test_terminal_colour_tokens_are_visible_on_dark_background(self):
        palette = self._palette(Image.new("RGB", (512, 512), (255, 255, 255)))
        background = palette["terminal"]["background"]
        for group in ("normal", "bright"):
            for name, colour in palette["terminal"][group].items():
                if name == "black":
                    continue
                with self.subTest(group=group, colour=name):
                    self.assertGreaterEqual(self._contrast(colour, background), 4.5)

    def test_terminal_ansi_hues_follow_album_art_instead_of_fixed_green(self):
        import colorsys
        warm = Image.new("RGB", (512, 512), (190, 82, 28))
        palette = self._palette(warm)
        green_slot = palette["terminal"]["normal"]["green"]
        rgb = tuple(int(green_slot[i:i + 2], 16) / 255 for i in (1, 3, 5))
        hue, _, saturation = colorsys.rgb_to_hls(*rgb)
        self.assertGreater(saturation, 0.25)
        # The warm cover should not force the ANSI green slot to canonical green.
        self.assertGreater(min((hue - 0.34) % 1.0, (0.34 - hue) % 1.0), 0.08)

    def test_monochrome_terminal_palette_uses_styled_fallback_not_neon_green(self):
        import colorsys
        palette = self._palette(Image.new("RGB", (512, 512), (180, 180, 180)))
        green_slot = palette["terminal"]["normal"]["green"]
        rgb = tuple(int(green_slot[i:i + 2], 16) / 255 for i in (1, 3, 5))
        hue, _, saturation = colorsys.rgb_to_hls(*rgb)
        self.assertGreater(saturation, 0.25)
        self.assertGreater(min((hue - 0.34) % 1.0, (0.34 - hue) % 1.0), 0.08)


class DiagnosticReportTests(unittest.TestCase):
    def test_report_does_not_include_track_or_artwork_metadata(self):
        from ambient import collect_diagnostics

        def fake_which(command):
            return f"/usr/bin/{command}" if command in {"playerctl", "noctalia"} else None

        def fake_run(argv, **kwargs):
            if argv[0].endswith("playerctl") and argv[1:] == ["-l"]:
                return SimpleNamespace(returncode=0, stdout="spotify\n", stderr="")
            if argv[0].endswith("playerctl") and argv[1:] == ["-p", "spotify", "status"]:
                return SimpleNamespace(returncode=0, stdout="Playing\n", stderr="")
            if argv[0].endswith("noctalia") and argv[1:] == ["msg", "color-scheme-get"]:
                return SimpleNamespace(returncode=0, stdout="wallpaper m3-content\n", stderr="")
            if argv[0].endswith("noctalia") and argv[1:] == ["theme", "--help"]:
                return SimpleNamespace(returncode=0, stdout="--terminal-colors STYLE", stderr="")
            self.fail(f"Unexpected diagnostic command: {argv}")

        with patch("ambient.shutil.which", side_effect=fake_which), patch("ambient.subprocess.run", side_effect=fake_run):
            report = collect_diagnostics()

        self.assertEqual(report["plugin_version"], "0.4.2")
        self.assertIn("spotify_mpris", {item["name"] for item in report["checks"]})
        serialized = json.dumps(report)
        self.assertNotIn("https://", serialized)
        self.assertNotIn("Never Gonna Give You Up", serialized)
        self.assertNotIn("https://i.scdn.co/", serialized)

    def test_diagnostic_command_reports_missing_executable(self):
        from ambient import _run_diagnostic_command
        ok, detail = _run_diagnostic_command(["this-command-should-not-exist-spotify-ambient"])
        self.assertFalse(ok)
        self.assertIn("command not found", detail)


if __name__ == "__main__":
    unittest.main()
