import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from dataclasses import dataclass


ROOT = Path(__file__).resolve().parents[1]
STATES = (
    "working", "searching", "solving", "listening", "connecting", "weaving",
    "composing", "breathing", "shaping", "done",
)
ATTENTION = ("waiting", "blocked")
SIZES = (16, 20, 24, 32, 64, 96)
TIMES = (0, 1 / 60, 0.37, 1, 2 - 1e-5, 2, 2 + 1e-5, 2.37)

# The constructors only capture the actual module's native tree. Geometry and
# assertions below interpret the result; no renderer formula is duplicated.
LUAU_CAPTURE = r'''
local ui = {}
for _, kind in ipairs({"column", "row", "box", "graph", "glyph", "spacer"}) do
    ui[kind] = function(props, children)
        return {kind = kind, props = props or {}, children = children or {}}
    end
end
setmetatable(ui, {__index = function(_, name)
    error("Non-native renderer operation: ui." .. tostring(name))
end})
local function require(name)
    if name == "ui" then return ui end
    error("Unexpected renderer dependency: " .. tostring(name))
end
local function encode(value)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        assert(value == value and math.abs(value) < math.huge, "Non-finite geometry")
        return string.format("%.17g", value)
    end
    if kind == "string" then
        return '"' .. string.gsub(value, '[%z\1-\31\\"]', function(character)
            return string.format("\\u%04x", string.byte(character))
        end) .. '"'
    end
    assert(kind == "table", "Unsupported native property: " .. kind)
    local parts = {}
    if #value > 0 then
        for _, item in ipairs(value) do table.insert(parts, encode(item)) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        assert(type(key) == "string", "Non-string native property name")
        table.insert(keys, key)
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        table.insert(parts, encode(key) .. ":" .. encode(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function loadOrb()
'''


def _literal(value):
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, dict):
        return "{" + ",".join(f"{key}={_literal(item)}" for key, item in value.items()) + "}"
    return repr(value)


def _color_alpha(color):
    if isinstance(color, str) and "/" in color:
        return float(color.rsplit("/", 1)[1])
    if isinstance(color, str) and color.startswith("#") and len(color) == 9:
        return int(color[-2:], 16) / 255
    return 1.0


@dataclass(frozen=True)
class Primitive:
    kind: str
    x: float
    y: float
    width: float
    height: float
    alpha: float
    color: str
    radius: float = 0
    line_width: float = 0
    points: tuple = ()

    def extents(self):
        if self.kind == "graph":
            half = self.line_width / 2
            xs, ys = zip(*self.points)
            return min(xs) - half, min(ys) - half, max(xs) + half, max(ys) + half
        return self.x, self.y, self.x + self.width, self.y + self.height


def primitives(tree):
    """Resolve native Flex positions, including negative-gap overlay cells."""
    result = []

    def walk(node, x, y, width, height, inherited_alpha):
        kind, props = node["kind"], node["props"]
        width, height = props.get("width", width), props.get("height", height)
        alpha = inherited_alpha * props.get("opacity", 1)
        if kind == "graph":
            values = props["values"]
            # Native graph values are normalized bottom-to-top samples.
            points = tuple((x + width * index / (len(values) - 1), y + height * (1 - value))
                           for index, value in enumerate(values))
            color = props.get("color", "white")
            result.append(Primitive(kind, x, y, width, height, alpha * _color_alpha(color),
                                    color, line_width=props.get("lineWidth", 1), points=points))
            if props.get("fillOpacity", 0) != 0:
                raise AssertionError("Graph area fill is not supported by the native line contract")
        elif kind in ("box", "glyph"):
            color = props.get("fill" if kind == "box" else "color")
            if color is not None:
                result.append(Primitive(kind, x, y, width, height, alpha * _color_alpha(color),
                                        color, radius=props.get("radius", 0)))
        elif kind not in ("column", "row", "spacer"):
            raise AssertionError(f"Unexpected native node: {kind}")
        children = node.get("children", [])
        if not children:
            return
        if kind not in ("column", "row", "box"):
            raise AssertionError(f"Unexpected children on native {kind}")
        horizontal = kind == "row"
        ph, pv = props.get("paddingH", 0), props.get("paddingV", 0)
        inner_w, inner_h = width - 2 * ph, height - 2 * pv
        dimensions = [(child["props"].get("width", inner_w),
                       child["props"].get("height", inner_h)) for child in children]
        gap = props.get("gap", 0)
        occupied = sum(d[0 if horizontal else 1] for d in dimensions) + gap * (len(children) - 1)
        remaining = (inner_w if horizontal else inner_h) - occupied
        factor = {"start": 0, "center": 0.5, "end": 1}
        offset = remaining * factor[props.get("justify", "start")]
        for child, (cw, ch) in zip(children, dimensions):
            cross = ((inner_h - ch) if horizontal else (inner_w - cw)) * factor[props.get("align", "start")]
            walk(child, x + ph + (offset if horizontal else cross),
                 y + pv + (cross if horizontal else offset), cw, ch, alpha)
            offset += (cw if horizontal else ch) + gap

    walk(tree, 0, 0, tree["props"]["width"], tree["props"]["height"], 1)
    return result


def _segment_distance(x, y, first, second):
    ax, ay = first
    bx, by = second
    length2 = (bx - ax) ** 2 + (by - ay) ** 2
    fraction = 0 if length2 == 0 else max(0, min(1, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / length2))
    return math.hypot(x - ax - fraction * (bx - ax), y - ay - fraction * (by - ay))


def coverage(shapes, size, resolution=64):
    """Deterministic antialiased geometry coverage, independent of theme colors."""
    pixels = [0.0] * (resolution * resolution)
    scale = size / resolution
    for shape in shapes:
        if shape.alpha <= 0:
            continue
        left, top, right, bottom = shape.extents()
        columns = range(max(0, math.floor(left / scale - 1)), min(resolution, math.ceil(right / scale + 1)))
        rows = range(max(0, math.floor(top / scale - 1)), min(resolution, math.ceil(bottom / scale + 1)))
        for row in rows:
            for column in columns:
                x, y = (column + 0.5) * scale, (row + 0.5) * scale
                if shape.kind == "graph":
                    distance = min(_segment_distance(x, y, a, b) for a, b in zip(shape.points, shape.points[1:]))
                    signed = distance - shape.line_width / 2
                else:
                    # Signed distance to a rounded rectangle; dots have half-size radius.
                    radius = min(shape.radius, shape.width / 2, shape.height / 2)
                    dx = abs(x - shape.x - shape.width / 2) - shape.width / 2 + radius
                    dy = abs(y - shape.y - shape.height / 2) - shape.height / 2 + radius
                    signed = math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius
                alpha = max(0, min(1, 0.5 - signed / scale)) * shape.alpha
                index = row * resolution + column
                pixels[index] += (1 - pixels[index]) * alpha
    return tuple(pixels)


def visual_distance(first, second):
    return sum(abs(a - b) for a, b in zip(first, second)) / max(1, sum(first), sum(second))


class OrbGeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        executable = shutil.which("luau")
        if executable is None:
            raise unittest.SkipTest("luau executable is required to exercise the actual orb renderer")
        cls.queries = []
        for size in SIZES:
            for state in STATES + ATTENTION:
                for time in TIMES:
                    cls.queries.append(("render", {"state": state, "size": size, "time": time}))
        for size in (20, 64):
            for attention in ATTENTION:
                for time in (0, 0.37, 2.37):
                    cls.queries.append(("render", {"state": "working", "attention": attention,
                                                   "size": size, "time": time}))
            for opacity in (0, 0.25, 1):
                cls.queries.append(("render", {"state": "working", "size": size,
                                               "time": 0.37, "opacity": opacity}))
            values = {-2, -0.01, 0, 1e-5, 0.125, 0.25, 0.5, 0.75, 0.9, 1 - 1e-5, 1, 1.01, 2}
            for step in range(1, 8):
                values.update((step / 8 - 1e-5, step / 8 + 1e-5))
            for value in sorted(values):
                cls.queries.append(("progress", {"size": size, "value": value}))
        requests = "\n".join(f"print(encode(orb.{method}({_literal(props)})))" for method, props in cls.queries)
        source = ROOT.joinpath("orb.luau").read_text(encoding="utf-8")
        script = LUAU_CAPTURE + source + "\nend\nlocal orb = loadOrb()\n" + requests + "\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "orb_geometry_harness.luau"
            path.write_text(script, encoding="utf-8")
            result = subprocess.run([executable, str(path)], capture_output=True, text=True,
                                    timeout=60, check=False)
        if result.returncode != 0:
            raise AssertionError(f"Actual orb.luau failed in the native constructor environment:\n{result.stderr}\n{result.stdout[-2000:]}")
        trees = [json.loads(line) for line in result.stdout.splitlines()]
        if len(trees) != len(cls.queries):
            raise AssertionError(f"Expected {len(cls.queries)} native trees, received {len(trees)}")
        cls.frames = {}
        cls.images = {}
        for (method, props), tree in zip(cls.queries, trees):
            key = cls.frame_key(method, props)
            cls.frames[key] = (tree, primitives(tree))

    @staticmethod
    def frame_key(method, props):
        return method, tuple(sorted(props.items()))

    def frame(self, method="render", **props):
        return self.frames[self.frame_key(method, props)][1]

    def image(self, method="render", **props):
        key = self.frame_key(method, props)
        if key not in self.images:
            self.images[key] = coverage(self.frames[key][1], props["size"])
        return self.images[key]

    def assert_bounded(self, shapes, size):
        self.assertTrue(shapes, "Renderer emitted no native visible primitives")
        for shape in shapes:
            numbers = (shape.x, shape.y, shape.width, shape.height, shape.alpha,
                       shape.radius, shape.line_width, *shape.extents())
            self.assertTrue(all(math.isfinite(value) for value in numbers), shape)
            self.assertGreaterEqual(shape.width, 0, shape)
            self.assertGreaterEqual(shape.height, 0, shape)
            self.assertGreaterEqual(shape.alpha, 0, shape)
            self.assertLessEqual(shape.alpha, 1, shape)
            left, top, right, bottom = shape.extents()
            self.assertGreaterEqual(left, -1e-6, shape)
            self.assertGreaterEqual(top, -1e-6, shape)
            self.assertLessEqual(right, size + 1e-6, shape)
            self.assertLessEqual(bottom, size + 1e-6, shape)

    def test_native_geometry_stays_inside_requested_square(self):
        for method, props in self.queries:
            with self.subTest(method=method, **props):
                tree, shapes = self.frames[self.frame_key(method, props)]
                self.assertEqual(tree["props"]["width"], props["size"])
                self.assertEqual(tree["props"]["height"], props["size"])
                self.assert_bounded(shapes, props["size"])

    def test_every_orb_state_has_visible_geometry_and_evolving_motion(self):
        for size in (20, 64):
            for state in STATES + ATTENTION:
                with self.subTest(size=size, state=state):
                    images = [self.image(state=state, size=size, time=time) for time in (0, 1 / 60, 0.37, 1)]
                    self.assertTrue(all(sum(image) > 0.01 for image in images))
                    self.assertGreater(max(visual_distance(images[0], image) for image in images[1:]), 0.005,
                                       "Time changed but consumer-visible geometry did not")

    def test_distinct_states_have_distinct_visible_geometries(self):
        for size in (20, 64):
            signatures = {state: tuple(self.image(state=state, size=size, time=time)
                                      for time in (0, 0.37, 1)) for state in STATES}
            for index, first in enumerate(STATES):
                for second in STATES[index + 1:]:
                    with self.subTest(size=size, first=first, second=second):
                        self.assertGreater(max(visual_distance(a, b) for a, b in zip(signatures[first], signatures[second])),
                                           0.005, "Two named states have the same visible geometry")

    def test_motion_is_continuous_through_former_two_second_loop_seam(self):
        for size in (20, 64):
            for state in STATES + ATTENTION:
                with self.subTest(size=size, state=state):
                    before = self.image(state=state, size=size, time=2 - 1e-5)
                    seam = self.image(state=state, size=size, time=2)
                    after = self.image(state=state, size=size, time=2 + 1e-5)
                    self.assertLess(visual_distance(before, seam), 0.002)
                    self.assertLess(visual_distance(seam, after), 0.002)

    def test_attention_symbols_and_overlays_are_visible(self):
        for size in (20, 64):
            base = self.image(state="working", size=size, time=0.37)
            symbols = []
            for attention in ATTENTION:
                with self.subTest(size=size, attention=attention):
                    symbol = self.frame(state=attention, size=size, time=0.37)
                    self.assertGreater(sum(self.image(state=attention, size=size, time=0.37)), 0.01)
                    symbols.append({shape.color for shape in symbol if shape.alpha > 0})
                    overlay = self.image(state="working", attention=attention, size=size, time=0.37)
                    self.assertGreater(visual_distance(base, overlay), 0.005)
            self.assertNotEqual(symbols[0], symbols[1], "Waiting and blocked attention must remain distinguishable")

    def test_group_opacity_changes_visible_geometry_without_moving_it(self):
        for size in (20, 64):
            images = [self.image(state="working", size=size, time=0.37, opacity=value) for value in (0, 0.25, 1)]
            self.assertEqual(sum(images[0]), 0)
            self.assertGreater(sum(images[1]), 0)
            self.assertLess(sum(images[1]), sum(images[2]))
            dim = self.frame(state="working", size=size, time=0.37, opacity=0.25)
            full = self.frame(state="working", size=size, time=0.37, opacity=1)
            self.assertEqual([shape.extents() for shape in dim], [shape.extents() for shape in full])

    def test_progress_clamps_and_has_distinct_partial_completion(self):
        for size in (20, 64):
            with self.subTest(size=size):
                empty = self.image("progress", size=size, value=0)
                full = self.image("progress", size=size, value=1)
                self.assertGreater(sum(empty), 0, "Empty progress still needs a visible track")
                self.assertGreater(sum(full), 0)
                for value in (-2, -0.01):
                    self.assertEqual(self.image("progress", size=size, value=value), empty)
                for value in (1.01, 2):
                    self.assertEqual(self.image("progress", size=size, value=value), full)
                partials = [self.image("progress", size=size, value=value) for value in (0.125, 0.25, 0.5, 0.75)]
                for earlier, later in zip([empty] + partials, partials + [full]):
                    self.assertGreater(visual_distance(earlier, later), 0.005)
                # More normalized progress must visibly add arc coverage.
                masses = [sum(image) for image in [empty] + partials]
                self.assertTrue(all(later > earlier for earlier, later in zip(masses, masses[1:])), masses)

    def test_progress_is_continuous_at_endpoints_and_former_eighth_steps(self):
        for size in (20, 64):
            for before, after in [(0, 1e-5), (1 - 1e-5, 1)] + [
                    (step / 8 - 1e-5, step / 8 + 1e-5) for step in range(1, 8)]:
                with self.subTest(size=size, before=before, after=after):
                    self.assertLess(visual_distance(self.image("progress", size=size, value=before),
                                                    self.image("progress", size=size, value=after)), 0.002,
                                    "Normalized progress snaps at a boundary")


if __name__ == "__main__":
    unittest.main()
