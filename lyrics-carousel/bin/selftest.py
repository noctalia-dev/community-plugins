#!/usr/bin/env python3
"""Self-test for the Lyrics Carousel plugin.

Checks the assumptions about the installation environment, which are the root
cause of the most annoying failures: the script may be launched through a
symbolic link (in which case its sibling modules and the helper are not in
the same directory), the data directory may not exist, and external tools may
be missing.

Usage:  python3 bin/selftest.py [--verbose]
Returns 1 if anything fails.

The self-test leaves no trace: it does not import the script (that would
write bytecode into the directory it is launched from), it runs it as a
process with --diagnostics.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import types
from contextlib import contextmanager

# Loading the script with SourceFileLoader (script_module) would write
# bin/__pycache__/*.pyc: the self-test must not leave traces in the plugin.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_DIR = os.path.dirname(HERE)
HELPER = os.path.join(HERE, "set-setting.py")
SCRIPT = os.path.join(HERE, "lyrics-carousel")
DATA_DIR = os.path.expanduser(
    "~/.local/state/noctalia/plugins/data/faminec/lyrics-carousel"
)
# Where it is actually launched from: the PATH symlink.
LAUNCHER = os.path.expanduser("~/.local/bin/lyrics-carousel")

results = []


def pixels(image):
    """Pixels of an image, without the method Pillow is going to remove."""
    if hasattr(image, "get_flattened_data"):
        return image.get_flattened_data()
    return list(image.getdata())


def check(name: str, ok: bool, detail: str = ""):
    results.append((name, ok, detail))
    return ok


@contextmanager
def temporary_env(values):
    """Applies environment variables only for the duration of the block.

    Tests must not touch the real state: the lyrics cache, settings.toml and
    the overrides are redirected to a temporary directory.
    """
    previous = dict(os.environ)
    try:
        os.environ.update(values)
        yield
    finally:
        os.environ.clear()
        os.environ.update(previous)


@contextmanager
def temporary_state(base: str):
    """Temporary Noctalia state for the current process.

    Replaces every variable that may point to the real state, not just
    XDG_STATE_HOME: paths.py prioritizes LYRICS_CAROUSEL_STATE and
    NOCTALIA_STATE_HOME, so with those defined the script would read (and
    write) the real settings.

    Returns the path of the state directory (<base>/.local/state/noctalia).
    """
    previous = dict(os.environ)
    state_value = os.path.join(base, ".local", "state")
    destination = os.path.join(state_value, "noctalia")
    os.makedirs(destination, exist_ok=True)
    os.environ["XDG_STATE_HOME"] = state_value
    os.environ["NOCTALIA_STATE_HOME"] = state_value
    os.environ["LYRICS_CAROUSEL_STATE"] = destination
    os.environ["LYRICS_CAROUSEL_OVERRIDES"] = os.path.join(
        destination,
        "plugins",
        "data",
        "faminec",
        "lyrics-carousel",
        "overrides.json",
    )
    try:
        yield destination
    finally:
        os.environ.clear()
        os.environ.update(previous)


def script_module():
    """Loads the script as a module so its individual functions can be tested.

    The script has no .py extension, so it is loaded with SourceFileLoader.
    The module name is not "__main__": loading the script does not run it.
    """
    loader = importlib.machinery.SourceFileLoader("lyrics_carousel_mod", SCRIPT)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def read_settings(file_path: str) -> dict:
    """Plugin settings from a settings.toml (empty if it cannot be read)."""
    try:
        import tomllib

        with open(file_path, "rb") as handle:
            data = tomllib.load(handle)
    except Exception:  # noqa: BLE001
        return {}
    section = (data.get("plugin_settings") or {}).get("faminec/lyrics-carousel")
    return section if isinstance(section, dict) else {}


def wait_for_setting(file_path: str, setting_key: str, setting_value, segundos: float = 10.0) -> bool:
    """Waits for the script to store a setting in settings.toml.

    The script writes in the background (the helper runs in a separate
    process), so the value does not appear right away: wait a little.
    """
    deadline = time.monotonic() + segundos
    while time.monotonic() < deadline:
        if read_settings(file_path).get(setting_key) == setting_value:
            return True
        time.sleep(0.2)
    return False


# visualizer_module() removed - visualizer feature removed

def run_script(path: str, cwd: str = "/"):
    """Runs the script with --diagnostics and returns the JSON."""
    process = subprocess.run(
        [sys.executable, path, "--diagnostics"],
        capture_output=True,
        text=True,
        timeout=30,
        cwd=cwd,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    if process.returncode != 0:
        raise RuntimeError(
            f"output {process.returncode}: {process.stderr.strip()[:200]}"
        )
    return json.loads(process.stdout)


def check_diagnostics(label: str, path: str):
    """Checks that the script finds its modules and its helper."""
    try:
        info = run_script(path)
    except Exception as error:  # noqa: BLE001
        check(f"diagnostics ({label})", False, repr(error)[:160])
        return None
    # What it has to resolve is the real directory of that script (the
    # symlink points to the deployment, not to the repo).
    expected = os.path.dirname(os.path.realpath(path))
    check(
        f"diagnostics ({label})",
        info.get("bin_dir") == expected,
        f"bin_dir={info.get('bin_dir')} expected={expected}",
    )
    check(
        f"sibling modules ({label})",
        bool(info.get("image_renderer")) and bool(info.get("graphics")),
        info.get("image_error") or "",
    )
    check(
        f"helper located ({label})",
        bool(info.get("helper_exists")),
        info.get("helper") or "",
    )
    return info


def check_shortcuts():
    """The 'd' and 'k' shortcuts toggle their settings and really store them.

    Everything happens in a temporary directory (test environment): the
    script writes to settings.toml and to the overrides, and the test must
    not touch the user's real state nor compete with the script's
    asynchronous write.
    """
    temporary = tempfile.mkdtemp(prefix="lyrics-carousel-selftest-")
    state_value = os.path.join(temporary, ".local", "state")
    cache = os.path.join(temporary, ".cache")
    settings_file = os.path.join(state_value, "noctalia", "settings.toml")
    os.makedirs(os.path.dirname(settings_file), exist_ok=True)
    os.makedirs(cache, exist_ok=True)
    with open(settings_file, "w", encoding="utf-8") as handle:
        handle.write("")
    environment = test_environment(temporary)
    log = os.path.join(cache, "lyrics-carousel", "debug.log")
    try:
        import fcntl
        import pty
        import select
        import signal
        import struct
        import termios

        pid, fd = pty.fork()
        if pid == 0:
            os.chdir("/")
            os.execvpe(
                "python3",
                [
                    "python3",
                    os.path.join(HERE, "lyrics-carousel"),
                    "--demo",
                    "--debug",
                ],
                environment,
            )
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 90, 0, 0))
        time.sleep(2.5)
        os.write(fd, b"d")
        time.sleep(1.5)
        os.write(fd, b"k")
        time.sleep(1.5)
        os.write(fd, b"r")
        time.sleep(2.5)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.close(fd)
    except Exception as error:  # noqa: BLE001
        check("the 'd' shortcut saves the direction", False, repr(error)[:120])
        check("the 'k' shortcut saves the karaoke", False, repr(error)[:120])
        shutil.rmtree(temporary, ignore_errors=True)
        return
    try:
        # The value has to end up in settings.toml: if it only stays in the
        # overrides layer, the user loses it when restarting.
        ok = wait_for_setting(settings_file, "direction", "up")
        check(
            "the 'd' shortcut saves the direction",
            ok,
            "expected up, got %s" % (read_settings(settings_file).get("direction"),),
        )
        ok_k = wait_for_setting(settings_file, "karaoke", False)
        check(
            "the 'k' shortcut saves the karaoke",
            ok_k,
            "expected false, got %s" % (read_settings(settings_file).get("karaoke"),),
        )
        # Demo mode is self-contained: neither at startup nor on reload ('r')
        # may it fetch lyrics from the internet.
        requests = []
        written = ""
        if os.path.isfile(log):
            try:
                with open(log, encoding="utf-8", errors="replace") as handle:
                    written = handle.read()
                requests = [
                    lyric_line
                    for lyric_line in written.split("\n")
                    if any(
                        marker in lyric_line.lower()
                        for marker in ("http", "kugou", "splayer", "netease", "lrclib")
                    )
                ]
            except OSError:
                written = ""
        # The guard only works if the script wrote its debug log: requests
        # to the providers are only recorded with --debug, so without it the
        # log would always look clean.
        # Look for a line that only shows up with debugging enabled.
        debug_output = any(
            marker in written
            for marker in ("demo: ", "mode: ", "settings: ", "result: ")
        )
        check(
            "the script log allows checking it",
            debug_output,
            ""
            if debug_output
            else "the script did not write its debug log",
        )
        check(
            "the demo mode does not request lyrics from the internet",
            not requests,
            "; ".join(requests[:2]),
        )
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def check_scroll_offset():
    """The scroll uses the position with the offset applied.

    The highlight already used position() (with the offset) but the scroll
    used the raw position: with a non-zero offset_ms the highlighted line was
    not the one in the center.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.args = types.SimpleNamespace(once=True, debug=False)
            app.cfg = dict(mod.DEFAULTS)
            app.cfg["offset_ms"] = 500
            app.demo = False
            app.track = mod.Track("cancion", "artista", duration=300.0, status="Playing")
            app.track.position = 10.0
            app.track.stamp = time.monotonic()
            app.stop_requested = False
            app.output_broken = False
            app.lines = []
            positions = []
            app._poll_data = lambda: None
            app.update_size = lambda: None
            app.draw = lambda force=False: None
            app._read_keys = lambda: []
            app._setup_terminal = lambda interactive: None
            app._restore_terminal = lambda interactive: None
            app._update_scroll = lambda position: positions.append(position)
            app.run()
            expected = app.position()
            ok = bool(positions) and abs(positions[0] - expected) < 0.05
            check(
                "the offset is applied to the scroll",
                ok,
                "scroll=%s expected=%s" % (positions[:1], round(expected, 3)),
            )


def check_lyrics_search():
    """The search waits 15 s and does not mark the negative cache on timeout."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            check(
                "the lyrics search timeout is 15 s",
                getattr(mod, "SEARCH_TIMEOUT", None) == 15.0,
                "SEARCH_TIMEOUT=%s" % (getattr(mod, "SEARCH_TIMEOUT", None),),
            )
            mod.load_lyrics_settings = lambda: {"sources": ["lrclib"]}
            marked_tracks = []
            mod.mark_missing = lambda track: marked_tracks.append(track)
            track = mod.Track("cancion", "artista", duration=120.0)

            # A provider that does not answer: the deadline expires and the
            # negative cache is NOT marked (the lyrics may arrive later).
            mod.SEARCH_TIMEOUT = 0.4

            def slow(track, log):
                time.sleep(3.0)
                return [], None

            mod.fetch_lrclib = slow
            mod.fetch_lyrics(track, True, lambda message: None)
            check(
                "a search that exhausts the timeout does not mark the negative cache",
                not marked_tracks,
                "marked %d" % len(marked_tracks),
            )

            # All the providers finish without lyrics: the negative cache
            # is marked (retrying the same song every 60 s makes no
            # sense).
            marked_tracks.clear()
            mod.SEARCH_TIMEOUT = 5.0
            mod.fetch_lrclib = lambda track, log: ([], None)
            mod.fetch_lyrics(track, True, lambda message: None)
            check(
                "a search that ends without lyrics marks the negative cache",
                len(marked_tracks) == 1,
                "marked %d" % len(marked_tracks),
            )


def check_lyrics_retry():
    """An empty lyric is retried after 60 s (not after 180)."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            check(
                "the retry for empty lyrics is 60 s",
                getattr(mod, "RETRY_SECONDS", None) == 60,
                "RETRY_SECONDS=%s" % (getattr(mod, "RETRY_SECONDS", None),),
            )
            app = object.__new__(mod.LyricsCarousel)
            app.args = types.SimpleNamespace(debug=False)
            app.demo = False
            app._player = None
            app.state = "empty"
            app.track = mod.Track("cancion", "artista")
            app.last_cfg = time.monotonic()
            app.last_reload = time.monotonic()
            app.theme = mod.Theme()
            start_calls = []

            class FakeFetcher:
                def take(self):
                    return None

                def start(self, track, force=False):
                    start_calls.append(force)

            app.fetcher = FakeFetcher()
            app.last_fetch = time.monotonic() - 61
            app._poll_data()
            check(
                "empty lyrics are retried after 60 s",
                len(start_calls) == 1,
                "starts=%s" % (start_calls,),
            )
            start_calls.clear()
            app.last_fetch = time.monotonic() - 10
            app._poll_data()
            check(
                "empty lyrics are not retried before 60 s",
                not start_calls,
                "starts=%s" % (start_calls,),
            )


def osc66_blocks(lyric_line):
    """Extracts the OSC 66 blocks from a row: (metadata, text)."""
    pattern = re.compile("\x1b\\]66;([^;]*);([^\x07]*)\x07")
    return pattern.findall(lyric_line)


def visible_text(lyric_line):
    """Strips the control sequences from a row and leaves the text.

    The text of the OSC 66 blocks travels inside the sequence, so only the
    payload is recovered from them.
    """
    lyric_line = re.sub("\x1b\\]66;[^;]*;([^\x07]*)\x07", r"\1", lyric_line)
    return re.sub("\x1b\\][^\x07]*\x07|\x1b\\[[0-9;]*m", "", lyric_line)


def osc66_metadata(metadatos):
    """Converts 's=2:n=6:d=10:w=7' into a dictionary."""
    data = {}
    for part in metadatos.split(":"):
        if "=" in part:
            setting_key, setting_value = part.split("=", 1)
            data[setting_key] = setting_value
    return data


def factor_osc66(data):
    """Size factor that kitty computes from that metadata.

    Kitty multiplies the font size by s and then reduces it by the n/d
    fraction. With s=1 and n/d=2/10 the text comes out at 20% of its size.
    """
    scale_factor = int(data.get("s", 1))
    numerator = int(data.get("n", 0))
    denominator = int(data.get("d", 0))
    if numerator and denominator:
        return scale_factor * numerator / denominator
    return float(scale_factor)


def image_module():
    """Loads image_renderer to test the layout of the lines."""
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import image_renderer

    return image_renderer


def check_image_layout():
    """The layout of image mode is symmetric and does not overlap blocks.

    In "down" the upcoming lines enter from the top and the past ones leave
    through the bottom; in "up" it is the other way around. An inverted sign
    pulls the neighbours inside the active block and the spacing stops being uniform.
    """
    mod = image_module()

    class App:
        pass

    for direction in ("down", "up"):
        app = App()
        app.cfg = {
            "visible_above": 2,
            "visible_below": 2,
            "direction": direction,
            "spacing": 3,
        }
        renderer = mod.ImageRenderer(app)
        center = 400.0
        size = 20.0
        scale = 1.2
        pos = renderer._layout(5, center, size, scale)
        small_h = size * 1.32
        big_h = size * scale * 1.32
        gap = size * 0.30 * 3
        time_step = big_h / 2 + gap + small_h / 2

        check(
            "the image layout draws the five lines",
            sorted(pos) == [3, 4, 5, 6, 7],
            repr(sorted(pos)),
        )
        check(
            "the image layout centers the active line",
            pos.get(5) == center,
            repr(pos.get(5)),
        )
        check(
            "the image layout leaves the same gap on both sides",
            abs(abs(pos.get(6, 0) - center) - abs(pos.get(4, 0) - center)) < 1e-6,
            "top=%.2f bottom=%.2f" % (pos.get(6, 0), pos.get(4, 0)),
        )
        check(
            "the image layout separates the neighbours from the active block",
            abs(pos.get(6, 0) - center) >= time_step - 1e-6
            and abs(pos.get(4, 0) - center) >= time_step - 1e-6,
            "step=%.2f actual=%.2f/%.2f"
            % (time_step, abs(pos.get(6, 0) - center), abs(pos.get(4, 0) - center)),
        )
        if direction == "down":
            check(
                "in down the future lines go above",
                pos[7] < pos[6] < center < pos[4] < pos[3],
                repr({k: round(v, 1) for k, v in pos.items()}),
            )
        else:
            check(
                "in up the future lines go below",
                pos[3] < pos[4] < center < pos[6] < pos[7],
                repr({k: round(v, 1) for k, v in pos.items()}),
            )


def check_karaoke_image_pixel_by_pixel():
    """The image karaoke is filled at pixel level and with decimals.

    `_draw_karaoke` receives the sung characters with decimals. The edge of
    the fill is interpolated inside the glyph in progress, so a given instant
    lights up a piece of a letter instead of jumping to a whole word: that
    is what made it look like it recognised the speed of the song.
    """
    mod = image_module()
    if mod.Image is None:
        check("the image karaoke can be measured (Pillow)", False, "without Pillow")
        return

    text = "cantando suave la linea"
    sung = (0, 200, 0)
    pending = (0, 90, 0)

    def measure(amount):
        image = mod.Image.new("RGBA", (1500, 90), (0, 0, 0, 0))
        brush = mod.ImageDraw.Draw(image)
        renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
        renderer.fonts = {}
        renderer.font_files = {"prueba": mod.FALLBACK_FONT}
        renderer._draw_karaoke(
            brush, text, 45, 20, sung, pending, amount, "prueba"
        )
        data = pixels(image)
        return sum(1 for px in data if px[0] == sung[0] and px[1] == sung[1])

    def measure_pending(amount):
        image = mod.Image.new("RGBA", (1500, 90), (0, 0, 0, 0))
        brush = mod.ImageDraw.Draw(image)
        renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
        renderer.fonts = {}
        renderer.font_files = {"prueba": mod.FALLBACK_FONT}
        renderer._draw_karaoke(
            brush, text, 45, 20, sung, pending, amount, "prueba"
        )
        data = pixels(image)
        # Only the visible ink: with the softened edge of the fill, the last
        # glyph leaves a leftover alpha of 2/255 (invisible) on its
        # antialiased border.
        return sum(
            1 for px in data if px[1] == pending[1] and px[3] >= 16
        )

    total = len(text)
    check(
        "without singing there are no sung pixels",
        measure(0.0) == 0,
        repr(measure(0.0)),
    )

    middle_value = measure(total / 2)
    check(
        "at the middle of the line half is sung",
        measure(0.0) < middle_value < measure(float(total)),
        "middle=%s" % (middle_value,),
    )
    check(
        "at the end nothing is left pending",
        measure_pending(float(total)) == 0,
        repr(measure_pending(float(total))),
    )

    # The fill is finer than one character: half a glyph lights up a small
    # piece, not the whole next letter.
    integer_jump = measure(7.0) - measure(6.0)
    half_jump = measure(6.5) - measure(6.0)
    check(
        "half a character lights less than a whole one",
        0 < half_jump < integer_jump,
        "half=%s whole=%s" % (half_jump, integer_jump),
    )
    check(
        "the fill keeps growing inside the same character",
        measure(6.25) >= measure(6.0) and measure(6.75) >= measure(6.5),
        "%s %s" % (measure(6.25), measure(6.75)),
    )


def check_karaoke_image_follows_the_times():
    """The image karaoke uses per-character timings, like the text one.

    If the adapter provides per-character timings, the fill respects them:
    with characters of 0.2 s each, at 0.5 s two and a half are done.
    Previously the duration of the whole line was spread evenly, so every
    word lit up at the same rate and the line lost its beat.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            image = image_module()
            text = "hola mundo feliz"
            line = mod.LyricLine(0.0, 6.0, text)
            line.chars = [round(index * 0.2, 3) for index in range(len(text))]

            class FakeTheme:
                background = (10, 10, 10)
                foreground = (200, 200, 200)
                past = (120, 120, 120)

            class FakeBrush:
                # ImageDraw is not used: what the render queries is enough.
                im = types.SimpleNamespace(size=(1500, 900))

                def textlength(self, text, font=None):
                    return len(text) * 12.0

            app = types.SimpleNamespace()
            app.cfg = {
                "karaoke": True,
                "marker": False,
                "ghost": False,
                "direction": "down",
                "spacing": 3,
                "visible_above": 2,
                "visible_below": 2,
            }
            app.state = "lyrics"
            app.lines = [line]
            app.track = mod.Track()
            app.theme = FakeTheme()
            app.karaoke = True
            app.demo = False
            app.position = lambda: 0.5
            app.next_timed_start = lambda index: None
            # The real methods, hooked onto the test object: this way the
            # test checks the real calculation, not a copy of it.
            app.scroll_state = types.MethodType(mod.LyricsCarousel.scroll_state, app)
            app._timed_lines = types.MethodType(mod.LyricsCarousel._timed_lines, app)
            app.karaoke_amount = types.MethodType(
                mod.LyricsCarousel.karaoke_amount, app
            )

            renderer = image.ImageRenderer.__new__(image.ImageRenderer)
            renderer.app = app
            renderer.fonts = {}
            renderer.font_files = {"prueba": image.FALLBACK_FONT}
            renderer._measure_draw = FakeBrush()
            views = []
            renderer._draw_karaoke = lambda *args: views.append(args)

            renderer._draw_lyrics(
                FakeBrush(), 450.0, 20.0, 1.2, "prueba", (0, 200, 0), 0.5, 0, 900
            )

            check(
                "the image render draws the karaoke of the active line",
                len(views) == 1,
                "calls=%s" % (len(views),),
            )
            if len(views) == 1:
                amount = views[0][6]
                check(
                    "the advance has decimals (continuous fill)",
                    abs(amount - round(amount)) > 1e-6,
                    "amount=%r" % (amount,),
                )
                check(
                    "the advance respects the per-character timings",
                    abs(amount - 2.5) < 0.02,
                    "amount=%r" % (amount,),
                )


def check_real_transition():
    """ghost enables the smooth transition; when off, the change is instant.

    With `ghost` the duration is fixed (~0.9 s) and is clipped to 80 % of the
    gap up to the next line. Without `ghost` there is no animation: the
    carousel jumps from one line to the next the moment it starts.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.cfg = dict(mod.DEFAULTS)
            app.cfg["ghost"] = True
            app.lines = [
                mod.LyricLine(0.0, 0.0, "uno"),
                mod.LyricLine(4.0, 0.0, "dos"),
                mod.LyricLine(8.0, 0.0, "tres"),
            ]

            # Starts 0.9 s early: halfway through the transition, progress 0.5.
            index, focus, progress = app.scroll_state(3.55)
            check(
                "the smooth transition lasts as expected",
                index == 0 and focus == 1 and abs(progress - 0.5) < 1e-6,
                "index=%s focus=%s progress=%.4f" % (index, focus, progress),
            )
            check(
                "the curve starts slowly",
                0.0 < app.scroll_state(3.325)[2] < 0.20,
                "progress=%.4f" % app.scroll_state(3.325)[2],
            )
            check(
                "the curve ends slowly",
                app.scroll_state(3.95)[2] > 0.95,
                "progress=%.4f" % app.scroll_state(3.95)[2],
            )

            # If the next line arrives before 0.9 s, the transition is
            # clipped to 80 % of the gap so it does not overlap the next one.
            app.lines = [
                mod.LyricLine(0.0, 0.0, "uno"),
                mod.LyricLine(0.5, 0.0, "dos"),
            ]
            index, focus, progress = app.scroll_state(0.2)
            check(
                "the transition is clipped if the lyrics go fast",
                focus == 1 and 0.0 < progress < 0.20,
                "focus=%s progress=%.4f" % (focus, progress),
            )

            # Without the smooth transition there is no progress: the change is abrupt.
            app.lines = [
                mod.LyricLine(0.0, 0.0, "uno"),
                mod.LyricLine(4.0, 0.0, "dos"),
                mod.LyricLine(8.0, 0.0, "tres"),
            ]
            app.cfg["ghost"] = False
            index, focus, progress = app.scroll_state(3.55)
            check(
                "without ghost the change is instant",
                index == 0 and focus == 0 and progress == 0.0,
                "index=%s focus=%s progress=%.4f" % (index, focus, progress),
            )
            check(
                "without ghost the line changes right on time",
                app.scroll_state(4.0)[0] == 1,
                "index=%s" % (app.scroll_state(4.0)[0],),
            )


# --- handover test scene ------------------------------------------------

SCENE_BACKGROUND = (12, 12, 18)
SCENE_WHITE = (240, 240, 245)
SCENE_PAST = (110, 110, 120)
SCENE_RED = (220, 60, 60)
SCENE_SIZE = 20.0
SCENE_SCALE = 1.6


class _SceneTheme:
    background = SCENE_BACKGROUND
    foreground = SCENE_WHITE
    past = SCENE_PAST


class _SceneLine:
    def __init__(self, text):
        self.text = text
        self.start = 0.0
        self.duration = 4.0
        self.chars = []


def render_handover(
    mod,
    progress,
    texts,
    state_value=None,
    karaoke=False,
    direction="down",
    amount=999.0,
):
    """Draws the carousel with the given lines and returns the image.

    `state_value` is the (index, focus, progress) tuple returned by
    `scroll_state`; by default line 1 is the main one and line 2 the one about
    to take its place. `amount` is the number of sung characters (with karaoke).
    """
    class App:
        pass

    app = App()
    app.theme = _SceneTheme()
    app.cfg = {
        "visible_above": 2,
        "visible_below": 2,
        "direction": direction,
        "spacing": 3,
        "marker": False,
        "karaoke": karaoke,
    }
    app.lines = [_SceneLine(text) for text in texts]
    app.karaoke = karaoke
    app.next_timed_start = lambda indice: None
    app.karaoke_amount = lambda *args: amount if karaoke else 0.0
    app.scroll_state = lambda scroll_position: state_value or (1, 2, progress)
    renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
    renderer.app = app
    renderer.fonts = {}
    renderer.font_files = {"prueba": mod.FALLBACK_FONT}
    image = mod.Image.new("RGBA", (900, 800), (0, 0, 0, 0))
    brush = mod.ImageDraw.Draw(image)
    renderer._measure_draw = brush
    renderer._draw_lyrics(
        brush,
        400.0,
        SCENE_SIZE,
        SCENE_SCALE,
        "prueba",
        SCENE_RED,
        0.0,
        60.0,
        740.0,
    )
    return image


def text_height(image):
    """Height of the drawn text (0 if there is none)."""
    box = image.getbbox()
    return 0 if box is None else box[3] - box[1]


def opaque_color(image):
    """RGB of the most opaque glyph (the color it was painted with)."""
    box = image.getbbox()
    if box is None:
        return (0, 0, 0)
    region = image.crop(box)
    colors = region.getcolors(maxcolors=200000) or []
    if not colors:
        return (0, 0, 0)
    cuenta, pixel = max(colors, key=lambda par: par[1][3])
    return pixel[:3]


def distance(one, other):
    return sum((one[i] - other[i]) ** 2 for i in range(3)) ** 0.5


def glow(color):
    """Perceived luminance of a color (to see whether it darkens)."""
    return 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2]


def check_smooth_visual_transition():
    """The ghost transition is visible: gradual size and crossing colors.

    What is measured is the real render (pixels), not the intermediate calculations:
      * the line that is about to become the main one grows from 1.0 to
        `active_scale` continuously (several intermediate sizes, not a jump);
      * that line enters in white and ends in the main color;
      * the line that stops being the main one leaves in the main color and
        ends in the color of the already sung lines.
    """
    mod = image_module()
    if mod.Image is None:
        check("the visual transition can be measured (Pillow)", False, "without Pillow")
        return

    BACKGROUND = SCENE_BACKGROUND
    WHITE = SCENE_WHITE
    PAST = SCENE_PAST
    RED = SCENE_RED
    SIZE = SCENE_SIZE
    SCALE = SCENE_SCALE

    def render(progress, texts, state_value=None, karaoke=False, direction="down"):
        """Draws the carousel with a single line of text and returns the image."""
        return render_handover(
            mod,
            progress,
            texts,
            state_value=state_value,
            karaoke=karaoke,
            direction=direction,
        )

    height = text_height

    entering = ["", "", "ENTRANTE", "", ""]
    leaving = ["", "SALIENTE", "", ""]

    # -- size: the incoming line grows from 1.0 to `scale`, without jumps.
    heights = [height(render(p, entering)) for p in (0.25, 0.5, 0.75, 1.0)]
    check(
        "the incoming line grows continuously",
        len(set(heights)) == 4 and heights[0] < heights[1] < heights[2] < heights[3],
        repr(heights),
    )
    check(
        "the incoming line reaches the main size",
        heights[-1] > heights[0] * 1.25,
        "heights=%r" % (heights,),
    )

    # -- size: the outgoing line shrinks from `scale` to 1.0 (it must not break).
    output_heights = [height(render(p, leaving)) for p in (0.0, 0.25, 0.5, 0.75, 1.0)]
    check(
        "the outgoing line shrinks continuously",
        output_heights[0] > output_heights[1] > output_heights[2] > output_heights[3]
        and output_heights[4] <= output_heights[3],
        repr(output_heights),
    )

    # -- color of the incoming line: white -> main color.
    start_value = opaque_color(render(0.15, entering))
    check(
        "the incoming line starts in white",
        distance(start_value, WHITE) < distance(start_value, RED),
        "color=%r" % (start_value,),
    )
    end_value = opaque_color(render(1.0, entering))
    check(
        "the incoming line ends in the main colour",
        distance(end_value, RED) < 12,
        "color=%r" % (end_value,),
    )

    # -- color of the outgoing line: main color -> color of the sung lines.
    output_start = opaque_color(render(0.0, leaving))
    check(
        "the outgoing line starts in the main colour",
        distance(output_start, RED) < 12,
        "color=%r" % (output_start,),
    )
    output_end = opaque_color(render(1.0, leaving))
    check(
        "the outgoing line ends in the colour of the already sung ones",
        distance(output_end, PAST) < 45
        and distance(output_end, RED) > 60,
        "color=%r" % (output_end,),
    )

    # -- the incoming line does not flicker: before and at the start of the transition it looks the same.
    before = render(0.0, entering, state_value=(1, 1, 0.0))
    check(
        "the incoming line does not flicker when the transition starts",
        height(before) > 0 and height(render(0.0, entering)) > 0,
        "before=%r after=%r" % (height(before), height(render(0.0, entering))),
    )

    # -- with karaoke (the default mode) the outgoing line also changes color.
    karaoke_start = opaque_color(render(0.0, leaving, karaoke=True))
    karaoke_end = opaque_color(render(1.0, leaving, karaoke=True))
    check(
        "with karaoke the outgoing line goes from the main colour to the sung one",
        distance(karaoke_start, RED) < distance(karaoke_start, WHITE)
        and distance(karaoke_end, PAST) < 45
        and distance(karaoke_end, RED) > 60,
        "start=%r end=%r" % (karaoke_start, karaoke_end),
    )

    # -- in the "up" direction the handover is the same, but going up.
    for sentido in ("up",):
        heights_up = [height(render(p, entering, direction=sentido)) for p in (0.25, 0.5, 0.75, 1.0)]
        up_color = opaque_color(render(1.0, entering, direction=sentido))
        output_up_color = opaque_color(render(1.0, leaving, direction=sentido))
        check(
            "in up direction the incoming line grows and ends in the main colour",
            heights_up[0] < heights_up[1] < heights_up[2] < heights_up[3]
            and distance(up_color, RED) < 12,
            "heights=%r color=%r" % (heights_up, up_color),
        )
        check(
            "in up direction the outgoing line ends in the colour of the sung ones",
            distance(output_up_color, PAST) < 45
            and distance(output_up_color, RED) > 60,
            "color=%r" % (output_up_color,),
        )


def check_karaoke_entry_without_jump():
    """With karaoke the incoming line already reaches the dim tone: the handover does not jump.

    Without karaoke the main line is drawn in a single color (the accent) and the
    handover has no jump. With karaoke it is drawn in two tones: the sung part in
    the accent and what is missing in a dim red. The incoming line used to reach
    the accent, so when it became the main one it darkened all of a sudden.

    With the darkening in the transition, the incoming line drops from the level
    the following lines have down to that dim tone, and the handover stays
    continuous.
    """
    mod = image_module()
    if mod.Image is None:
        check("the karaoke handover can be measured (Pillow)", False, "without Pillow")
        return

    bg_color = SCENE_BACKGROUND
    red = SCENE_RED
    # The dim tone of what has not been sung yet: the same 45 % of the
    # accent over the background that the karaoke path uses.
    off_color = tuple(
        int(bg_color[i] + (red[i] - bg_color[i]) * 0.45) for i in range(3)
    )

    entering = ["", "", "ENTRANTE", "", ""]
    primary_color = ["", "CANTO", "", "", ""]

    # The incoming line, at the end of the transition, with the tone the
    # main line will have while what is missing has not been sung yet.
    end_value = opaque_color(render_handover(mod, 1.0, entering, karaoke=True))
    check(
        "with karaoke the incoming line reaches the dim tone of what is pending",
        distance(end_value, off_color) < 12,
        "color=%r expected=%r" % (end_value, off_color),
    )

    # It is exactly the same tone the main line has: switching from one to
    # the other produces no color jump.
    primary_tone = opaque_color(
        render_handover(
            mod,
            0.0,
            primary_color,
            state_value=(1, 1, 0.0),
            karaoke=True,
            amount=0.0,
        )
    )
    check(
        "the incoming line and the main line have the same tone",
        distance(end_value, primary_tone) < 6,
        "incoming=%r main=%r" % (end_value, primary_tone),
    )

    # The darkening is gradual: halfway through, the incoming line is
    # already closer to the dim tone than it is without karaoke.
    karaoke_half = opaque_color(render_handover(mod, 0.5, entering, karaoke=True))
    half_without = opaque_color(render_handover(mod, 0.5, entering, karaoke=False))
    check(
        "with karaoke the incoming line darkens gradually",
        distance(karaoke_half, off_color) < distance(half_without, off_color),
        "with=%r without=%r off=%r" % (karaoke_half, half_without, off_color),
    )

    # And the darkening is not noticeable as a step: each segment is a
    # little darker than the previous one.
    segments = [
        opaque_color(render_handover(mod, p, entering, karaoke=True))
        for p in (0.25, 0.5, 0.75, 1.0)
    ]
    glows = [glow(color) for color in segments]
    check(
        "the incoming line darkens continuously",
        all(glows[i] > glows[i + 1] for i in range(len(glows) - 1)),
        "glows=%r" % ([round(b, 1) for b in glows],),
    )

    # Without karaoke nothing changes: the incoming line still ends in the accent.
    end_without = opaque_color(render_handover(mod, 1.0, entering, karaoke=False))
    check(
        "without karaoke the incoming line still ends in the main colour",
        distance(end_without, red) < 12,
        "color=%r" % (end_without,),
    )


def check_frame_rhythm():
    """The loop really beats at 60 fps: the deadline runs from the frame start.

    Sleeping the whole interval AFTER the work made the real cycle be
    `work + interval`: 36 fps instead of 60, and with that the carousel
    looked stuttery.
    """
    mod = script_module()
    remainder = mod.remainder_for_next_frame
    interval = 1.0 / 60.0

    check(
        "the deadline is counted from the frame start",
        abs(remainder(0.0, 0.008, interval) - (interval - 0.008)) < 1e-9,
        repr(remainder(0.0, 0.008, interval)),
    )
    check(
        "an on-time frame sleeps what is left",
        abs(remainder(0.0, 0.0, interval) - interval) < 1e-9,
        repr(remainder(0.0, 0.0, interval)),
    )
    check(
        "a late frame does not sleep",
        remainder(0.0, 0.05, interval) == 0.0,
        repr(remainder(0.0, 0.05, interval)),
    )
    check(
        "the remainder is never negative",
        remainder(10.0, 20.0, interval) == 0.0,
        repr(remainder(10.0, 20.0, interval)),
    )
    check(
        "the real fps are measured between frames",
        abs(mod.real_fps(180, 3.0) - 60.0) < 1e-9
        and mod.real_fps(0, 1.0) == 0.0
        and mod.real_fps(60, 0.0) == 0.0,
        repr((mod.real_fps(180, 3.0), mod.real_fps(0, 1.0))),
    )


def check_karaoke_without_glow():
    """The karaoke is the glow of the letters, with no blurred shadow around.

    Before, the sung line was drawn twice: the crisp one and a blurred copy
    (the halo). That halo was a shadow that also cost 3.2 ms per frame (the
    GaussianBlur) and made the carousel drop below 60 fps.
    """
    mod = image_module()
    if mod.Image is None:
        check("the karaoke without glow can be measured (Pillow)", False, "without Pillow")
        return

    text = "cantando"
    image = mod.Image.new("RGBA", (600, 90), (0, 0, 0, 0))
    brush = mod.ImageDraw.Draw(image)
    renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
    renderer.fonts = {}
    renderer.font_files = {"prueba": mod.FALLBACK_FONT}
    renderer._draw_karaoke(
        brush, text, 45, 20, (0, 200, 0), (0, 90, 0), float(len(text)), "prueba"
    )

    # The text is drawn centered: the box starts at the same x.
    font = renderer.font("prueba", 20)
    x = (image.size[0] - brush.textlength(text, font=font)) / 2
    box = brush.textbbox((x, 45), text, font=font, anchor="lm")
    # Outside the text box (with 2 px of tolerance for the antialiasing
    # of the glyph itself) not a single pixel may remain: that is where the halo used to live.
    outside = 0
    for indice, px in enumerate(pixels(image)):
        if px[3] == 0:
            continue
        px_x = indice % image.size[0]
        px_y = indice // image.size[0]
        if (
            px_x < box[0] - 2
            or px_x > box[2] + 2
            or px_y < box[1] - 2
            or px_y > box[3] + 2
        ):
            outside += 1
    check(
        "the karaoke leaves no shadow around the lyrics",
        outside == 0,
        "pixels outside=%d" % outside,
    )
    check(
        "the sung lyrics stay painted",
        sum(1 for px in pixels(image) if px[1] == 200 and px[3] == 255) > 0,
    )


def check_fractional_size():
    """The size of the letters is continuous: it does not step in whole pixels.

    With the integer cache, the growing line jumped by 1 px every few frames
    and that was noticeable as a small staircase.
    """
    mod = image_module()
    if mod.Image is None:
        check("the fractional size can be measured (Pillow)", False, "without Pillow")
        return

    renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
    renderer.fonts = {}
    renderer.font_files = {"prueba": mod.FALLBACK_FONT}
    image = mod.Image.new("RGBA", (600, 90), (0, 0, 0, 0))
    brush = mod.ImageDraw.Draw(image)

    def glyph_width(tam):
        return brush.textlength("Hola", font=renderer.font("prueba", tam))

    # 25.1 and 25.4 with the integer cache fell into the same font (25):
    # the letters could not grow continuously.
    a, b = glyph_width(25.1), glyph_width(25.4)
    check(
        "the size of the letters is continuous, not stepped",
        abs(a - b) > 0.5,
        "width=%.2f/%.2f" % (a, b),
    )
    check(
        "the cache distinguishes different sizes",
        renderer.font("prueba", 25.1) is not renderer.font("prueba", 25.4),
    )
    check(
        "the cache reuses the same size",
        renderer.font("prueba", 25.1) is renderer.font("prueba", 25.12),
    )


def check_smooth_curve():
    """The handover curve has no acceleration at the extremes.

    With smoothstep the velocity reached zero but the acceleration jumped
    when starting and when braking: that showed up as a micro-stutter in the
    carousel. The smootherstep (6t5-15t4+10t3) leaves the acceleration at
    zero at the extremes as well.
    """
    mod = script_module()
    curve = mod.ease_in_out
    h = 1e-3

    def second(t):
        return (curve(t + h) - 2 * curve(t) + curve(t - h)) / (h * h)

    check(
        "the curve goes from 0 to 1",
        curve(0.0) == 0.0 and curve(1.0) == 1.0,
        "start=%r end=%r" % (curve(0.0), curve(1.0)),
    )
    check(
        "the curve has no acceleration at the extremes",
        abs(second(0.0)) < 0.05 and abs(second(1.0)) < 0.05,
        "start=%.3f end=%.3f" % (second(0.0), second(1.0)),
    )
    check(
        "the curve is monotonic",
        all(curve(i / 20.0) <= curve((i + 1) / 20.0) for i in range(20)),
    )
    check(
        "the curve stays within range",
        all(0.0 <= curve(v / 40.0) <= 1.0 for v in range(-10, 51)),
    )
    check(
        "the curve keeps half at the midpoint",
        abs(curve(0.5) - 0.5) < 1e-9,
        "midpoint=%r" % (curve(0.5),),
    )


def check_first_window_fps():
    """The first statistics window does not report 0 fps.

    The log measures the real fps between frames: the window starts with the
    first frame drawn. If the start of the window is taken at the moment of
    logging, the first line always comes out with 0 fps and it looks like
    the plugin stutters when it actually runs at 60.
    """
    mod = script_module()
    app = mod.LyricsCarousel.__new__(mod.LyricsCarousel)
    lyric_lines = []
    app.warn = lambda message: lyric_lines.append(message)
    # A minimal but measurable draw: if the clock did not advance, the frame
    # counter would not move and the test would fail for the wrong reason.
    app.draw_image = lambda force=False: time.sleep(0.0002)
    app._draw_accum = 0
    app._draw_frames = 0

    for _ in range(180):
        app.draw()

    numbers = []
    if lyric_lines:
        numbers = re.findall(r"(\d+(?:\.\d+)?) real fps", lyric_lines[0])
    check(
        "the first fps window is not zero",
        bool(numbers) and float(numbers[0]) > 0.0,
        "line=%r" % (lyric_lines[:1],),
    )


def check_karaoke_smooth_edge():
    """The edge of the fill fades out: there is no cut with what is missing.

    The alpha ramp at the end of the fill has to go in the right direction:
    the sung color fades towards the limit and blends with what has not been
    sung yet. With the ramp reversed the red ended abruptly (a vertical wall
    of light) and the last character was left half
    lit.
    """
    mod = image_module()
    if mod.Image is None:
        check("the edge of the fill can be measured (Pillow)", False, "without Pillow")
        return

    BACKGROUND = (31, 31, 31)
    SUNG = (229, 57, 53)
    PENDING = (120, 42, 40)
    # The cut falls inside the fourth M: that way the ramp is applied over
    # the letter and not in a gap between words.
    text = "MMMMMMMM"

    renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
    renderer.fonts = {}
    renderer.font_files = {"prueba": mod.FALLBACK_FONT}
    image = mod.Image.new("RGBA", (900, 120), BACKGROUND + (255,))
    brush = mod.ImageDraw.Draw(image)
    renderer._draw_karaoke(
        brush, text, 60, 40.0, SUNG, PENDING, 3.5, "prueba"
    )

    # Per column, the further from the pending tone, the more sung it is.
    saturation = {}
    for indice, px in enumerate(pixels(image)):
        if px[3] != 255:
            continue
        color = px[:3]
        if color == BACKGROUND:
            continue
        setting_value = distance(color, PENDING) - distance(color, SUNG)
        x = indice % image.size[0]
        saturation[x] = max(saturation.get(x, 0), setting_value)

    sung_lines = {x: v for x, v in saturation.items() if v > 0}
    check(
        "the fill has a sung zone",
        bool(sung_lines),
        "columns=%d" % (len(sung_lines),),
    )
    if sung_lines:
        first = min(sung_lines)
        last = max(sung_lines)
        check(
            "the edge of the fill fades towards the limit",
            sung_lines[last] < sung_lines[first],
            "first=%r last=%r" % (sung_lines[first], sung_lines[last]),
        )


def check_handover_without_alpha_jump():
    """When the main line changes, opacity is not lost all of a sudden.

    The karaoke path always painted the text opaque, while the normal path
    paints it with the alpha of the distance to the center. At the moment of
    the handover the outgoing line went from opaque to semi-transparent from
    one frame to the next: a flicker exactly where the change has to be
    invisible.
    """
    mod = image_module()
    if mod.Image is None:
        check("the handover alpha can be measured (Pillow)", False, "without Pillow")
        return

    leaving = ["", "SALIENTE", "", "", ""]
    # The last frame of the transition and the first one after the change:
    # the outgoing line is in the same place in both, only the path it is
    # drawn with changes.
    before = render_handover(
        mod, 1.0, leaving, state_value=(1, 2, 1.0), karaoke=True, amount=0.0
    )
    after = render_handover(
        mod, 0.0, leaving, state_value=(2, 2, 0.0), karaoke=True, amount=0.0
    )

    def max_alpha(image):
        return max((px[3] for px in pixels(image)), default=0)

    alpha_before = max_alpha(before)
    alpha_after = max_alpha(after)
    check(
        "the outgoing line does not lose opacity in the handover",
        abs(alpha_before - alpha_after) <= 1,
        "before=%d after=%d" % (alpha_before, alpha_after),
    )


def check_sung_text_is_crisp():
    """The sung text is crisp: the glow of the letters, with no blurred halo.

    Before, the sung line was drawn twice: the crisp one and a blurred copy
    (the halo). That halo was a shadow and also expensive (two GaussianBlur
    per frame, 3.2 ms) and made the carousel drop below 60 fps. What is kept
    is the fill with its softened edge.
    """
    mod = image_module()
    if mod.Image is None:
        check("the fill can be measured (Pillow)", False, "without Pillow")
        return

    text = "cantando"
    sung = (0, 200, 0)
    pending = (0, 90, 0)
    image = mod.Image.new("RGBA", (400, 80), (0, 0, 0, 0))
    brush = mod.ImageDraw.Draw(image)
    renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
    renderer.fonts = {}
    renderer.font_files = {"prueba": mod.FALLBACK_FONT}
    renderer._draw_karaoke(brush, text, 40, 20, sung, pending, 4.0, "prueba")

    # What is left of the glow away from the text. The blurred halo used to
    # spill outside the text box; now nothing remains outside it.
    font = renderer.font("prueba", 20)
    x = (image.size[0] - brush.textlength(text, font=font)) / 2
    box = brush.textbbox((x, 40), text, font=font, anchor="lm")
    outside_box = 0
    for indice, px in enumerate(pixels(image)):
        if px[3] == 0:
            continue
        px_x = indice % image.size[0]
        px_y = indice // image.size[0]
        if (
            px_x < box[0] - 2
            or px_x > box[2] + 2
            or px_y < box[1] - 2
            or px_y > box[3] + 2
        ):
            outside_box += 1
    check(
        "no blurred halo remains away from the lyrics",
        outside_box == 0,
        "pixels=%s" % (outside_box,),
    )

    # And beyond the edge of the sung part there is no light of another
    # color: what remains is the edge of the fill (tones between sung and
    # pending), not a shadow spilled to the side.
    last = 0
    for indice, px in enumerate(pixels(image)):
        if px[3] > 0 and px[:3] == sung:
            last = max(last, indice % image.size[0])
    beyond = 0
    for indice, px in enumerate(pixels(image)):
        x = indice % image.size[0]
        if x <= last or px[3] == 0:
            continue
        red, green, blue = px[:3]
        if not (
            pending[0] <= red <= sung[0]
            and pending[1] <= green <= sung[1]
            and pending[2] <= blue <= sung[2]
        ):
            beyond += 1
    check(
        "no light spills beyond what is sung",
        beyond == 0,
        "pixels=%s" % (beyond,),
    )

    # The edge of the fill fades out: there are several intermediate tones
    # between the sung and the missing, not a jump from one color to another.
    mid_tones = set()
    for px in pixels(image):
        if px[3] == 0:
            continue
        red, green, blue = px[:3]
        if red == sung[0] and green == sung[1] and blue == sung[2]:
            continue
        if red == pending[0] and green == pending[1] and blue == pending[2]:
            continue
        mid_tones.add((red, green, blue))
    check(
        "the edge of the fill is smoothed",
        len(mid_tones) >= 3,
        "tones=%s" % (len(mid_tones),),
    )

    # The intermediate tones are mixes of the sung and the missing: if any
    # of them falls outside that range, the glow is dirty (the transparent
    # black from outside seeps into the color when it is blurred).
    outside = [
        color
        for color in mid_tones
        if not (
            pending[0] <= color[0] <= sung[0]
            and pending[1] <= color[1] <= sung[1]
            and pending[2] <= color[2] <= sung[2]
        )
    ]
    check(
        "the fill does not dirty the colours of the lyrics",
        not outside,
        "colours=%s" % (sorted(outside)[:5],),
    )




def check_reload_by_signal():
    """SIGUSR1 reloads the lyrics in the open window after clearing the cache."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.cfg = dict(mod.DEFAULTS)
            app.demo = False
            app.track = mod.Track("Tema", "Artista")
            app.reload_requested = False
            calls = []
            app.reload_lyrics = lambda force=False: calls.append(force)

            app._on_reload_signal(signal.SIGUSR1, None)
            check(
                "the signal leaves the reload pending",
                app.reload_requested is True,
                repr(app.reload_requested),
            )
            check(
                "the requested reload is handled only once",
                app._consume_reload() is True
                and calls == [True]
                and app.reload_requested is False,
                "calls=%s flag=%s" % (calls, app.reload_requested),
            )
            check(
                "without a signal nothing is reloaded",
                app._consume_reload() is False and calls == [True],
                "calls=%s" % (calls,),
            )

            # The PID of the window: the panel signals that process and does
            # not search by command line (SIGUSR1 kills by default).
            app.reload_requested = False
            app.log = lambda message: None
            app._announce_pid()
            file_path = mod.pid_path()
            try:
                with open(file_path, encoding="utf-8") as handle:
                    written = handle.read().strip()
            except OSError:
                written = ""
            check(
                "the window writes its PID",
                written == str(os.getpid()),
                "written=%r" % (written,),
            )
            app._forget_pid()
            check(
                "when the window closes it removes its PID",
                not os.path.exists(file_path),
                file_path,
            )


def check_real_terminal_size():
    """update_size() respects the real cells of the terminal.

    The window may have fewer than 30x12 cells (for example with a large
    font). Making up that minimum makes every row overflow and the text
    break into pieces.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.width = 0
            app.height = 0
            original = mod.shutil.get_terminal_size
            mod.shutil.get_terminal_size = lambda fallback=None: os.terminal_size(
                (23, 9)
            )
            try:
                app.update_size()
            finally:
                mod.shutil.get_terminal_size = original
            check("the width uses the real cells", app.width == 23, str(app.width))
            check("the height uses the real cells", app.height == 9, str(app.height))


def check_state_paths():
    """The state directory respects NOCTALIA_STATE_HOME and XDG_STATE_HOME."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            helper = getattr(mod, "state_dir", None)
            if not callable(helper):
                check(
                    "the state directory respects XDG_STATE_HOME",
                    False,
                    "no state_dir helper",
                )
                check(
                    "the state directory respects NOCTALIA_STATE_HOME",
                    False,
                    "no state_dir helper",
                )
                return
            previous = dict(os.environ)
            try:
                # LYRICS_CAROUSEL_STATE takes precedence over everything else:
                # without removing it, these checks would look at the state of
                # the sandbox instead of the one they ask for.
                os.environ.pop("LYRICS_CAROUSEL_STATE", None)
                os.environ.pop("NOCTALIA_STATE_HOME", None)
                os.environ["XDG_STATE_HOME"] = "/tmp/xdg-state-prueba"
                check(
                    "the state directory respects XDG_STATE_HOME",
                    helper() == "/tmp/xdg-state-prueba/noctalia",
                    helper(),
                )
                os.environ["NOCTALIA_STATE_HOME"] = "/tmp/noctalia-state-prueba"
                check(
                    "the state directory respects NOCTALIA_STATE_HOME",
                    helper() == "/tmp/noctalia-state-prueba/noctalia",
                    helper(),
                )
                os.environ.pop("NOCTALIA_STATE_HOME", None)
                os.environ.pop("XDG_STATE_HOME", None)
                expected = os.path.expanduser("~/.local/state/noctalia")
                check(
                    "the state directory uses the Noctalia one by default",
                    helper() == expected,
                    helper(),
                )
            finally:
                os.environ.clear()
                os.environ.update(previous)


def check_without_text_mode():
    """The configuration and the code no longer have a text mode.

    Leaving dead keys in DEFAULTS lets the panel or an IPC write values the
    window ignores: if the text mode were to sneak back in, the user would
    see controls that do nothing.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            for key in ("render_mode", "equalizer", "animation_ms", "language"):
                check(
                    "the script does not have the setting %s" % key,
                    key not in mod.DEFAULTS,
                    repr(sorted(mod.DEFAULTS)),
                )
            for name in (
                "equalizer_text", "_equalizer", "_equalizer_only", "_header",
                "_footer", "_hints", "_idle_block", "_line_color",
            ):
                check(
                    "the script does not keep %s" % name,
                    not hasattr(mod.LyricsCarousel, name),
                    name,
                )
            check(
                "no terminal width helpers are left",
                not hasattr(mod, "cell_width") and not hasattr(mod, "truncate"),
                "cell_width/truncate",
            )


def check_settings_limits():
    """The limits of the script are the ones of the manifest."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-limites-") as temporary:
        with temporary_env(
            {
                "XDG_CACHE_HOME": os.path.join(temporary, "cache"),
            }
        ), temporary_state(temporary) as destination:
            os.makedirs(os.path.join(destination, "plugins", "data"), exist_ok=True)
            with open(os.path.join(destination, "settings.toml"), "w", encoding="utf-8") as handle:
                handle.write(
                    '[plugin_settings."faminec/lyrics-carousel"]\n'
                    "width = 100\n"
                    "height = 100\n"
                    "offset_ms = 99999\n"
                )
            mod = script_module()
            cfg = mod.load_settings()
        check("the width is limited like the manifest", cfg["width"] == 400, str(cfg["width"]))
        check("the height is limited like the manifest", cfg["height"] == 200, str(cfg["height"]))
        check(
            "the offset is limited like the manifest",
            cfg["offset_ms"] == 3000,
            str(cfg["offset_ms"]),
        )


def check_readme():
    """The README documents what the manifest declares.

    The store requires the README to mention every dependency of the manifest
    with its exact name, to document every entry (widget, panel) with its id
    and to list the IPC commands. If the manifest changes and the README does
    not, the plugin is rejected in the store review; here it is warned about.
    """
    manifest_path = os.path.join(PLUGIN_DIR, "plugin.toml")
    readme_path = os.path.join(PLUGIN_DIR, "README.md")
    try:
        import tomllib

        with open(manifest_path, "rb") as handle:
            manifest = tomllib.load(handle)
    except Exception as error:  # noqa: BLE001
        check("the manifest can be read", False, repr(error)[:120])
        return
    try:
        with open(readme_path, encoding="utf-8") as handle:
            readme = handle.read()
    except OSError as error:
        check("the README can be read", False, repr(error)[:120])
        return

    plugin_id = manifest.get("id", "")
    check("the README cites the plugin id", f"`{plugin_id}`" in readme, plugin_id)

    # Every dependency of the manifest, with its exact name.
    dependencies = manifest.get("dependencies") or []
    for dependencia in dependencies:
        check(
            f"the README mentions the dependency `{dependencia}`",
            f"`{dependencia}`" in readme,
            dependencia,
        )

    # Every entry (widget, panel) with its id.
    entries = []
    for setting_key in ("widget", "panel", "service", "launcher_provider"):
        for entry in manifest.get(setting_key) or []:
            entries.append((setting_key, entry.get("id", "")))
    for setting_key, entry_id in entries:
        check(
            f"the README documents the entry {setting_key} `{entry_id}`",
            f"`{entry_id}`" in readme,
            entry_id,
        )

    # The IPC command of the panel, verbatim.
    for setting_key, entry_id in entries:
        if setting_key != "panel":
            continue
        command = f"noctalia msg panel-toggle {plugin_id}:{entry_id}"
        check(f"the README has the panel IPC command", command in readme, command)

    # The IPC events handled by the panel and the widget have to be
    # documented: the store template asks for them when the plugin does
    # something more than opening the panel.
    events = set()
    entries_by_id = {}
    for setting_key, entry_id in entries:
        entries_by_id[entry_id] = entry
    for entry_id, entry in entries_by_id.items():
        entry_path = os.path.join(PLUGIN_DIR, entry.get("entry", entry_id + ".luau"))
        try:
            with open(entry_path, encoding="utf-8") as handle:
                font = handle.read()
        except OSError:
            continue
        for name in ("launch", "toggle", "set", "refresh"):
            if f'event == "{name}"' in font:
                events.add(name)
    for event in sorted(events):
        commands = [
            f"noctalia msg plugin {plugin_id}:{entry_id} all {event}"
            for entry_id in entries_by_id
        ]
        check(
            f"the README documents the IPC event `{event}`",
            any(command in readme for command in commands),
            event,
        )


def check_empty_title_does_not_search_again():
    """A track without a title (artist only) does not restart the search in a loop.

    The guard in _apply_track compared the key and also required the new
    track to have a title. With a track without a title the condition was
    never met and every poll asked for the lyrics again.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.args = types.SimpleNamespace(force=False)
            app.track = mod.Track()
            app.track_key = ""
            app.state = "idle"
            app.lines = []
            app.source = ""
            app.synced = False
            app.last_fetch = 0.0
            app.log = lambda message: None
            start_calls = []

            class FakeFetcher:
                def start(self, track, force=False):
                    start_calls.append(track.key)

            app.fetcher = FakeFetcher()
            song = mod.Track("", "Artista", "Album", 100.0)
            for _ in range(5):
                app._apply_track(song)
            check(
                "a track without title does not restart the search",
                len(start_calls) == 1,
                "lookups=%d" % len(start_calls),
            )


def check_adapter_timeout():
    """The slow adapter (4 s) is not cut off before it answers.

    The 3 s deadline killed NetEase and QQ Music, which sometimes take longer:
    the lyrics were lost even though the adapter was about to return them.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-adapter-") as temporary:
        cache = os.path.join(temporary, "cache")
        os.makedirs(cache, exist_ok=True)
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            os.makedirs(mod.CACHE_DIR, exist_ok=True)
            script = os.path.join(temporary, "lyric_sources.py")
            with open(script, "w", encoding="utf-8") as handle:
                handle.write(
                    "import json, time\n"
                    "time.sleep(4)\n"
                    "print(json.dumps({'lines': [{'time': 1000, 'duration': 0, 'text': 'hola'}]}))\n"
                )
            original = mod.find_lyric_adapter
            mod.find_lyric_adapter = lambda: script
            try:
                lines, source = mod.run_adapter(
                    "splayer",
                    mod.Track("cancion", "artista", duration=200.0),
                    {},
                    lambda message: None,
                )
            finally:
                mod.find_lyric_adapter = original
            check(
                "the slow adapter is not cut off",
                len(lines) == 1,
                "lines=%d source=%s" % (len(lines), source),
            )


def check_real_times_do_not_overlap():
    """estimate_times fills in the lines without a time, not the ones that already have it."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            lines = [
                mod.LyricLine(-1.0, 0.0, "a"),
                mod.LyricLine(-1.0, 0.0, "b"),
                mod.LyricLine(-1.0, 0.0, "c"),
                mod.LyricLine(42.0, 4.0, "d"),
            ]
            mod.estimate_times(lines, 200.0)
            check(
                "estimate_times respects the real timings",
                abs(lines[3].start - 42.0) < 0.01,
                "start=%.3f" % lines[3].start,
            )


def check_lines_are_sorted():
    """The highlight ignores the lines without a time when searching by position."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.cfg = dict(mod.DEFAULTS)
            app.lines = [
                mod.LyricLine(-1.0, 0.0, "sin tiempo"),
                mod.LyricLine(10.0, 0.0, "suena"),
                mod.LyricLine(-1.0, 0.0, "sin tiempo 2"),
                mod.LyricLine(20.0, 0.0, "final"),
            ]
            index, _, _ = app.scroll_state(15.0)
            check(
                "the highlight ignores the lines without time",
                app.lines[index].text == "suena",
                "highlighted line=%r" % (app.lines[index].text,),
            )


def _config_app(mod):
    """Minimal instance to test _reload_config without opening the window."""
    app = object.__new__(mod.LyricsCarousel)
    app.args = types.SimpleNamespace(
        direction=None,
        no_karaoke=False,
        active_scale=None,
        accent=None,
        lang=None,
        force=False,
    )
    app.cfg = dict(mod.DEFAULTS)
    app.direction = 1
    app.karaoke = True
    app.spacing = 2
    app.image = None
    app.image_disabled = False
    app.image_failures = 0
    app.status_message = ""
    app.pending_overrides = {}
    app.log = lambda message: None
    app.tr = lambda key, args=None: key
    app._set_language = lambda value: None
    return app


def check_only_the_winner_writes_the_cache():
    """Only the winning provider writes the cache (not all of them)."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            mod.load_lyrics_settings = lambda: {
                "sources": ["lrclib", "netease"],
                "credentials": {},
                "translation": "zh-Hans",
            }
            mod.load_cache = lambda track: None
            mod.missing_recent = lambda track: False
            mod.SEARCH_TIMEOUT = 5.0
            saved_values = []
            mod.save_cache = lambda *args: saved_values.append(args)

            def lrclib(track, log):
                return [mod.LyricLine(1.0, 0.0, "gana")], None

            def adapter(source, track, settings, log):
                if source == "netease":
                    time.sleep(0.4)
                    return [mod.LyricLine(2.0, 0.0, "pierde")], None
                return [], None

            mod.fetch_lrclib = lrclib
            mod.run_adapter = adapter
            mod.fetch_lyrics(mod.Track("cancion", "artista", duration=100.0), True, lambda m: None)
            # The losing thread stays alive for a moment: the cache can only
            # have been written once, with the winner.
            time.sleep(0.6)
            check(
                "only the winning provider writes the cache",
                len(saved_values) == 1,
                "writes=%d" % len(saved_values),
            )


def check_times_per_word():
    """A lyric only counts as real karaoke if it brings per-character timings.

    Line-level providers (LRCLIB almost always) give one time per line: the
    karaoke spreads the duration evenly and does not follow the voice.
    Word-level ones bring a time per character, which is what makes the
    fill look like it recognizes the song.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            with_timings = mod.LyricLine(0.0, 2.0, "hola")
            with_timings.chars = [0.0, 0.1, 0.2, 0.3]
            without_timings = mod.LyricLine(2.0, 2.0, "mundo")
            another = mod.LyricLine(4.0, 2.0, "otra")
            check(
                "half of the lines with timings already counts as word level",
                mod.lines_have_chars([with_timings, without_timings]),
                "the timings were not detected",
            )
            check(
                "a single line with timings among several is not enough",
                not mod.lines_have_chars([with_timings, without_timings, another]),
                "a line-level lyric slipped in",
            )
            check(
                "empty lyrics have no word timings",
                not mod.lines_have_chars([]),
                "an empty list cannot count",
            )


def check_fetch_prefers_the_word_timing():
    """The first lyric is published; the word-level one improves it and goes to the cache.

    LRCLIB usually answers first, but with line-level timings. NetEase may
    bring word-level timings. Keeping the first one left the cache without
    `chars` forever and the karaoke spread the whole line evenly instead of
    following the voice.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            mod.load_lyrics_settings = lambda: {
                "sources": ["lrclib", "netease"],
                "credentials": {},
                "translation": "zh-Hans",
            }
            mod.load_cache = lambda track: None
            mod.missing_recent = lambda track: False
            mod.SEARCH_TIMEOUT = 5.0
            mod.WORD_GRACE = 1.5
            saved_values = []
            mod.save_cache = lambda *args: saved_values.append(args)

            def lyric_line(text, with_chars=False):
                line = mod.LyricLine(1.0, 2.0, text)
                if with_chars:
                    line.chars = [1.0 + index * 0.1 for index in range(len(text))]
                return line

            def lrclib(track, log):
                return [lyric_line("letra por linea")], None

            def adapter(source, track, settings, log):
                time.sleep(0.35)
                return [lyric_line("letra por palabra", True)], None

            mod.fetch_lrclib = lrclib
            mod.run_adapter = adapter
            updates = []
            lines, source, synced = mod.fetch_lyrics(
                mod.Track("cancion", "artista", duration=100.0),
                True,
                lambda message: None,
                on_update=lambda *args: updates.append(args),
            )
            check(
                "the final result has word timings",
                mod.lines_have_chars(lines),
                "source=%s" % (source,),
            )
            check(
                "the provider with word timings wins",
                source == "netease",
                "source=%s" % (source,),
            )
            check(
                "the first lyrics are published without waiting",
                bool(updates) and updates[0][1] == "lrclib",
                str([item[1] for item in updates]),
            )
            check(
                "the improvement is published when it arrives",
                len(updates) >= 2
                and mod.lines_have_chars(updates[-1][0]),
                str([item[1] for item in updates]),
            )
            check(
                "the cache keeps the word-level version",
                bool(saved_values) and mod.lines_have_chars(saved_values[-1][1]),
                "writes=%d" % len(saved_values),
            )


def check_word_fetch_does_not_wait():
    """If the first lyric already brings word-level timings, nobody is waited for."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            mod.load_lyrics_settings = lambda: {
                "sources": ["lrclib", "netease"],
                "credentials": {},
                "translation": "zh-Hans",
            }
            mod.load_cache = lambda track: None
            mod.missing_recent = lambda track: False
            mod.SEARCH_TIMEOUT = 3.0
            mod.WORD_GRACE = 3.0
            mod.save_cache = lambda *args: None

            text = "letra por palabra"
            line = mod.LyricLine(1.0, 2.0, text)
            line.chars = [1.0 + index * 0.1 for index in range(len(text))]

            def lrclib(track, log):
                return [mod.LyricLine(1.0, 2.0, text, line.chars)], None

            def adapter(source, track, settings, log):
                time.sleep(2.0)
                return [mod.LyricLine(5.0, 2.0, "tarde")], None

            mod.fetch_lrclib = lrclib
            mod.run_adapter = adapter
            start_value = time.monotonic()
            lines, source, synced = mod.fetch_lyrics(
                mod.Track("cancion", "artista", duration=100.0),
                True,
                lambda message: None,
            )
            elapsed = time.monotonic() - start_value
            check(
                "with word timings the slow provider is not waited for",
                elapsed < 1.0,
                "took %.2f s" % elapsed,
            )
            check(
                "the lyrics with word timings win",
                source == "lrclib" and mod.lines_have_chars(lines),
                "source=%s" % (source,),
            )


def check_lyrics_without_accents():
    """A latin lyric without accents or tildes cannot override the one that has them.

    NetEase sometimes returns the Frijolero lyric as "algn", "petrleo",
    "pases" or "Quin". That version brings per-character timings and that is
    why it used to win over the LRCLIB one, which is properly written. The
    carousel must keep the one with the accents, whether it arrives first or later.
    """
    broken = [
        "Yo ya estoy hasta la madre",
        "De que me pongan sombrero",
        "Escucha entonces cuando digo",
        "No me llames Frijolero",
        "Y aunque exista algn respeto",
        "Y no metamos las narices",
        "Nunca inflamos la moneda",
        "Haciendo guerra a otros pases",
        "Te pagamos con petrleo",
        "O intereses nuestra deuda",
        "Quin se queda con la feria",
        "El nino juega en el patio",
    ]
    good = [
        "Yo ya estoy hasta la madre",
        "De que me pongan sombrero",
        "Escucha entonces cuando digo",
        "No me llames Frijolero",
        "Y aunque exista algún respeto",
        "Y no metamos las narices",
        "Nunca inflamos la moneda",
        "Haciendo guerra a otros países",
        "Te pagamos con petróleo",
        "E intereses nuestra deuda",
        "Quién se queda con la feria",
        "El niño juega en el patio",
    ]
    english = (
        "We drove across the desert looking for a place to rest and found "
        "nothing but sand and sky and silence everywhere we turned until "
        "morning came"
    )

    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            mod.load_lyrics_settings = lambda: {
                "sources": ["lrclib", "netease"],
                "credentials": {},
                "translation": "zh-Hans",
            }
            mod.load_cache = lambda track: None
            mod.missing_recent = lambda track: False
            mod.save_cache = lambda *args: None
            mod.SEARCH_TIMEOUT = 3.0
            mod.WORD_GRACE = 2.0

            def lyric_lines(texts, with_chars=False):
                output = []
                for indice, text in enumerate(texts):
                    line = mod.LyricLine(1.0 + indice * 4.0, 3.0, text)
                    if with_chars:
                        line.chars = [
                            1.0 + indice * 4.0 + time_step * 0.05
                            for time_step in range(len(text))
                        ]
                    output.append(line)
                return output

            def fake_fetch(lrclib_lyrics, adapter_lyrics, lrclib_wait=0.0, adapter_wait=0.0):
                def fetch(track, log):
                    time.sleep(lrclib_wait)
                    return lrclib_lyrics, None

                def adapter(source, track, settings, log):
                    time.sleep(adapter_wait)
                    return adapter_lyrics, None

                mod.fetch_lrclib = fetch
                mod.run_adapter = adapter
                return mod.fetch_lyrics(
                    mod.Track("Frijolero", "Molotov", duration=208.0),
                    True,
                    lambda message: None,
                )

            detector = getattr(mod, "text_without_accents", None)
            check("the detector of lyrics without accents exists", callable(detector))
            if detector is not None:
                check(
                    "the broken lyrics are detected as missing accents",
                    detector(lyric_lines(broken)),
                    "not detected",
                )
                check(
                    "the corrected lyrics are not flagged",
                    not detector(lyric_lines(good)),
                    "the good lyrics were flagged",
                )
                check(
                    "English lyrics without accents are not flagged",
                    not detector(lyric_lines([english])),
                    "the English was flagged",
                )

            # A) The complete one arrives first and the broken word-level one later.
            lines, source, _ = fake_fetch(
                lyric_lines(good), lyric_lines(broken, True), adapter_wait=0.2
            )
            text = " ".join(line.text for line in lines or [])
            check(
                "the complete lyrics win over the broken word-level ones",
                "algún" in text and "petróleo" in text and source == "lrclib",
                "source=%s text=%r" % (source, text[:60]),
            )

            # B) The broken word-level one arrives first and the complete one later.
            lines, source, _ = fake_fetch(
                lyric_lines(good), lyric_lines(broken, True), lrclib_wait=0.2
            )
            text = " ".join(line.text for line in lines or [])
            check(
                "the complete lyrics replace the broken word-level ones",
                "algún" in text and "petróleo" in text and source == "lrclib",
                "source=%s text=%r" % (source, text[:60]),
            )

            # C) With no alternative, the only available lyric is shown anyway.
            lines, source, _ = fake_fetch(lyric_lines(broken, True), [])
            text = " ".join(line.text for line in lines or [])
            check(
                "with no alternative the broken lyrics are shown anyway",
                bool(lines) and "algn" in text,
                "source=%s text=%r" % (source, text[:60]),
            )

            # D) A background improvement cannot degrade the good lyric that
            #    is already being shown.
            app = object.__new__(mod.LyricsCarousel)
            app.track = mod.Track("Frijolero", "Molotov", duration=208.0)
            current = lyric_lines(good)
            app.lines = current
            app.source = "lrclib"
            app.synced = True
            app.state = "lyrics"
            app._snap_scroll = lambda: None
            mod.mark_word_checked = lambda track: None
            apply = getattr(app, "_apply_fetched", None)
            if apply is None:
                check(
                    "the broken lyrics do not replace the good ones already shown",
                    False,
                    "_apply_fetched is missing",
                )
            else:
                check(
                    "the broken lyrics do not replace the good ones already shown",
                    apply(lyric_lines(broken, True), "netease", True) is False
                    and app.source == "lrclib"
                    and app.lines is current,
                    "source=%s" % (app.source,),
                )


def check_improvement_does_not_overwrite_the_cache():
    """An improvement search without word-level timings does not rewrite the cache."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            mod.load_lyrics_settings = lambda: {
                "sources": ["lrclib"],
                "credentials": {},
                "translation": "zh-Hans",
            }
            mod.load_cache = lambda track: None
            mod.missing_recent = lambda track: False
            mod.SEARCH_TIMEOUT = 2.0
            mod.WORD_GRACE = 0.2
            mod.save_cache = lambda *args: None
            mod.fetch_lrclib = lambda track, log: (
                [mod.LyricLine(1.0, 2.0, "letra por linea")],
                None,
            )
            mod.run_adapter = lambda source, track, settings, log: ([], None)
            saved_values = []
            mod.save_cache = lambda *args: saved_values.append(args)
            mod.fetch_lyrics(
                mod.Track("cancion", "artista", duration=100.0),
                True,
                lambda message: None,
                upgrade=True,
            )
            check(
                "an improvement without timings does not overwrite the existing cache",
                not saved_values,
                "writes=%d" % len(saved_values),
            )


def check_cache_is_upgraded_in_the_background():
    """A line-level cache is improved in the background when it is shown."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            line = mod.LyricLine(1.0, 2.0, "letra por linea")
            original_cache = mod.load_cache
            original_recent = getattr(mod, "word_checked_recent", None)
            mod.load_cache = lambda track: ([line], "lrclib", True)
            mod.word_checked_recent = lambda track: False

            class FakeFetcher:
                def __init__(self):
                    self.start_calls = []

                def start(self, track, force=False, upgrade=False):
                    self.start_calls.append((force, upgrade))

                def take(self):
                    return None

            try:
                app = _config_app(mod)
                app.track = mod.Track("cancion", "artista", duration=100.0)
                app.lines = []
                app.source = ""
                app.synced = False
                app.state = "idle"
                app.last_fetch = 0.0
                app.fetcher = FakeFetcher()
                app.reload_lyrics()
                check(
                    "the cached lyrics are shown instantly",
                    app.state == "lyrics" and app.lines == [line],
                    "state=%s lines=%d" % (app.state, len(app.lines)),
                )
                check(
                    "the line-level cache is improved in the background",
                    app.fetcher.start_calls == [(True, True)],
                    repr(app.fetcher.start_calls),
                )

                # If it was already checked recently, the search is not
                # repeated on every start of the song.
                mod.word_checked_recent = lambda track: True
                app = _config_app(mod)
                app.track = mod.Track("cancion", "artista", duration=100.0)
                app.lines = []
                app.source = ""
                app.synced = False
                app.state = "idle"
                app.last_fetch = 0.0
                app.fetcher = FakeFetcher()
                app.reload_lyrics()
                check(
                    "a recent check does not repeat the search",
                    app.fetcher.start_calls == [],
                    repr(app.fetcher.start_calls),
                )
            finally:
                mod.load_cache = original_cache
                if original_recent is None:
                    del mod.word_checked_recent
                else:
                    mod.word_checked_recent = original_recent


def check_result_does_not_overwrite_the_same_lyrics():
    """A result of the same quality does not place the carousel again."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            original_mark = getattr(mod, "mark_word_checked", None)
            mod.mark_word_checked = lambda track: None
            try:
                app = object.__new__(mod.LyricsCarousel)
                app.track = mod.Track("cancion", "artista", duration=100.0)
                current = mod.LyricLine(1.0, 2.0, "letra por linea")
                app.lines = [current]
                app.source = "lrclib"
                app.synced = True
                app.state = "lyrics"
                app._snap_scroll = lambda: None
                apply = getattr(app, "_apply_fetched", None)
                if apply is None:
                    check("applying a result does not overwrite the current lyrics", False, "_apply_fetched is missing")
                    return
                another = mod.LyricLine(1.0, 2.0, "otra letra por linea")
                check(
                    "lyrics of the same quality are not applied again",
                    apply([another], "netease", True) is False
                    and app.source == "lrclib"
                    and app.lines == [current],
                    "source=%s" % (app.source,),
                )
                word = mod.LyricLine(1.0, 2.0, "letra por palabra")
                word.chars = [1.0 + index * 0.1 for index in range(len(word.text))]
                check(
                    "lyrics with word timings do replace",
                    apply([word], "netease", True) is True
                    and app.source == "netease",
                    "source=%s" % (app.source,),
                )
                check(
                    "an empty search does not clear the current lyrics",
                    apply([], "", False) is False and bool(app.lines),
                    "lines=%d" % len(app.lines),
                )
            finally:
                if original_mark is None:
                    del mod.mark_word_checked
                else:
                    mod.mark_word_checked = original_mark


def check_enhanced_lrc_to_characters():
    """An LRC with <mm:ss.xx> marks is converted into per-character timings.

    This is the format that brings the lyrics synchronized word by word in
    some providers: without this the marks were discarded and the karaoke
    spread the whole line evenly.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            lines = mod.parse_lrc(
                "[00:10.00]<00:10.00>Hola <00:10.50>mundo\n"
                "[00:12.00]siguiente"
            )
            line = lines[0] if lines else None
            text = line.text if line else ""
            chars = line.chars if line else []
            check(
                "the enhanced LRC keeps the text without the marks",
                text == "Hola mundo",
                repr(text),
            )
            check(
                "the enhanced LRC gives one time per character",
                len(chars) == len("Hola mundo"),
                repr(chars),
            )
            check(
                "the first character goes into the line mark",
                bool(chars) and abs(chars[0] - 10.0) < 0.01,
                repr(chars[:2]),
            )
            check(
                "the second word goes into its own mark",
                len(chars) > 5 and abs(chars[5] - 10.5) < 0.01,
                repr(chars[4:7]),
            )
            check(
                "the per-character timings do not go backwards",
                all(
                    before <= after + 1e-6
                    for before, after in zip(chars, chars[1:])
                ),
                repr(chars),
            )


def check_lrclib_prefers_the_enhanced_lyrics():
    """Between two equal candidates, the one with word-level timings wins."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            original = mod._http_json
            candidates = [
                {
                    "trackName": "cancion",
                    "artistName": "artista",
                    "duration": 100,
                    "syncedLyrics": "[00:01.00]hola\n[00:05.00]mundo",
                },
                {
                    "trackName": "cancion",
                    "artistName": "artista",
                    "duration": 100,
                    "syncedLyrics": "[00:01.00]<00:01.00>hola <00:01.50>mundo",
                },
            ]
            mod._http_json = lambda *args, **kwargs: candidates
            try:
                lines, error = mod.fetch_lrclib(
                    mod.Track("cancion", "artista", duration=100.0),
                    lambda message: None,
                )
            finally:
                mod._http_json = original
            check(
                "the lyrics with word timings are preferred",
                mod.lines_have_chars(lines),
                "error=%r" % (error,),
            )


def check_lyrics_settings_state_dir():
    """The Lyrics configuration is read from the real Noctalia state."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-estado-") as temporary:
        with temporary_state(temporary) as state_value:
            with open(os.path.join(state_value, "settings.toml"), "w", encoding="utf-8") as handle:
                handle.write(
                    '[plugin_settings."h465855hgg/lyrics"]\n'
                    'lyrics_sources = ["lrclib"]\n'
                )
            mod = script_module()
            settings_file = mod.load_lyrics_settings()
        check(
            "the lyrics sources are read from the Noctalia state",
            settings_file.get("sources") == ["lrclib"],
            str(settings_file.get("sources")),
        )


def check_karaoke_uses_real_times():
    """The karaoke uses the next real time, not the one of the next line.

    Lines without a time mark are -1: if the karaoke fill takes "the next
    one in the list", the active line is left without an end (or is cut
    short all of a sudden) and the highlight goes out of sync.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.lines = [
                mod.LyricLine(10.0, 0, "primera"),
                mod.LyricLine(-1, 0, "sin tiempo"),
                mod.LyricLine(20.0, 0, "tercera"),
            ]
            next_timed_start_fn = getattr(app, "next_timed_start", None)
            ok = next_timed_start_fn is not None and next_timed_start_fn(0) == 20.0
            check("the karaoke uses the next real time", ok, str(next_timed_start_fn))
            if next_timed_start_fn is not None:
                check(
                    "the last line has no next time",
                    next_timed_start_fn(2) is None,
                    str(next_timed_start_fn(2)),
                )


def check_estimated_times_do_not_advance_untimed_lines():
    """The lines without a time are not placed before the real ones.

    A lyric with a half-done LRC (some lines with a time and others without)
    cannot spread the times at random: if the line without a time is at the
    end of the list, it cannot start playing at second 6 and leave the part
    with real times unhighlighted.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()

            # Reviewer case: the line without a time goes last.
            lines = [
                mod.LyricLine(30.0, 0, "con tiempo"),
                mod.LyricLine(60.0, 0, "con tiempo"),
                mod.LyricLine(-1, 0, "sin tiempo"),
            ]
            mod.estimate_times(lines, 200.0)
            check(
                "the line without time does not overtake the real ones",
                lines[2].start > lines[1].start,
                str([line.start for line in lines]),
            )
            check(
                "the real timings do not move",
                abs(lines[0].start - 30.0) < 0.01 and abs(lines[1].start - 60.0) < 0.01,
                str([line.start for line in lines]),
            )

            # A line without a time in the middle stays between its neighbours.
            lines = [
                mod.LyricLine(10.0, 0, "primera"),
                mod.LyricLine(-1, 0, "sin tiempo"),
                mod.LyricLine(20.0, 0, "tercera"),
            ]
            mod.estimate_times(lines, 200.0)
            check(
                "the line without time stays between the real ones",
                lines[0].start < lines[1].start < lines[2].start,
                str([line.start for line in lines]),
            )

            # Edge case: several lines without a time before a very early
            # real one. They cannot all end at second 0 (nor get out of
            # order): they have to spread out without leaving the origin.
            lines = [
                mod.LyricLine(-1, 0, "a"),
                mod.LyricLine(-1, 0, "b"),
                mod.LyricLine(-1, 0, "c"),
                mod.LyricLine(2.0, 0, "real"),
            ]
            mod.estimate_times(lines, 200.0)
            starts = [line.start for line in lines]
            check(
                "the lines without time spread out without overlapping",
                starts[0] < starts[1] < starts[2] < starts[3],
                str(starts),
            )
            check(
                "the lines without time stay before the real one",
                starts[0] >= 0.0 and starts[2] < 2.0,
                str(starts),
            )


def check_estimated_times_stay_inside_the_song():
    """The lines without a time stay inside the song.

    The gap between lines is not derived from the duration: with a 200 s
    song, a line without a time at the end used to end at second 226
    (outside the song, so it was never highlighted). And if the list of
    lines comes out of order, the estimate has to fall after the previous
    line (not in a gap computed with a duration that did not correspond to
    it).
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()

            # A line without a time at the end: it stays four seconds after
            # the last real one, inside the song.
            lines = [
                mod.LyricLine(30.0, 0, "con tiempo"),
                mod.LyricLine(-1, 0, "sin tiempo"),
            ]
            mod.estimate_times(lines, 200.0)
            check(
                "the line without time at the end does not leave the song",
                30.0 < lines[1].start < 200.0,
                str([line.start for line in lines]),
            )
            check(
                "the line without time at the end goes right after the real one",
                lines[1].start <= 30.0 + 4.0,
                str([line.start for line in lines]),
            )

            # Shuffled list: the estimate falls after the previous line (the
            # next real one comes earlier in time, so the intermediate gap
            # is useless).
            lines = [
                mod.LyricLine(30.0, 0, "con tiempo"),
                mod.LyricLine(-1, 0, "sin tiempo"),
                mod.LyricLine(10.0, 0, "con tiempo"),
            ]
            mod.estimate_times(lines, 200.0)
            check(
                "with a shuffled list the estimate goes after the previous one",
                30.0 < lines[1].start < 200.0,
                str([line.start for line in lines]),
            )

            # Several lines without a time at the end: all of them inside the
            # song and without overlapping.
            lines = [
                mod.LyricLine(180.0, 0, "con tiempo"),
                mod.LyricLine(-1, 0, "a"),
                mod.LyricLine(-1, 0, "b"),
                mod.LyricLine(-1, 0, "c"),
                mod.LyricLine(-1, 0, "d"),
                mod.LyricLine(-1, 0, "e"),
            ]
            mod.estimate_times(lines, 200.0)
            starts = [line.start for line in lines]
            check(
                "the lines without time at the end do not leave the song",
                all(start_value < 200.0 for start_value in starts[1:]),
                str(starts),
            )
            check(
                "the lines without time at the end spread out in order",
                starts[1] < starts[2] < starts[3] < starts[4] < starts[5],
                str(starts),
            )

            # The last real line may fall right at the end (or beyond): the
            # estimated ones cannot end at second 104 of a
            # 100 s song.
            lines = [
                mod.LyricLine(100.0, 0, "con tiempo"),
                mod.LyricLine(-1, 0, "sin tiempo"),
                mod.LyricLine(-1, 0, "sin tiempo 2"),
            ]
            mod.estimate_times(lines, 100.0)
            starts = [line.start for line in lines]
            check(
                "the estimated ones after a real one at the end do not leave the song",
                all(0.0 <= start_value <= 100.0 for start_value in starts[1:]),
                str(starts),
            )

            # Between two real ones, the next may be beyond the end of the
            # song: the gap is clipped to the duration.
            lines = [
                mod.LyricLine(10.0, 0, "con tiempo"),
                mod.LyricLine(-1, 0, "sin tiempo"),
                mod.LyricLine(200.0, 0, "con tiempo"),
            ]
            mod.estimate_times(lines, 100.0)
            check(
                "an estimated one between two real ones does not leave the song",
                0.0 <= lines[1].start <= 100.0,
                str([line.start for line in lines]),
            )

            # The first real line at second 0 leaves no gap before it: the
            # estimated ones stay at the origin, they do not jump past it.
            lines = [
                mod.LyricLine(-1, 0, "sin tiempo"),
                mod.LyricLine(-1, 0, "sin tiempo 2"),
                mod.LyricLine(0.0, 0, "con tiempo"),
            ]
            mod.estimate_times(lines, 100.0)
            starts = [line.start for line in lines]
            check(
                "with no gap before the first real one the estimated ones do not jump ahead",
                starts[0] <= starts[2] and starts[1] <= starts[2] and starts[0] <= starts[1],
                str(starts),
            )

            # Two real lines with the SAME time leave no gap: the estimated
            # one cannot be placed after the next, because the highlight
            # would go backwards (the line that comes later in the list
            # would already have been sung).
            lines = [
                mod.LyricLine(10.0, 0, "primera"),
                mod.LyricLine(-1, 0, "sin tiempo"),
                mod.LyricLine(10.0, 0, "segunda"),
            ]
            mod.estimate_times(lines, 200.0)
            check(
                "with no gap between two real ones with the same time the estimated one does not go after",
                lines[1].start <= lines[2].start,
                str([line.start for line in lines]),
            )

            # Without any anchor the duration also rules: a short song
            # cannot leave lines at second 13.
            lines = [mod.LyricLine(-1, 0, "línea %d" % indice) for indice in range(10)]
            mod.estimate_times(lines, 10.0)
            starts = [line.start for line in lines]
            check(
                "without anchors the estimated ones fit in a short song",
                all(0.0 <= start_value <= 10.0 for start_value in starts),
                str(starts),
            )


def check_geometry_is_clipped_to_the_screen():
    """The window geometry is applied by the panel, not by the script.

    The panel clips the width and the height to the monitor and uses the
    Noctalia API (which does work). The script used to try to do the same
    with `hyprctl dispatch` and its own arithmetic: that arithmetic used the
    whole monitor (not the usable area) and the resize was silently
    discarded, so the window ended up off screen.
    """
    mod = script_module()
    check(
        "the script does not resize the window on its own",
        not hasattr(mod, "apply_geometry"),
        "apply_geometry is still in the script",
    )


def check_window_size_via_hyprctl():
    """The window size is read from Hyprland, in pixels.

    The width/height setting is the window size in pixels (what the panel
    uses when creating it). The terminal cell is another measure: before,
    the script stored the cells (96x30) and the window was created with
    96x30 pixels, that is, tiny.
    """
    mod = script_module()
    original = mod.subprocess.run
    try:
        mod.subprocess.run = lambda args, **kwargs: types.SimpleNamespace(
            returncode=0,
            stdout=json.dumps([
                {"class": "otra-ventana", "size": [800, 600]},
                {"class": "noctalia-lyrics-carousel", "size": [1300, 900]},
            ]),
            stderr="",
        )
        check(
            "the window size is read from Hyprland",
            mod.window_size_px() == (1300, 900),
            str(mod.window_size_px()),
        )
        mod.subprocess.run = lambda args, **kwargs: types.SimpleNamespace(
            returncode=0, stdout="[]", stderr=""
        )
        check(
            "without the carousel window there is no size",
            mod.window_size_px() is None,
            str(mod.window_size_px()),
        )
    finally:
        mod.subprocess.run = original


def check_redimensionado_manual_se_guarda():
    """The size the user picks by hand is stored in pixels.

    Resizing the window with the mouse does not go through the panel, so the
    script stores it. It goes to the overrides layer (not to settings.toml):
    writing settings.toml makes Noctalia reload the configuration and close
    the panel that was open.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.demo = False
            app.args = types.SimpleNamespace(debug=False)
            app.cfg = dict(mod.DEFAULTS)
            app._last_size_check = 0.0
            saved_values = []
            app._save_override = (
                lambda key, value, kind="string", persist=True: saved_values.append(
                    (key, value, kind, persist)
                )
            )
            original = mod.window_size_px
            try:
                mod.window_size_px = lambda: (1300, 900)
                app.check_manual_resize()
                check(
                    "the resized width is saved",
                    any(k == "width" and v == 1300 for k, v, _, _ in saved_values),
                    str(saved_values),
                )
                check(
                    "the resized height is saved",
                    any(k == "height" and v == 900 for k, v, _, _ in saved_values),
                    str(saved_values),
                )
                check(
                    "the size is saved in the overrides layer",
                    bool(saved_values) and all(persist is False for _, _, _, persist in saved_values),
                    str(saved_values),
                )

                # The size already in the settings is not stored again.
                saved_values.clear()
                app.cfg["width"] = 1300
                app.cfg["height"] = 900
                app._last_size_check = 0.0
                app.check_manual_resize()
                check(
                    "a size that is already saved is not repeated",
                    not saved_values,
                    str(saved_values),
                )

                # A tiny window (for example halfway through a drag) is no good.
                saved_values.clear()
                mod.window_size_px = lambda: (55, 15)
                app._last_size_check = 0.0
                app.check_manual_resize()
                check(
                    "a tiny window is not saved",
                    not saved_values,
                    str(saved_values),
                )
            finally:
                mod.window_size_px = original


def check_lrc_hours():
    """An LRC with hours ([01:02:03]) is not discarded."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            lines = mod.parse_lrc("[01:02:03]hola")
            check(
                "an LRC with hours is parsed",
                len(lines) == 1 and abs(lines[0].start - 3723.0) < 0.01,
                str([line.start for line in lines]),
            )


def check_lrc_minutes():
    """An LRC with more than 99 minutes ([100:00]) is not discarded."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            lines = mod.parse_lrc("[100:00]hola")
            check(
                "an LRC with three-digit minutes is parsed",
                len(lines) == 1 and abs(lines[0].start - 6000.0) < 0.01,
                str([line.start for line in lines]),
            )


def check_lrc_decimals():
    """An LRC with four or six decimals is not discarded."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            lines = mod.parse_lrc("[00:12.1234]hola")
            check(
                "an LRC with four decimals is parsed",
                len(lines) == 1 and abs(lines[0].start - 12.1234) < 0.001,
                str([line.start for line in lines]),
            )
            # Six decimals: the time is stored with milliseconds (what the
            # karaoke needs), but the line is not discarded.
            lines = mod.parse_lrc("[00:12.123456]hola")
            check(
                "an LRC with six decimals is parsed",
                len(lines) == 1 and abs(lines[0].start - 12.123) < 0.001,
                str([line.start for line in lines]),
            )


def check_text_between_angle_brackets():
    """The enhanced tags do not eat the normal text between < >."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            lines = mod.parse_lrc("[00:01.00]I <3 you > me")
            text = lines[0].text if lines else ""
            check(
                "the text with < and > is preserved",
                "<3" in text,
                repr(text),
            )


def check_cache_json_is_not_an_object():
    """A cache with a JSON that is not an object does not raise."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            mod.CACHE_DIR = cache
            track = mod.Track("cancion", "artista", duration=100.0)
            path = os.path.join(cache, mod.cache_key(track) + ".json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("[]")
            try:
                outcome = mod.load_cache(track)
            except Exception as error:  # noqa: BLE001
                outcome = error
            check(
                "a cache that is not an object does not throw",
                outcome is None,
                repr(outcome)[:120],
            )


def check_pause_key_survives_playerctl_failure():
    """If playerctl fails, the pause key does not kill the window."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = object.__new__(mod.LyricsCarousel)
            app.track = mod.Track("cancion", "artista", player="mpv")
            app._player = None
            original = mod.subprocess.run

            def fail(*args, **kwargs):
                raise OSError("no playerctl")

            mod.subprocess.run = fail
            try:
                outcome = app.handle_key(" ")
            except Exception as error:  # noqa: BLE001
                outcome = error
            finally:
                mod.subprocess.run = original
            check(
                "a failing playerctl does not kill the window",
                outcome is True,
                repr(outcome)[:120],
            )


def check_shortcut_is_not_reverted():
    """Pressing 'd' is not reverted if the config still has the old value."""
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as cache:
        with temporary_env({"XDG_CACHE_HOME": cache}):
            mod = script_module()
            app = _config_app(mod)
            app._save_override = lambda key, value, kind="string": app.pending_overrides.__setitem__(
                key, value
            )
            app.handle_key("d")
            original = mod.load_settings
            mod.load_settings = lambda: dict(mod.DEFAULTS)
            try:
                app._reload_config()
            finally:
                mod.load_settings = original
            check(
                "the 'd' shortcut is not lost on reload",
                app.cfg.get("direction") == "up"
                and app.direction == -1,
                "direction=%s cfg=%s" % (app.direction, app.cfg.get("direction")),
            )


def check_panel_covers_the_manifest():
    """Every setting of the manifest can be changed from the panel.

    The Noctalia settings page and the panel have to offer the same thing:
    a setting that only exists in the settings page makes the user think
    the panel is complete when it is not.
    """
    try:
        import tomllib

        with open(os.path.join(PLUGIN_DIR, "plugin.toml"), "rb") as handle:
            manifest = tomllib.load(handle)
    except Exception as error:  # noqa: BLE001
        check("the manifest can be read for the panel", False, repr(error)[:120])
        return
    try:
        with open(os.path.join(PLUGIN_DIR, "panel.luau"), encoding="utf-8") as handle:
            panel = handle.read()
    except OSError as error:
        check("the panel can be read", False, repr(error)[:120])
        return
    for setting in manifest.get("setting", []):
        key = setting.get("key", "")
        # The bar icon is configured on this page and not in the panel: it
        # belongs to the bar widget, not to the lyrics window. It is the only
        # key allowed outside the panel.
        if key == "glyph":
            continue
        # The panel can touch the setting in three ways: writing it
        # directly (setSetting), through a toggle row
        # (toggleRow) or with a control whose key is the setting
        # itself (key = "...").
        exposed = (
            f'setSetting("{key}"' in panel
            or f'toggleRow("{key}"' in panel
            or f'key = "{key}"' in panel
            or f'numberOf("{key}")' in panel
            or f'valueOf("{key}")' in panel
            or f'countChips("{key}"' in panel
            or f'sizeStepper("{key}"' in panel
            or f'sliderRow("{key}"' in panel
            or f'inputRow("{key}"' in panel
        )
        check(f"the panel exposes `{key}`", exposed, key)


def check_centered_hints():
    """The shortcuts row ends up centered in the image window.

    Before it started at the left margin and the leftover accumulated on
    the right: it looked misaligned. Now it is drawn with the same centering
    as the rest of the texts.
    """
    mod = image_module()
    if mod.Image is None:
        check("the hints can be measured (Pillow)", False, "without Pillow")
        return

    image = mod.Image.new("RGBA", (1000, 200), (0, 0, 0, 0))
    brush = mod.ImageDraw.Draw(image)
    app = types.SimpleNamespace(
        texts={"hints": ["pulsa [q] para salir"]},
        theme=types.SimpleNamespace(
            background=(10, 10, 10),
            faint=(120, 120, 120),
        ),
        terminal_pixels=lambda: (1000, 200),
        demo=False,
    )
    renderer = mod.ImageRenderer.__new__(mod.ImageRenderer)
    renderer.app = app
    renderer.fonts = {}
    renderer.font_files = {"prueba": mod.FALLBACK_FONT}
    renderer._measure_draw = brush
    renderer._draw_hints(brush, 20.0, "prueba")

    box = image.getbbox()
    check("the shortcuts are drawn", box is not None, repr(box))
    if box is not None:
        center_x = (box[0] + box[2]) / 2.0
        check(
            "the shortcuts end up centered",
            abs(center_x - 500.0) <= 2.0,
            "center=%.1f bbox=%s" % (center_x, box),
        )




def check_translate_lyrics_false_default():
    """translate_lyrics default false."""
    mod = script_module()
    check(
        "translate_lyrics default false",
        mod.DEFAULTS.get("translate_lyrics") == False,
        mod.DEFAULTS.get("translate_lyrics"),
    )


def check_settings_are_split():
    """The manifest does not duplicate what is already changed in the panel.

    The user does not consider the Noctalia configuration options that are
    already in the panel necessary, so the manifest only declares what the
    panel does not offer. If someone adds a key back that the panel already
    controls, the settings page and the panel end up offering the same
    thing with two different limits.

    The exception is `glyph`: it is the icon of the bar widget, which is
    configured on this page and not in the lyrics window.
    """
    try:
        import tomllib

        with open(os.path.join(PLUGIN_DIR, "plugin.toml"), "rb") as handle:
            manifest = tomllib.load(handle)
    except Exception as error:  # noqa: BLE001
        check("the manifest can be read for the split", False, repr(error)[:120])
        return
    declared = {
        setting.get("key", "")
        for setting in manifest.get("setting", [])
        if setting.get("key")
    }
    only_in_settings = {"glyph"}

    # What the panel controls: it is the list of keys of lib/settings.luau
    # (DEFAULTS), not loose text, so that the test does not go stale.
    lib = os.path.join(PLUGIN_DIR, "lib", "settings.luau")
    from_panel = set()
    try:
        with open(lib, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        check("the list of keys can be read", False, repr(error)[:120])
        return
    block = re.search(r"local DEFAULTS = \{(.*?)\n\}", text, re.S)
    if block:
        for found in re.finditer(r"^\s{2}(\w+)\s*=", block.group(1), re.M):
            from_panel.add(found.group(1))
    check("the list of panel keys can be read", bool(from_panel))

    duplicates = sorted((declared - only_in_settings) & from_panel)
    check(
        "the manifest does not repeat the panel settings",
        not duplicates,
        "duplicates=%s" % (duplicates,),
    )
    check(
        "the manifest only leaves what is not in the panel",
        declared <= only_in_settings,
        "declared=%s" % (sorted(declared),),
    )
    check(
        "the bar icon is still in the manifest",
        "glyph" in declared,
        str(sorted(declared)),
    )


def check_panel_attached():
    """The panel opens attached to the widget, not in the center of the screen."""
    try:
        import tomllib

        with open(os.path.join(PLUGIN_DIR, "plugin.toml"), "rb") as handle:
            manifest = tomllib.load(handle)
    except Exception as error:  # noqa: BLE001
        check("the manifest can be read for the placement", False, repr(error)[:120])
        return
    panel = (manifest.get("panel") or [{}])[0]
    check(
        "the panel opens attached",
        panel.get("placement") == "attached",
        str(panel.get("placement")),
    )
    check(
        "the panel opens next to the widget",
        panel.get("open_near_click") is True,
        str(panel.get("open_near_click")),
    )


def check_output_on_close():
    """The script exits when the output is closed (the terminal is closed).

    It is run with the output pointing to a pipe whose read end is closed:
    the writes fail and the script has to exit, instead of staying there
    drawing into the void. With a pty it did not work: the kernel SIGHUP
    was intercepted by the script itself and it exited with code 0 without
    going through its own detection.
    """
    temporary = tempfile.mkdtemp(prefix="lyrics-carousel-cierre-")
    overrides = os.path.join(temporary, "overrides.json")
    # The script writes its diagnostics into the cache: without isolating
    # XDG_CACHE_HOME the self-test leaves a debug.log in the real cache.
    environment = test_environment(temporary)
    environment["LYRICS_CAROUSEL_OVERRIDES"] = overrides
    read_end, escritura = os.pipe()
    os.close(read_end)  # the reading end is closed: writing fails
    process = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "lyrics-carousel"), "--demo"],
        stdout=escritura,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        env=environment,
    )
    os.close(escritura)
    code = None
    try:
        code = process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
    # 0: normal exit. 120: Python warns that it could not flush the output
    # on exit (normal if it was closed). What is not acceptable is hanging
    # (no code) or dying from a signal (negative code).
    check(
        "the script exits when the output is closed",
        code is not None and code >= 0,
        "exit code %s" % code,
    )
    shutil.rmtree(temporary, ignore_errors=True)


def test_environment(base: str) -> dict:
    """Isolated environment: no variable can point to the real state.

    paths.state_dir() prioritizes LYRICS_CAROUSEL_STATE and NOCTALIA_STATE_HOME
    over XDG_STATE_HOME, and paths.overrides_path() prioritizes
    LYRICS_CAROUSEL_OVERRIDES: isolating only HOME (or only XDG_STATE_HOME)
    is not enough. With any of those variables defined (the usual case on a
    desktop) the dump writes to the real settings and wipes the user's
    overrides layer.

    Every test that launches the script or the helper uses this function:
    the isolation has to live in a single place, or it gets forgotten
    somewhere.
    """
    env = dict(os.environ)
    state_value = os.path.join(base, ".local", "state")
    env["HOME"] = base
    env["XDG_STATE_HOME"] = state_value
    env["NOCTALIA_STATE_HOME"] = state_value
    env["XDG_CACHE_HOME"] = os.path.join(base, ".cache")
    env["LYRICS_CAROUSEL_STATE"] = os.path.join(state_value, "noctalia")
    env["LYRICS_CAROUSEL_OVERRIDES"] = os.path.join(
        state_value,
        "noctalia",
        "plugins",
        "data",
        "faminec",
        "lyrics-carousel",
        "overrides.json",
    )
    # The subprocesses import paths/graphics/image_renderer: without this
    # they would leave bin/__pycache__/*.pyc in the plugin.
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.pop("COLUMNS", None)
    env.pop("LINES", None)
    return env


def test_helper_dump(fake_home: str) -> dict:
    """Runs the helper with an override and its dump into settings.toml.

    It is split into its own function so that the tests can repeat it with
    a different environment (for example, with XDG_STATE_HOME pointing to
    the "real" state) and check that they do not touch it.

    Returns a dictionary with what happened.
    """
    outcome = {
        "crea_directorio": False,
        "vuelca": False,
        "detalle": "",
        "settings": "",
        "env": {},
    }
    fake_state = os.path.join(fake_home, ".local", "state", "noctalia")
    os.makedirs(fake_state, exist_ok=True)
    fake_settings = os.path.join(fake_state, "settings.toml")
    with open(fake_settings, "w", encoding="utf-8") as handle:
        handle.write("")
    env = test_environment(fake_home)
    outcome["env"] = env
    try:
        result = subprocess.run(
            [sys.executable, HELPER, "override", "marker", "true", "bool"],
            capture_output=True,
            text=True,
            timeout=15,
            env=env,
        )
        fake_dir = os.path.join(
            fake_home,
            ".local/state/noctalia/plugins/data/faminec/lyrics-carousel",
        )
        outcome["crea_directorio"] = result.returncode == 0 and os.path.isdir(fake_dir)
        outcome["detalle"] = result.stderr.strip()[:120]
        # The dump is always attempted: if the helper could not write, the
        # merge will fail too and it will be noticed anyway. This way the
        # test reproduces the dangerous case: with the real state in
        # XDG_STATE_HOME, the dump happens there and not in the temporary one.
        merge = subprocess.run(
            [sys.executable, HELPER, "merge"],
            capture_output=True,
            text=True,
            timeout=15,
            env=env,
        )
        with open(fake_settings, encoding="utf-8") as handle:
            outcome["settings"] = handle.read()
        outcome["vuelca"] = merge.returncode == 0 and "marker = true" in outcome["settings"]
        outcome["detalle"] = merge.stderr.strip()[:120]
    except (OSError, subprocess.SubprocessError) as error:
        outcome["detalle"] = repr(error)[:120]
    return outcome


def check_real_state_is_untouched():
    """The self-test cannot write to the real state of the user.

    paths.state_dir() prioritizes LYRICS_CAROUSEL_STATE and NOCTALIA_STATE_HOME
    over XDG_STATE_HOME, and paths.overrides_path() prioritizes
    LYRICS_CAROUSEL_OVERRIDES. With any of those variables defined (the
    usual case on a desktop) the dump writes to the real settings and wipes
    the user's overrides layer.

    The test proves both halves: without isolation the dump DOES reach the
    trap (otherwise checking that it does not reach it would prove
    nothing), and with the isolation the trap is left intact.
    """
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-estado-") as temporary:
        trap = os.path.join(temporary, "estado-real")
        data = os.path.join(
            trap, "noctalia", "plugins", "data", "faminec", "lyrics-carousel"
        )
        os.makedirs(data, exist_ok=True)
        settings = os.path.join(trap, "noctalia", "settings.toml")
        overrides = os.path.join(data, "overrides.json")
        content = '[plugin_settings."faminec/lyrics-carousel"]\nfont_size = 22\n'

        def prepare_trap():
            with open(settings, "w", encoding="utf-8") as handle:
                handle.write(content)
            with open(overrides, "w", encoding="utf-8") as handle:
                json.dump({"font_size": 22}, handle)

        prepare_trap()

        # 1) The user environment: the real state lives in the variables
        #    that paths.py prioritizes. Without isolation, the dump reaches
        #    there (and wipes the overrides layer).
        hostile = dict(os.environ)
        hostile["NOCTALIA_STATE_HOME"] = trap
        hostile["XDG_STATE_HOME"] = trap
        hostile["LYRICS_CAROUSEL_STATE"] = os.path.join(trap, "noctalia")
        hostile["LYRICS_CAROUSEL_OVERRIDES"] = overrides
        subprocess.run(
            [sys.executable, HELPER, "override", "font_size", "30", "int"],
            capture_output=True,
            text=True,
            timeout=15,
            env=hostile,
        )
        with open(overrides, encoding="utf-8") as handle:
            override_reached = json.load(handle)
        check(
            "without isolation the dump reaches the overrides layer",
            override_reached.get("font_size") == 30,
            str(override_reached),
        )
        subprocess.run(
            [sys.executable, HELPER, "merge"],
            capture_output=True,
            text=True,
            timeout=15,
            env=hostile,
        )
        with open(settings, encoding="utf-8") as handle:
            reached = handle.read()
        check(
            "without isolation the dump reaches settings.toml",
            "font_size = 30" in reached,
            reached[:100],
        )

        # 2) With the isolation, the trap is left as it was and the dump
        #    goes to the temporary one.
        prepare_trap()
        with tempfile.TemporaryDirectory() as temporal2:
            outcome = test_helper_dump(temporal2)
        check("the dump goes to the temporary one", outcome["vuelca"], outcome["detalle"])
        with open(settings, encoding="utf-8") as handle:
            after = handle.read()
        check(
            "the self-test does not touch the real settings.toml",
            after == content,
            after[:100],
        )
        with open(overrides, encoding="utf-8") as handle:
            overrides_after = json.load(handle)
        check(
            "the self-test does not touch the real overrides layer",
            overrides_after.get("font_size") == 22,
            str(overrides_after),
        )


def check_limits_of_panel_and_script():
    """The panel and the script clip with the same ranges.

    The manifest only declares the bar icon, so the ranges no longer live
    in plugin.toml: the panel applies them before writing (lib/settings.luau)
    and the script applies them when reading them. If they diverged, the
    panel would let a value be stored that the window later discards, and
    the user would see a number that is not applied.
    """
    lib = os.path.join(os.path.dirname(HERE), "lib", "settings.luau")
    copy = {}
    try:
        with open(lib, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        check("the panel declares limits", False, repr(error)[:120])
        return
    block = re.search(r"local LIMITS = \{(.*?)\n\}", text, re.S)
    if block:
        for lyric_line in block.group(1).splitlines():
            found = re.match(
                r"\s*(\w+)\s*=\s*\{\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\}",
                lyric_line,
            )
            if found:
                copy[found.group(1)] = (
                    float(found.group(2)),
                    float(found.group(3)),
                )
    check("the panel declares limits", bool(copy), str(sorted(copy))[:120])
    if not copy:
        return

    # The copy of the script: the clips of load_settings.
    try:
        with open(os.path.join(HERE, "lyrics-carousel"), encoding="utf-8") as handle:
            script_source = handle.read()
    except OSError as error:
        check("the script can be read", False, repr(error)[:120])
        return
    crops = {}
    for found in re.finditer(
        r'cfg\["(\w+)"\]\s*=\s*max\(\s*(-?[\d.]+)\s*,\s*min\(\s*(-?[\d.]+)\s*,',
        script_source,
    ):
        crops[found.group(1)] = (
            float(found.group(2)),
            float(found.group(3)),
        )
    check(
        "the script clips with the panel ranges",
        crops == copy,
        f"script={sorted(crops.items())} panel={sorted(copy.items())}",
    )

    # The helper no longer clips ranges: the manifest does not declare them.
    # What it keeps is the format (patterns) and the atomic write. Checking
    # that it does NOT clip is as important as the opposite: if someone puts
    # the limits back in the manifest, the helper would silently lose values.
    import importlib.util

    spec = importlib.util.spec_from_file_location("set_setting_sin_tomllib", HELPER)
    helper = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(helper)
    except Exception as error:  # noqa: BLE001
        check("the helper can be loaded", False, repr(error)[:120])
        return
    check(
        "the helper has a fallback to read the limits",
        hasattr(helper, "manifest_limits_without_tomllib"),
    )
    if not hasattr(helper, "manifest_limits_without_tomllib"):
        return

    # The fallback without tomllib keeps reading whatever the manifest has:
    # it is tested with a fake manifest because the real one declares no ranges.
    with tempfile.NamedTemporaryFile(
        "w", suffix=".toml", delete=False, encoding="utf-8"
    ) as handle:
        handle.write(
            "[[setting]]\n"
            'key = "font_size"\n'
            "min = 6\n"
            "max = 96\n"
            "\n"
            "[[panel]]\n"
            "min = 1\n"
            "max = 2\n"
        )
        simple_manifest = handle.name
    try:
        if helper.tomllib is not None:
            with open(simple_manifest, "rb") as handle:
                data = helper.tomllib.load(handle)
            with_tomllib = {
                campo["key"]: (campo.get("min"), campo.get("max"))
                for campo in data.get("setting", [])
                if campo.get("min") is not None or campo.get("max") is not None
            }
            check(
                "without tomllib the same limits are read",
                helper.manifest_limits_without_tomllib(simple_manifest) == with_tomllib,
                f"regex={sorted(helper.manifest_limits_without_tomllib(simple_manifest).items())}"
                f" tomllib={sorted(with_tomllib.items())}",
            )

        # The fallback cannot rely on the manifest using only the simplest
        # format: any block that is not [[setting]] must cut the previous
        # setting, and the values may be in single quotes, with a + sign or
        # in scientific notation.
        with tempfile.NamedTemporaryFile(
            "w", suffix=".toml", delete=False, encoding="utf-8"
        ) as handle:
            handle.write(
                "[[setting]]\n"
                'key = "font_size"\n'
                "min = +6\n"
                "max = 1e2\n"
                "\n"
                "[[panel]]\n"
                "min = 1\n"
                "max = 2\n"
                "\n"
                "[[setting]]\n"
                "key = 'active_scale'\n"
                "min = 1.0\n"
                "max = 2.5\n"
            )
            odd_manifest = handle.name
        try:
            odd_limits = helper.manifest_limits_without_tomllib(odd_manifest)
        finally:
            os.unlink(odd_manifest)
        check(
            "the fallback cuts on any block and accepts other formats",
            odd_limits == {"font_size": (6, 100), "active_scale": (1, 2.5)},
            str(odd_limits),
        )

        # And the clipping of the helper works if the manifest really brings them.
        original = helper._MANIFEST_LIMITS
        try:
            helper._MANIFEST_LIMITS = {"font_size": (6, 96)}
            check(
                "with limits in the manifest the helper clips",
                helper.clamp_value("font_size", 9999) == 96,
                str(helper.clamp_value("font_size", 9999)),
            )
        finally:
            helper._MANIFEST_LIMITS = original
    finally:
        os.unlink(simple_manifest)

    # What really protects the user: an out-of-range value that
    # reaches settings.toml (an IPC, the file edited by hand) is clipped
    # when it is read.
    def load_config(values: dict) -> dict:
        with tempfile.TemporaryDirectory(prefix="lyrics-carousel-limites-") as temporary:
            with temporary_env(
                {
                    "XDG_CACHE_HOME": os.path.join(temporary, "cache"),
                }
            ), temporary_state(temporary) as destination:
                with open(
                    os.path.join(destination, "settings.toml"), "w", encoding="utf-8"
                ) as handle:
                    handle.write('[plugin_settings."faminec/lyrics-carousel"]\n')
                    for setting_key, setting_value in values.items():
                        handle.write(f"{setting_key} = {setting_value}\n")
                mod = script_module()
                return mod.load_settings()

    for etiqueta, elegir in (
        ("arriba", lambda low, height: height),
        ("abajo", lambda low, height: low),
    ):
        values = {}
        for setting_key, (low, height) in copy.items():
            values[setting_key] = elegir(low, height) + (1000 if etiqueta == "arriba" else -1000)
        cfg = load_config(values)
        for setting_key, (low, height) in copy.items():
            expected = height if etiqueta == "arriba" else low
            obtained = cfg.get(setting_key)
            check(
                f"the script clips {setting_key} by {etiqueta}",
                obtained is not None and abs(float(obtained) - float(expected)) < 0.001,
                str(obtained),
            )


def check_helper_formats():
    """The helper validates the format, not only the ranges.

    The panel and the widget IPC apply the patterns of lib/settings.luau
    (glyph, color, family). The helper is another write path: if it did not
    validate, any call could leave a non-existent icon or an invalid color
    in the settings. A rejected value is stored neither in the overrides nor
    in settings.toml.
    """
    cases = (
        ("glyph", "headphones", "string", True),
        ("glyph", "music_note", "string", False),
        ("glyph", "Music!", "string", False),
        ("custom_color", "#12ab34", "string", True),
        ("custom_color", "#fff", "string", False),
        ("custom_color", "rojo", "string", False),
        ("font_family", "Iosevka", "string", True),
        ("font_family", "", "string", False),
        ("font_family", "Iosevka\nMono", "string", False),
    )
    for setting_key, setting_value, tipo, valido in cases:
        with tempfile.TemporaryDirectory(prefix="lyrics-carousel-formatos-") as temporary:
            env = test_environment(temporary)
            state_value = os.path.join(temporary, ".local", "state", "noctalia")
            os.makedirs(state_value, exist_ok=True)
            settings_path = os.path.join(state_value, "settings.toml")
            with open(settings_path, "w", encoding="utf-8") as handle:
                handle.write("")
            process = subprocess.run(
                [sys.executable, HELPER, "persist", setting_key, setting_value, tipo],
                capture_output=True,
                text=True,
                timeout=15,
                env=env,
            )
            overrides_path = os.path.join(
                state_value,
                "plugins",
                "data",
                "faminec",
                "lyrics-carousel",
                "overrides.json",
            )
            try:
                with open(overrides_path, encoding="utf-8") as handle:
                    overrides = json.load(handle)
            except (OSError, ValueError):
                overrides = {}
            settings_file = read_settings(settings_path)
            if valido:
                check(
                    f"the helper saves {setting_key}={setting_value!r}",
                    process.returncode == 0
                    and settings_file.get(setting_key) == setting_value,
                    f"code={process.returncode} settings={settings_file.get(setting_key)!r}",
                )
            else:
                check(
                    f"the helper rejects {setting_key}={setting_value!r}",
                    process.returncode != 0
                    and setting_key not in overrides
                    and setting_key not in settings_file,
                    f"code={process.returncode} overrides={overrides!r} settings={settings_file.get(setting_key)!r}",
                )


def check_helper_accepts_the_new_keys():
    """The helper knows every key the panel and the script use.

    The helper is another write path (the one of the panel and the one of
    the window shortcuts). If a key is missing from its list, it answers
    that the key is unknown and the setting is silently lost: that is why
    the visualizer switch was not being saved.
    """
    cases = (
        ("visualizer", "false", "bool", False),
        ("translate_lyrics", "true", "bool", True),
        ("visualizer_position", "left", "string", "left"),
        ("visualizer_position", "arriba", "string", None),
        ("visualizer_coverage", "40", "int", 40),
    )
    for setting_key, setting_value, tipo, expected in cases:
        with tempfile.TemporaryDirectory(prefix="lyrics-carousel-claves-") as temporary:
            env = test_environment(temporary)
            state_value = os.path.join(temporary, ".local", "state", "noctalia")
            os.makedirs(state_value, exist_ok=True)
            settings_path = os.path.join(state_value, "settings.toml")
            with open(settings_path, "w", encoding="utf-8") as handle:
                handle.write("")
            process = subprocess.run(
                [sys.executable, HELPER, "persist", setting_key, setting_value, tipo],
                capture_output=True,
                text=True,
                timeout=15,
                env=env,
            )
            settings_file = read_settings(settings_path)
            if expected is None:
                check(
                    f"the helper rejects {setting_key}={setting_value!r}",
                    process.returncode != 0 and setting_key not in settings_file,
                    f"code={process.returncode} settings={settings_file.get(setting_key)!r}",
                )
            else:
                check(
                    f"the helper saves {setting_key}={setting_value!r}",
                    process.returncode == 0 and settings_file.get(setting_key) == expected,
                    f"code={process.returncode} settings={settings_file.get(setting_key)!r}",
                )


def main(argv):
    verbose = "--verbose" in argv

    # Sandbox for the whole self-test.
    #
    # The variables the user may have to point at the Noctalia state
    # (NOCTALIA_STATE_HOME, XDG_STATE_HOME, LYRICS_CAROUSEL_STATE and
    # LYRICS_CAROUSEL_OVERRIDES) are replaced with temporary paths before
    # anything is done. That way no test, not even the ones that launch the
    # script as a subprocess, can write to the real settings: with
    # LYRICS_CAROUSEL_STATE defined (which is what makes paths.py work) the
    # dump of the helper reached the real state.
    box = tempfile.mkdtemp(prefix="lyrics-carousel-autotest-")
    box_state = os.path.join(box, ".local", "state")
    os.makedirs(os.path.join(box_state, "noctalia"), exist_ok=True)
    os.environ["HOME"] = box
    os.environ["XDG_STATE_HOME"] = box_state
    os.environ["NOCTALIA_STATE_HOME"] = box_state
    os.environ["XDG_CACHE_HOME"] = os.path.join(box, ".cache")
    os.environ["LYRICS_CAROUSEL_STATE"] = os.path.join(box_state, "noctalia")
    os.environ["LYRICS_CAROUSEL_OVERRIDES"] = os.path.join(
        box_state,
        "noctalia",
        "plugins",
        "data",
        "faminec",
        "lyrics-carousel",
        "overrides.json",
    )
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    # Bytecode that may already be there (from a previous run): at the end
    # only the new .pyc files are reported, the ones this self-test leaves.
    cache_plugin = os.path.join(HERE, "__pycache__")
    bytecode_before = (
        set(os.listdir(cache_plugin)) if os.path.isdir(cache_plugin) else set()
    )

    # 1) the helper has to be next to the script (real path, not the one of
    #    the symlink it can be launched through).
    check("helper present", os.path.isfile(HELPER), HELPER)
    check("helper executable", os.access(HELPER, os.X_OK))

    # 2) the data directory can be created and written to. It is done in a
    #    temporary one: the self-test cannot create or write in the real data
    #    directory of the user.
    with tempfile.TemporaryDirectory(prefix="lyrics-carousel-datos-") as temporary:
        test_data = os.path.join(temporary, "datos")
        try:
            os.makedirs(test_data, exist_ok=True)
            created = os.path.isdir(test_data)
        except OSError as error:
            created = False
            check("data directory", False, str(error))
        if created:
            check("data directory", True, test_data)

            # 3) the data directory can be used (write and read).
            probe = os.path.join(test_data, "selftest.json")
            try:
                with open(probe, "w", encoding="utf-8") as handle:
                    json.dump({"selftest": True}, handle)
                with open(probe, encoding="utf-8") as handle:
                    data = json.load(handle)
                os.remove(probe)
                check("overrides write", data.get("selftest") is True)
            except (OSError, ValueError) as error:
                check("overrides write", False, str(error))
                try:
                    os.remove(probe)
                except OSError:
                    pass

    # 3-bis) the real data directory is only looked at, never written to:
    #     if it does not exist yet, the plugin will create it when writing.
    if os.path.isdir(DATA_DIR):
        check("real data directory writable", os.access(DATA_DIR, os.W_OK), DATA_DIR)
    else:
        parent = os.path.dirname(DATA_DIR)
        check(
            "real data directory writable",
            os.path.isdir(parent) and os.access(parent, os.W_OK),
            parent,
        )

    # 4) the helper answers, creates the directory if missing and dumps the
    #    overrides into settings.toml. All of it with a temporary HOME and
    #    the state isolated: if the real one were used, the self-test would
    #    leave the user's settings changed (the dump writes to the real
    #    settings.toml).
    with tempfile.TemporaryDirectory() as fake_home:
        outcome = test_helper_dump(fake_home)
        check(
            "the helper creates the directory",
            outcome["crea_directorio"],
            outcome["detalle"],
        )
        check(
            "the helper dumps into settings.toml",
            outcome["vuelca"],
            outcome["detalle"],
        )

    # 4b) the 'd' shortcut of the script toggles the direction and saves it.
    #     It is the proof that the script, the helper and the overrides
    #     really work together.
    check_shortcuts()

    # 4b-bis) the self-test cannot write to the real state: with
    #     XDG_STATE_HOME or NOCTALIA_STATE_HOME defined (the usual case), the
    #     dump of the helper would leave the user's settings changed.
    check_real_state_is_untouched()

    # 4c) if the terminal is closed, the script has to exit: if it stays,
    #      it keeps drawing into the void indefinitely.
    check_output_on_close()

    # 4d) the behaviour of the script: offset, search deadline for the
    #      lyrics, retry, equalizer row, state paths, window language and
    #      limits of the settings.
    check_scroll_offset()
    check_lyrics_search()
    check_lyrics_retry()
    check_image_layout()
    check_karaoke_image_pixel_by_pixel()
    check_karaoke_without_glow()
    check_karaoke_smooth_edge()
    check_handover_without_alpha_jump()
    check_fractional_size()
    check_karaoke_image_follows_the_times()
    check_real_transition()
    check_smooth_visual_transition()
    check_karaoke_entry_without_jump()
    check_frame_rhythm()
    check_first_window_fps()
    check_smooth_curve()
    check_sung_text_is_crisp()
    check_reload_by_signal()
    check_real_terminal_size()
    check_state_paths()
    check_without_text_mode()
    check_settings_limits()
    check_limits_of_panel_and_script()
    check_helper_formats()
    check_empty_title_does_not_search_again()
    check_adapter_timeout()
    check_real_times_do_not_overlap()
    check_lines_are_sorted()
    check_only_the_winner_writes_the_cache()
    check_times_per_word()
    check_fetch_prefers_the_word_timing()
    check_word_fetch_does_not_wait()
    check_lyrics_without_accents()
    check_improvement_does_not_overwrite_the_cache()
    check_cache_is_upgraded_in_the_background()
    check_result_does_not_overwrite_the_same_lyrics()
    check_lyrics_settings_state_dir()
    check_lrc_hours()
    check_lrc_minutes()
    check_lrc_decimals()
    check_karaoke_uses_real_times()
    check_estimated_times_do_not_advance_untimed_lines()
    check_estimated_times_stay_inside_the_song()
    check_geometry_is_clipped_to_the_screen()
    check_window_size_via_hyprctl()
    check_redimensionado_manual_se_guarda()
    check_text_between_angle_brackets()
    check_enhanced_lrc_to_characters()
    check_lrclib_prefers_the_enhanced_lyrics()
    check_cache_json_is_not_an_object()
    check_pause_key_survives_playerctl_failure()
    check_shortcut_is_not_reverted()
    check_panel_covers_the_manifest()
    check_centered_hints()
    check_translate_lyrics_false_default()
    check_settings_are_split()
    check_panel_attached()

    # 4e) the README documents what the manifest declares: if the manifest
    #     changes and the README does not, the store rejects the plugin.
    check_readme()

    # 5) external tools.
    for tool in ("kitty", "fc-match", "playerctl", "hyprctl"):
        check(f"tool {tool}", shutil.which(tool) is not None)

    # 6) Pillow (image mode).
    try:
        import PIL  # noqa: F401

        check("pillow", True)
    except ImportError as error:
        check("pillow", False, str(error))

    # 7) the script resolves itself with realpath: launched through the PATH
    #    symlink it still has to find its sibling modules (image_renderer,
    #    graphics) and the helper. Without this the image mode silently
    #    fell back to the text mode.
    check_diagnostics("real path", SCRIPT)
    if os.path.exists(LAUNCHER):
        check_diagnostics("symlink", LAUNCHER)
    else:
        # The PATH symlink is a convenience, not a requirement: the panel
        # launches the script by absolute path. If it is not there, it is not a failure.
        print("  (no symlink in %s: the panel uses the absolute path)" % LAUNCHER)

    # 8) the .luau files of the plugin have to compile as they are. If they
    #    used Luau syntax, the static check could not be conclusive (there
    #    is no Luau compiler) and a real error would go unnoticed: the
    #    runtime only detects it if the file is reloaded during the
    #    verification.
    compiler = ""
    for name in ("luac5.4", "luac", "luac5.3", "luac5.1", "luajit"):
        compiler = shutil.which(name) or ""
        if compiler:
            break
    if not compiler:
        check("compiler available", False, "no luac")
    else:
        bad_files = []
        for root, dirs, names in os.walk(PLUGIN_DIR):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for name in sorted(names):
                if not name.endswith(".luau"):
                    continue
                path = os.path.join(root, name)
                try:
                    result = subprocess.run(
                        [compiler, "-p", path],
                        capture_output=True,
                        text=True,
                        timeout=20,
                    )
                except (OSError, subprocess.SubprocessError) as error:
                    bad_files.append("%s (%s)" % (name, error))
                    continue
                if result.returncode != 0:
                    bad_files.append(name)
        check("the .luau files compile as they are", not bad_files, ", ".join(bad_files))

    # 9) the self-test must not leave bytecode in the directory the script is
    #    launched from.
    launcher_dir = os.path.dirname(LAUNCHER)
    cache = os.path.join(launcher_dir, "__pycache__")
    leftovers = []
    if os.path.isdir(cache):
        leftovers = [n for n in os.listdir(cache) if n.startswith("lyrics-carousel")]
    check("no bytecode in the launcher", not leftovers, ", ".join(leftovers))
    new_files = []
    if os.path.isdir(cache_plugin):
        new_files = sorted(
            name
            for name in os.listdir(cache_plugin)
            if name.endswith(".pyc") and name not in bytecode_before
        )
    check("no new bytecode in the plugin", not new_files, ", ".join(new_files))

    failed = 0
    for name, ok, detail in results:
        if not ok:
            failed += 1
        if verbose or not ok:
            print(
                "  %s %s%s"
                % ("ok " if ok else "FAIL", name, (" -> " + detail) if detail else "")
            )
    print("%d check(s), %d failure(s)" % (len(results), failed))
    shutil.rmtree(box, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
