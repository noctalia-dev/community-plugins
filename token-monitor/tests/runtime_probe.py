#!/usr/bin/env python3
"""Private headless Noctalia acceptance; fixture by default, real Hub read only.

Only copied plugin entries are instrumented. No desktop config, D-Bus session,
user compositor, real credentials or raw provider data are written to evidence.
Requires existing Python, noctalia, sway and grim; installs nothing.
"""
import argparse
from datetime import date, timedelta
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import struct
import zlib
import shutil
import subprocess
import tempfile
import threading
import time
import tomllib

PLUGIN_ID = "shangshui0302/token-monitor"
SWAY = shutil.which("sway")


def fixture_dashboard(reordered=False, missing_pin=False):
    """Synthetic public wire data, never a snapshot of a user's Hub."""
    def account(key, provider, label, windows, stale=False):
        return {"provider": provider, "accountKey": key, "accountLabel": label,
                "sourceDeviceId": "fixture-device",
                "status": "ok", "stale": stale, "updatedAt": "2026-10-22T00:00:00Z", "windows": windows}
    def window(label, value, balance=False, kind="weekly"):
        return ({"label": label, "kind": "billing", "remaining": value, "currency": "CNY"} if balance else
                {"label": label, "kind": kind, "remainingPercent": value, "resetsAt": "2026-10-29T00:00:00Z"})
    providers = [
        account("fixture-1", "codex", "Fixture zero", [window("5 hours", 0, kind="session"), window("Weekly", 62)]),
        account("fixture-2", "deepseek", "Fixture balance", [window("Balance", 0, True)]),
        account("fixture-3", "antigravity", "Fixture primary", [window("Claude", 23), window("Gemini", 68), window("Gemini Flash", 41)], True),
        account("fixture-4", "antigravity", "Fixture secondary", [window("Claude", 72), window("Gemini", 0)]),
    ]
    if reordered:
        providers[2], providers[3] = providers[3], providers[2]
    if missing_pin:
        providers = [row for row in providers if row["accountKey"] != "fixture-3"]
    periods = {}
    for index, name in enumerate(("today", "month", "allTime"), 1):
        model = "Synthetic " + name + " model"
        sessions = {}
        # Thirteen records force paging even with the largest native page size.
        for number in range(1, 14):
            key = "codex:synthetic-session-" + str(number)
            sessions[key] = {"client": "codex", "sessionId": "synthetic-session-" + str(number),
                "title": "Synthetic private title " + str(number), "projectId": "synthetic-project-id",
                "projectLabel": "Synthetic private project", "sessionKind": "interactive",
                "startedAt": "2026-10-22T00:00:00Z", "lastUsedAt": f"2026-10-22T00:{number:02d}:00Z",
                "totalTokens": number * 100, "costUsd": number / 100, "messageCount": number,
                "inputTokens": 20, "outputTokens": 30, "cacheReadTokens": 40, "cacheWriteTokens": 10,
                "reasoningTokens": 5, "contextTokens": 3000, "contextWindow": 100000,
                "timedOutputTokens": 30, "timedDurationMs": 1000,
                "models": {model: number * 100}, "modelCosts": {model: number / 100},
                "turnEnded": number % 2 == 0, "archived": False}
        periods[name] = {"capabilities": {"tokenComponents": True, "throughput": True},
            "totalTokens": index * 12000, "costUsd": index * 1.25,
            "outputTokens": 3000, "cacheReadTokens": 4000, "cacheWriteTokens": 1000,
            "unclassifiedTokens": 0, "models": {model: index * 12000, "Synthetic zero model": 0},
            "modelCosts": {model: index * 1.25, "Synthetic zero model": 0},
            "modelOutputs": {model: 3000}, "modelCacheReads": {model: 4000}, "modelCacheWrites": {model: 1000},
            # An intentionally populated allTime field must still never be presented as supported.
            "sessions": sessions}
    return {"devices": [], "periods": periods, "limits": {"providers": providers},
            "sessionDetailsOmitted": {"month": 2}, "historyRevision": "synthetic-revision"}


def fixture_history():
    def bucket(field, date, tokens):
        return {field: date, "tokens": tokens, "cost": tokens / 10000,
                "messages": tokens // 100, "activeTimeMs": tokens * 10,
                "tokenComponentsAvailable": True, "outputTokens": tokens // 4,
                "cacheReadTokens": tokens // 4, "cacheWriteTokens": 0, "unclassifiedTokens": 0,
                "perClient": {"codex": {"tokens": tokens, "cost": tokens / 10000, "messages": tokens // 100}},
                "perModel": {"Synthetic history model": {"tokens": tokens, "cost": tokens / 10000}}}
    return {"daily": [bucket("date", "2026-10-20", 0), bucket("date", "2026-10-21", 12000),
                      bucket("date", "2026-10-22", 6000)],
            "monthly": [bucket("month", "2026-09", 0), bucket("month", "2026-10", 18000)],
            "summary": {"totalTokens": 18000, "totalCost": 1.8, "activeDays": 2, "currentStreak": 2,
                        "longestStreak": 2, "peakDayTokens": 12000, "messages": 180,
                        "activeTimeMs": 180000, "favoriteModel": "Synthetic history model"}}


def fixture_heatmap_history(today=None):
    """Rich synthetic 26-week activity; no user data or wall-clock randomness."""
    today = today or date.today()
    base = fixture_history()
    template = base["daily"][1]
    rows = []
    # Reserve recent days for explicit-zero, recorded, unknown and missing checks.
    for offset in range(181, -1, -1):
        if offset == 3 or (offset > 3 and offset % 11 == 0):
            continue
        tokens = 0 if offset == 2 else (1 + (offset * 7) % 23) * 1000
        row = dict(template, date=(today - timedelta(days=offset)).isoformat(),
                   tokens=tokens, cost=tokens / 10000, messages=tokens // 100,
                   activeTimeMs=tokens * 10, outputTokens=tokens // 4,
                   cacheReadTokens=tokens // 4,
                   perClient={"codex": {"tokens": tokens, "cost": tokens / 10000}},
                   perModel={"Synthetic history model": {"tokens": tokens, "cost": tokens / 10000}})
        if offset == 0 or (offset > 3 and offset % 13 == 0):
            row.pop("messages")  # Unknown must remain distinct from explicit zero.
        rows.append(row)
    monthly = {}
    for row in rows:
        month = row["date"][:7]
        aggregate = monthly.setdefault(month, {"month": month, "tokens": 0, "cost": 0, "messages": 0})
        for metric in ("tokens", "cost", "messages"):
            aggregate[metric] += row.get(metric, 0)
    base["daily"], base["monthly"] = rows, list(monthly.values())
    base["summary"].update(totalTokens=sum(r["tokens"] for r in rows),
                           totalCost=sum(r["cost"] for r in rows),
                           activeDays=sum(r["tokens"] > 0 for r in rows))
    return base


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}



def png_region_means(path, regions):
    """Read grim's 8-bit RGB(A) PNG using only the standard library."""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "invalid screenshot PNG"
    offset, compressed = 8, bytearray()
    while offset < len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + size]
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and color in (2, 6) and not interlace, "unsupported screenshot PNG"
        elif kind == b"IDAT":
            compressed.extend(body)
        offset += size + 12
    channels = 3 if color == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    previous = bytearray(stride)
    sums = {name: [0, 0, 0] for name in regions}
    for y in range(min(height, max(ry + rh for _, ry, _, rh in regions.values()))):
        start = y * (stride + 1)
        method, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            if method == 1:
                predictor = left
            elif method == 2:
                predictor = up
            elif method == 3:
                predictor = (left + up) // 2
            elif method == 4:
                estimate = left + up - upper_left
                distances = [abs(estimate - value) for value in (left, up, upper_left)]
                predictor = (left, up, upper_left)[distances.index(min(distances))]
            else:
                assert method == 0, "unsupported PNG filter"
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        for name, (rx, ry, rw, rh) in regions.items():
            assert 0 <= rx < rx + rw <= width and 0 <= ry < ry + rh <= height
            if ry <= y < ry + rh:
                for x in range(rx, rx + rw):
                    for channel in range(3):
                        sums[name][channel] += row[x * channels + channel]
        previous = row
    return {name: [round(value / (regions[name][2] * regions[name][3]), 4) for value in total]
            for name, total in sums.items()}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plugin", nargs="?", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--sway", default=SWAY)
    parser.add_argument("--hub-url", help="Existing Hub URL: disables fixture and failure mutation")
    parser.add_argument("--credentials-file", type=Path, help="Read existing credentials through plugin; never copy to evidence")
    parser.add_argument("--discover-credentials", action="store_true", help="Real local Hub: use production automatic discovery, without copying credentials")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--no-screenshot", action="store_true", help="Skip fixture screenshots; real Hub screenshots are always disabled")
    parser.add_argument("--settings-json", default="{}", help="Public presentation settings as a JSON object; applied through native plugin_settings")
    parser.add_argument("--exercise-provider-icons", action="store_true", help="Separate fixture-only all-provider native card, pinned-bar and icon-gallery acceptance")
    parser.add_argument("--exercise-ui", action="store_true", help="Drive fixture panel handlers through test-only IPC and verify native trees")
    parser.add_argument("--capture-settings", action="store_true", help="Open native plugin settings and retain a fixture-only screenshot")
    parser.add_argument("--heatmap-showcase", action="store_true", help="Use richer, strictly synthetic 26-week heatmap history")
    parser.add_argument("--capture-transitions", action="store_true", help="Fixture-only native tab transition frames and unchanged ghost-button background assertions; skips the full UI/recovery suite")
    parser.add_argument("--large-stats", action="store_true", help="Fixture-only 1.5 MiB structured stats response for native parser budget acceptance")
    parser.add_argument("--large-quotas", action="store_true", help="Fixture-only maximum supported 512 total windows, plus over-limit snapshot retention")
    parser.add_argument("--exercise-connection", choices=("automatic", "manual"), help="Separate fixture-only connection acceptance suite")
    args = parser.parse_args()
    if args.large_quotas and (args.hub_url or args.exercise_provider_icons or args.exercise_ui or args.exercise_connection
                             or args.large_stats or args.heatmap_showcase or args.capture_transitions or args.capture_settings):
        parser.error("--large-quotas is a separate fixture-only quota budget suite")
    if args.exercise_provider_icons and (args.hub_url or args.credentials_file or args.discover_credentials or args.exercise_ui
            or args.exercise_connection or args.capture_transitions or args.capture_settings or args.heatmap_showcase or args.large_stats
            or args.settings_json != "{}"):
        parser.error("--exercise-provider-icons uses its own synthetic fixture and runs separately from other suites/settings")
    catalog = read_json(args.plugin / "assets/providers.json") if args.exercise_provider_icons else {}
    icon_cases = []
    if args.exercise_provider_icons:
        rows = catalog.get("providers", [])
        if catalog.get("tokenMonitorVersion") != "0.68.0" or len(rows) != 29 or len({r["id"] for r in rows}) != 29:
            parser.error("all-provider acceptance requires the 29-provider Token Monitor 0.68.0 catalog")
        adapters = catalog.get("thirdPartyAdapters", [])
        if {row["id"] for row in adapters} != {"newapi-account", "newapi-token", "sub2api"}:
            parser.error("all-provider acceptance requires all three known third-party adapters")
        table = (args.plugin / "lib/providers.luau").read_text()
        sections = table.split("adapters =", 1)
        def expected_codepoint(section, ident):
            match = re.search(r'(?:\["' + re.escape(ident) + r'"\]|\b' + re.escape(ident) + r')\s*=\s*\{[^}]*codepoint\s*=\s*(0x[0-9A-Fa-f]+)', section)
            if not match:
                parser.error("missing reviewed provider codepoint: " + ident)
            return int(match.group(1), 16)
        icon_cases = [dict(row, caseId=row["id"], cardName=row["name"]) for row in rows]
        generic_name = next(row["name"] for row in rows if row["id"] == "thirdparty")
        icon_cases.extend(dict(row, id="thirdparty", adapterId=row["id"], caseId=row["id"], cardName=row["name"]) for row in adapters)
        for row in icon_cases:
            if row.get("brand") is not None:
                row["codepoint"] = expected_codepoint(sections[1] if row.get("adapterId") else sections[0], row.get("adapterId", row["id"]))
    if args.exercise_connection and (args.hub_url or args.exercise_ui or args.capture_transitions or args.capture_settings):
        parser.error("--exercise-connection runs separately and uses synthetic credentials only")
    if args.capture_transitions and (args.hub_url or args.no_screenshot or args.exercise_ui or args.capture_settings):
        parser.error("--capture-transitions requires fixture screenshots and runs separately from other UI suites")
    if args.discover_credentials and (not args.hub_url or args.credentials_file):
        parser.error("--discover-credentials requires --hub-url and no file override")
    if args.credentials_file and not args.hub_url or args.hub_url and not (args.credentials_file or args.discover_credentials):
        parser.error("--hub-url requires --credentials-file or --discover-credentials")
    if args.large_stats and args.hub_url:
        parser.error("--large-stats is fixture-only")
    if args.hub_url and args.heatmap_showcase:
        parser.error("--heatmap-showcase is fixture-only")
    history_fixture = fixture_heatmap_history() if args.heatmap_showcase else fixture_history()
    if args.hub_url:
        args.no_screenshot = True  # Real Hub proof retains counts/errors only.
    settings = json.loads(args.settings_json)
    if args.exercise_provider_icons:
        settings.update(initial_view="quotas", bar_show_icon=True, show_account_names=True)
    declared = {setting["key"] for setting in tomllib.loads((args.plugin / "plugin.toml").read_text()).get("setting", [])}
    if not isinstance(settings, dict) or any(key not in declared or key in {"hub_url", "credentials_file", "refresh_interval_seconds"}
                                            or type(value) not in (bool, int, str) for key, value in settings.items()):
        parser.error("--settings-json must contain declared non-sensitive scalar presentation settings")
    if (args.exercise_ui or args.capture_settings) and args.hub_url:
        parser.error("UI content assertions are fixture-only")
    base = args.output or args.plugin / "output/runtime" / time.strftime("%Y%m%d-%H%M%S")
    base = base.resolve()
    base.mkdir(parents=True, exist_ok=False)
    base.chmod(0o700)
    private = Path(tempfile.mkdtemp(prefix="token-monitor-private-"))
    runtime = private / "runtime"
    runtime.mkdir(mode=0o700)
    source = private / "source/token-monitor"
    shutil.copytree(args.plugin, source, ignore=shutil.ignore_patterns(".git", "output", "__pycache__"))
    # Store-backed baselines are read-only; instrumentation edits only this
    # disposable copy, whose permissions copytree otherwise preserves.
    for copied in [source, *source.rglob("*")]:
        if not copied.is_symlink():
            copied.chmod(0o700 if copied.is_dir() else 0o600)
    hashes = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in source.rglob("*") if p.is_file() and (p.suffix in (".luau", ".toml", ".json")
                                                          or "assets" in p.relative_to(source).parts)}
    evidence = {"mode": "real-hub-read-only" if args.hub_url else "simulated-hub-native-http",
                "provider_icon_suite": args.exercise_provider_icons, "connection_suite": args.exercise_connection, "large_stats": args.large_stats, "large_quotas": args.large_quotas, "actual_noctalia": True, "heatmap_showcase": args.heatmap_showcase, "isolated_headless_compositor": True,
                "plugin_id": PLUGIN_ID, "plugin_api": tomllib.loads((source / "plugin.toml").read_text())["plugin_api"],
                "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "source_sha256": hashes, "settings": settings, "samples": [], "commands": [], "passed": False,
                "noctalia_version": subprocess.check_output(["noctalia", "--version"], text=True).strip()}
    fixture = {"statsStatus": 200, "historyStatus": 200, "authorizedRequests": 0, "unauthorizedRequests": 0,
               "statsRequests": 0, "historyRequests": 0, "reordered": False, "missingPin": False, "excessQuotas": False}
    fixture_home = private / "home"
    fixture_home.mkdir(mode=0o700)
    discovery_credentials = fixture_home / ".config/Token Monitor/credentials.json"
    discovery_credentials.parent.mkdir(parents=True)
    large_rows = [{"index": index, "label": ('Synthetic padding \"quote\" \\ slash ' * 16),
                   "nested": {"empty": [], "flag": True, "absent": None, "value": index / 100}}
                  for index in range(2200)] if args.large_stats else []
    processes, server = [], None
    try:
        hub_url = args.hub_url
        credentials = args.credentials_file
        if not hub_url:
            secret = secrets.token_hex(24)
            credentials = private / "fixture-credentials.json"
            credentials.write_text(secret + "\n")
            credentials.chmod(0o600)
            if args.exercise_connection == "automatic":
                credentials = None  # Exercise first-run discovery before any file exists.
            elif args.exercise_connection == "manual":
                discovery_credentials.write_text(json.dumps({"credentials": {"hub": {"hostSecret": "synthetic-wrong-automatic-secret"}}}))
                discovery_credentials.chmod(0o600)
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    kind = {"/api/stats": "stats", "/api/history": "history"}.get(self.path)
                    if kind is None or self.headers.get("Authorization") != "Bearer " + secret:
                        fixture["unauthorizedRequests"] += 1
                        self.send_response(401); self.end_headers(); return
                    fixture["authorizedRequests"] += 1
                    fixture[kind + "Requests"] += 1
                    status = fixture[kind + "Status"]
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    body = (fixture_dashboard(fixture["reordered"], fixture["missingPin"]) if kind == "stats" else history_fixture)
                    if status == 200 and kind == "stats" and args.large_quotas:
                        body["limits"]["providers"] = [
                            {"provider": "codex", "accountKey": "maximum-quota-" + str(index),
                             "windows": [{"label": "w" * 256, "kind": "period", "detail": "d" * 256,
                                          "resetDescription": "r" * 256, "remainingPercent": 50}
                                         for _ in range(32)]} for index in range(16)]
                        if fixture["excessQuotas"]:
                            body["limits"]["providers"].append({"provider": "codex", "accountKey": "excess-quota",
                                                                "windows": [{"remainingPercent": 0}]})
                    if kind == "stats" and args.exercise_provider_icons:
                        body["limits"]["providers"] = [
                            {"provider": row["id"], "accountKey": "fixture-icon-" + row["caseId"], "adapterId": row.get("adapterId"),
                             "accountLabel": "Synthetic " + row["caseId"], "sourceDeviceId": "fixture-device",
                             "status": "ok", "updatedAt": "2026-10-22T00:00:00Z",
                             "windows": [{"label": "Weekly", "kind": "weekly", "remainingPercent": 62,
                                          "resetsAt": "2026-10-29T00:00:00Z"}]}
                            for row in icon_cases]
                    if status == 200 and kind == "stats" and args.large_stats:
                        body["syntheticPadding"] = large_rows
                    wire = json.dumps(body if status == 200 else {"error": "fixture_unavailable"}).encode()
                    if kind == "stats" and status == 200:
                        fixture["statsBytes"] = len(wire)
                    self.wfile.write(wire)
                def log_message(self, *unused):
                    pass
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            hub_url = "http://127.0.0.1:" + str(server.server_port)
        # All settings use native configuration. Only observers/IPC test hooks are
        # added to copied entries; production transport and settings reads remain.
        service = source / "service.luau"
        observer = '''
local function saveRuntimeProbe(value)
  local d = value or noctalia.state.get("dashboard") or {}
  local c = d.connection or {}
  local windows, zeroes, stale = 0, 0, 0
  for _, p in ipairs(d.providers or {}) do
    if p.stale then stale = stale + 1 end
    for _, w in ipairs(p.windows or {}) do windows = windows + 1; if w.value == 0 then zeroes = zeroes + 1 end end
  end
  noctalia.writeFile(noctalia.pluginDataDir() .. "/probe.json", noctalia.json.encode({
    connectionStatus = c.status, credentialSource = c.credentialSource,
    connection = __CAPTURE__ and {status = c.status, url = c.url, credentialSource = c.credentialSource,
      credentialPath = c.credentialPath, discovery = c.discovery, stats = c.stats, history = c.history, checkedAt = c.checkedAt} or nil,
    status = d.status or "", error = d.error or "", count = #(d.providers or {}),
    windowCount = windows, zeroCount = zeroes, staleCount = stale,
    lastSuccess = d.lastSuccess or 0, cached = d.cached or false, cacheWarning = d.cacheWarning or false,
    historyStatus = (d.history or {}).status or "", historyError = (d.history or {}).error or "",
    dailyCount = #((d.history or {}).daily or {}), monthlyCount = #((d.history or {}).monthly or {}),
    analyticsStatus = (d.analytics or {}).status or "", deferredCount = #deferred,
    pinReady = (noctalia.state.get("pinned_account") or {}).ready or false,
    pinKey = __CAPTURE__ and (noctalia.state.get("pinned_account") or {}).key or nil
  }))
end
noctalia.state.watch("dashboard", saveRuntimeProbe)
noctalia.state.watch("pinned_account", function() saveRuntimeProbe() end)
saveRuntimeProbe()
local productionProbeIpc = onIpc
function onIpc(event, payload)
  if event == "test_refresh" then noctalia.state.set("refresh_requested", tostring(payload))
  elseif event == "test_dump" then saveRuntimeProbe()
  elseif event == "test_tick" then update()
  elseif productionProbeIpc then productionProbeIpc(event, payload) end
end
'''.replace("__CAPTURE__", "false" if args.hub_url else "true")
        service.write_text(service.read_text() + observer)
        probe_today = date.today() if args.heatmap_showcase else date(2026, 10, 23)
        probe_offsets = (0, 1, 2, 3) if args.heatmap_showcase else (0, 1, 3, 4)
        probe_cell_keys = ", ".join("[" + json.dumps("heatmap-day-" + (probe_today - timedelta(days=offset)).isoformat()) + "] = true"
                                    for offset in probe_offsets)
        tree_observer = '''
local probeCellKeys = { __CELL_KEYS__ }
local function describeProbeTree(tree)
  local result = {nodes = 0, maxChildren = 0, heatmapCellCount = 0, cells = {}, keys = {}, texts = {}, progress = {}, graphs = {}, bars = {}, icons = {}}
  local function visit(node)
    if type(node) ~= "table" then return end
    result.nodes = result.nodes + 1
    if type(node.children) == "table" then result.maxChildren = math.max(result.maxChildren, #node.children) end
    if type(node.key) == "string" and node.key:match("^heatmap%-day%-") then result.heatmapCellCount = result.heatmapCellCount + 1 end
    if __CAPTURE__ then
      if type(node.key) == "string" then table.insert(result.keys, node.key) end
      if type(node.key) == "string" and node.key:match("^provider%-icon%-") then
        table.insert(result.icons, {key = node.key, text = node.text, fontFamily = node.fontFamily,
          width = node.width, height = node.height, fontSize = node.fontSize, name = node.name, size = node.size, color = node.color})
      end
      if type(node.key) == "string" and probeCellKeys[node.key] then
        result.cells[node.key] = {fill = node.fill, border = node.border, borderWidth = node.borderWidth,
          clickable = node.onClick ~= nil, tooltip = node.tooltip}
      end
      if type(node.text) == "string" then table.insert(result.texts, node.text) end
      if type(node.progress) == "number" then table.insert(result.progress, node.progress) end
      if type(node.values) == "table" then table.insert(result.graphs, node.values) end
      if type(node.key) == "string" and node.key:match("^trend%-value%-") then table.insert(result.bars, node.height / 96) end
    end
    for _, child in pairs(node) do if type(child) == "table" then visit(child) end end
  end
  visit(tree)
  return result
end
'''.replace("__CAPTURE__", "false" if args.hub_url else "true").replace("__CELL_KEYS__", probe_cell_keys)
        bar_entry = source / "bar_widget.luau"
        bar_entry.write_text(tree_observer + """local nativeProbeBar = barWidget
local barRenders = 0
local barProbe = {}
local barWidget = setmetatable({render = function(tree)
  nativeProbeBar.render(tree)
  barRenders = barRenders + 1
  barProbe = describeProbeTree(tree)
  barProbe.renders = barRenders
  noctalia.writeFile(noctalia.pluginDataDir() .. "/probe-bar.json", noctalia.json.encode(barProbe))
end, setTooltip = function(value)
  nativeProbeBar.setTooltip(value)
  barProbe.tooltip = __CAPTURE__ and value or nil
  noctalia.writeFile(noctalia.pluginDataDir() .. "/probe-bar.json", noctalia.json.encode(barProbe))
end}, {__index = nativeProbeBar})
""".replace("__CAPTURE__", "false" if args.hub_url else "true") + bar_entry.read_text())
        panel_entry = source / "panel.luau"
        panel_source = panel_entry.read_text()
        if not args.hub_url and not args.heatmap_showcase:
            # The original three-day fixture has a fixed calendar, independent
            # of the date on which this acceptance suite is rerun.
            panel_source = panel_source.replace('today = os.date("%Y-%m-%d")', 'today = "2026-10-23"')
        provider_hooks = ""
        if args.exercise_provider_icons:
            catalog_luau = "{" + ",".join("{id=" + json.dumps(row["id"]) + ",name=" + json.dumps(row["name"]) + ",caseId=" + json.dumps(row["caseId"]) + ",adapterId=" + (json.dumps(row["adapterId"]) if row.get("adapterId") else "nil") + "}" for row in icon_cases) + "}"
            provider_hooks = """
local probeProviderCatalog = __CATALOG__
local probeFullDashboard = nil
local function probeSelectProvider(caseId)
  probeFullDashboard = probeFullDashboard or dashboard
  for _, account in ipairs(probeFullDashboard.providers or {}) do
    if type(account.key) == "string" and account.key:find("fixture-icon-" .. caseId, 1, true) then
      local selected = {}
      for key, value in pairs(probeFullDashboard) do selected[key] = value end
      selected.providers = {account}
      dashboard = selected
      activeView = "quotas"
      setProvider(account.provider)
      return
    end
  end
  error("synthetic normalized account missing: " .. caseId)
end
local function probeProviderGallery(page)
  local rows = {ui.label({text = "Token Monitor 0.68.0 provider icons · 15px / 20px", fontSize = 16})}
  for i = (page - 1) * 16 + 1, math.min(page * 16, #probeProviderCatalog) do
    local item = probeProviderCatalog[i]
    rows[#rows + 1] = ui.row({height = 32, gap = 16, align = "center"}, {
      view.providerIcon(item.id, 15, "primary", item.adapterId), view.providerIcon(item.id, 20, "primary", item.adapterId),
      ui.label({text = item.name .. " (" .. item.caseId .. ")", fontSize = 12})})
  end
  panel.render(ui.column({key = "provider-gallery-" .. tostring(page), padding = 20, gap = 6}, rows))
end
""".replace("__CATALOG__", catalog_luau)
        panel_entry.write_text(tree_observer + """local nativeProbePanel = panel
local probePanelStats = {renders = 0, opens = 0}
local probePanelTree, probePanelDirty = nil, false
local function savePanelProbe()
  -- Keep capture outside production render and event callbacks: native callback
  -- CPU limits must measure production separately from test JSON serialization.
  probePanelDirty = true
end
local panel = setmetatable({render = function(tree)
  nativeProbePanel.render(tree)
  probePanelStats.renders = probePanelStats.renders + 1
  probePanelTree = tree
  savePanelProbe()
end}, {__index = nativeProbePanel})
""" + panel_source + provider_hooks + """
local productionProbeUpdate = update
function update(...)
  if probePanelDirty then
    probePanelStats.tree = describeProbeTree(probePanelTree)
    noctalia.writeFile(noctalia.pluginDataDir() .. "/probe-panel.json", noctalia.json.encode(probePanelStats))
    probePanelDirty = false
    return
  end
  if productionProbeUpdate then productionProbeUpdate(...) end
end
local originalProbeOnOpen = onOpen
function onOpen(...)
  probePanelStats.opens = probePanelStats.opens + 1
  if originalProbeOnOpen then originalProbeOnOpen(...) end
  savePanelProbe()
end
local probeHandlers = {
  all = onProviderAll, codex = onProviderCodex, deepseek = onProviderDeepseek,
  antigravity = onProviderAntigravity, previous = onPrevious, next = onNext,
  expand = onExpandAccount,
  settings = onSettings,
  connection = onConnection, testConnection = onTestConnection, connectionBack = onConnectionBack,
  quotas = onViewQuotas, models = onViewModels, sessions = onViewSessions,
  activity = onViewActivity, trends = onViewTrends,
  today = onPeriodToday, month = onPeriodMonth, allTime = onPeriodAllTime,
  daily = onHistoryDaily, monthly = onHistoryMonthly,
  tokens = onTrendTokens, cost = onTrendCost,
  heatmapTokens = onHeatmapTokens, heatmapCost = onHeatmapCost, heatmapMessages = onHeatmapMessages,
  heatmap13Weeks = onHeatmap13Weeks, heatmap26Weeks = onHeatmap26Weeks,
  selectDay = function() onSelectDay(__SELECT_DAY__) end,
  expandModel = function() onExpandModel("Synthetic allTime model") end,
  expandSession = function() onExpandSession("codex:synthetic-session-13") end,
  pin = function() onPinAccount("3") end, clearPin = onClearPin,
  expandBucket = function() onExpandBucket("daily:" .. __BUCKET_DAY__) end,
}
function onIpc(event, payload)
  if event == "test_provider" then
    if probeSelectProvider then probeSelectProvider(payload) else activeView = "quotas"; setProvider(payload) end
  elseif event == "test_pin_provider" then
    if probeSelectProvider then onPinAccount("1") else
      for index, provider in ipairs(dashboard.providers or {}) do
        if provider.provider == payload then onPinAccount(tostring(index)); break end
      end
    end
  elseif event == "test_gallery" and probeProviderGallery then
    probeProviderGallery(tonumber(payload))
  elseif event == "test_action" and probeHandlers[payload] then
    probeHandlers[payload](3)
  end
end
""".replace("__SELECT_DAY__", json.dumps((date.today() - timedelta(days=1)).isoformat() if args.heatmap_showcase else "2026-10-22")).replace("__BUCKET_DAY__", json.dumps(history_fixture["daily"][-1]["date"])))
        manifest = source / "plugin.toml"
        manifest.write_text(re.sub(r'placement\s*=\s*"attached"', 'placement = "floating"', manifest.read_text()))
        config = private / "config/noctalia"
        config.mkdir(parents=True)
        (config / "config.toml").write_text('''[shell]
lang = "en"
offline_mode = false
telemetry_enabled = false
clipboard_enabled = false
polkit_agent = false
[bar.main]
enabled = true
start = ["token_probe"]
center = []
end = []
[widget.token_probe]
type = "shangshui0302/token-monitor:bar"
[wallpaper]
enabled = false
[dock]
enabled = false
[desktop_widgets]
enabled = false
[lockscreen]
enabled = false
[notification]
enable_daemon = false
[system.monitor]
enabled = false
[plugins]
enabled = ["shangshui0302/token-monitor"]
auto_update = "none"
[[plugins.source]]
name = "token-monitor-probe"
kind = "path"
location = ''' + json.dumps(str(private / "source")) + "\n\n[plugin_settings." + json.dumps(PLUGIN_ID) + "]\n" +
            "\n".join(key + " = " + json.dumps(value) for key, value in dict(settings, hub_url=hub_url,
                credentials_file=str(credentials.resolve()) if credentials else "", refresh_interval_seconds=3600).items()) + "\n")
        (private / "sway.config").write_text('output * resolution 1000x900\nseat seat0 fallback true\nxwayland disable\n')
        env = dict(os.environ, NOCTALIA_CONFIG_HOME=str(private / "config"), NOCTALIA_STATE_HOME=str(private / "state"),
                   NOCTALIA_DATA_HOME=str(private / "data"), XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS="headless",
                   WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1", PIPEWIRE_REMOTE="token-monitor-no-pipewire",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(private / "no-system-bus"), PULSE_SERVER="unix:" + str(private / "no-pulse"))
        if not args.hub_url:
            # Discovery must never inspect the actual user home or Distrobox homes.
            env["HOME"] = str(fixture_home)
        for key in ("CONFIG", "STATE", "DATA", "CACHE"):
            env["XDG_" + key + "_HOME"] = str(private / key.lower())
        for key in ("WAYLAND_DISPLAY", "SWAYSOCK", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key, None)
        def launch(argv, name):
            with (base / name).open("a") as log:
                p = subprocess.Popen(argv, env=env, stdout=log, stderr=log)
            processes.append(p)
            return p
        sway = launch([args.sway, "--unsupported-gpu", "-c", str(private / "sway.config")], "sway.log")
        deadline = time.monotonic() + 15
        while not any(p.is_socket() for p in runtime.glob("wayland-*")):
            if sway.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("private sway did not start")
            time.sleep(.1)
        env["WAYLAND_DISPLAY"] = next(p for p in runtime.glob("wayland-*") if p.is_socket()).name
        started = time.monotonic()
        process = launch(["noctalia"], "runtime.log")
        probe = private / "state/noctalia/plugins/data/shangshui0302/token-monitor/probe.json"
        def command(*argv):
            result = subprocess.run(["noctalia", "msg", *argv], env=env, capture_output=True, text=True, timeout=4)
            evidence["commands"].append({"argv": argv, "returncode": result.returncode})
            result.check_returncode()
        def wait_state(predicate, description, path=probe):
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("isolated Noctalia exited")
                runtime_text = (base / "runtime.log").read_text()
                if "ignoring plugin at" in runtime_text and "source/token-monitor" in runtime_text:
                    raise RuntimeError("Noctalia rejected plugin manifest; inspect runtime.log")
                value = read_json(path)
                if predicate(value):
                    return value
                time.sleep(.15)
            raise RuntimeError("timeout waiting for " + description + "; last sanitized state=" + json.dumps(read_json(path)))
        def wait_status(status, history="ready"):
            value = wait_state(lambda d: d.get("status") == status and d.get("historyStatus") == history,
                               status + "/history=" + history)
            evidence["samples"].append(dict(value, seconds=round(time.monotonic() - started, 3)))
            return value
        def wait_idle():
            # A ready snapshot can precede cache serialization's deferred frames.
            # Observe the actual queue and require a quiet interval before test_tick.
            deadline = time.monotonic() + args.timeout
            quiet = None
            while time.monotonic() < deadline:
                command("plugin", PLUGIN_ID + ":service", "all", "test_dump")
                time.sleep(.1)
                value = read_json(probe)
                if value.get("deferredCount") == 0 and value.get("status") != "loading" and value.get("historyStatus") != "loading":
                    if quiet is not None and time.monotonic() - quiet >= .4:
                        return value
                    if quiet is None:
                        quiet = time.monotonic()
                else:
                    quiet = None
                time.sleep(.1)
            raise AssertionError("native deferred work did not become idle")
        def refresh(name, status="ready", history="ready"):
            before = fixture["authorizedRequests"]
            command("plugin", PLUGIN_ID + ":service", "all", "test_refresh", name)
            wait_state(lambda _: fixture["authorizedRequests"] >= before + 2, "two endpoint requests")
            value = wait_status(status, history)
            wait_idle()
            return value
        if args.exercise_connection:
            connection_cases = []
            evidence["connection_cases"] = connection_cases
            panel_probe = probe.parent / "probe-panel.json"
            def connection_state(status, source=None, discovery=None, stats=None, history=None):
                def matches(value):
                    c = value.get("connection", {})
                    return (c.get("status") == status
                            and (source is None or c.get("credentialSource") == source)
                            and (discovery is None or c.get("discovery") == discovery)
                            and (stats is None or c.get("stats") == stats)
                            and (history is None or c.get("history") == history))
                value = wait_state(matches, "connection " + status)
                connection_cases.append({"connection": value["connection"], "cached": value.get("cached"),
                                         "lastSuccess": value.get("lastSuccess")})
                return value
            def connection_tree(label):
                value = wait_state(lambda v: label.lower() in "\n".join(v.get("tree", {}).get("texts", [])).lower(),
                                   "connection UI label " + label, panel_probe)
                assert value["tree"].get("maxChildren", 0) <= 256
                return value["tree"]
            def connection_action(name):
                command("plugin", PLUGIN_ID + ":panel", "all", "test_action", name)
            connection_state("error" if args.exercise_connection == "automatic" else "ready")
            command("panel-toggle", PLUGIN_ID + ":panel")
            if args.exercise_connection == "automatic":
                missing = connection_state("error", discovery="not_found")
                evidence["first_run_guide"] = connection_tree("Connect Token Monitor")
                if not args.no_screenshot and shutil.which("grim"):
                    time.sleep(.35)
                    subprocess.run(["grim", str(base / "connection-first-run.png")], env=env, check=True)
                connection_tree("Test connection")
                assert not missing.get("lastSuccess"), "first run unexpectedly has a successful cache"
                # Back cannot open a dashboard before the first successful fetch.
                connection_action("connectionBack")
                connection_tree("Connect Token Monitor")
                discovery_credentials.write_text(json.dumps({"credentials": {"hub": {"hostSecret": "synthetic-wrong-secret"}}}))
                discovery_credentials.chmod(0o600)
                before = fixture["unauthorizedRequests"]
                connection_action("testConnection")
                wait_state(lambda _: fixture["unauthorizedRequests"] > before, "automatic auth failure HTTP")
                connection_state("error", source="automatic", discovery="found", stats="unauthorized")
                evidence["auth_failure_tree"] = connection_tree("Stats")
                discovery_credentials.write_text(json.dumps({"credentials": {"hub": {"hostSecret": secret}}}))
                before = fixture["authorizedRequests"]
                connection_action("testConnection")
                wait_state(lambda _: fixture["authorizedRequests"] >= before + 2, "retry both endpoints")
                connection_state("ready", source="automatic", discovery="found", stats="ok", history="ok")
                connection_tree("Open dashboard")
                if not args.no_screenshot and shutil.which("grim"):
                    time.sleep(.35)
                    subprocess.run(["grim", str(base / "connection-ready.png")], env=env, check=True)
            else:
                connection_state("ready", source="manual", discovery="manual", stats="ok", history="ok")
                assert fixture["unauthorizedRequests"] == 0, "manual path did not override wrong automatic credential"
                connection_action("connection")
                connection_tree("Connection")
            connection_action("connectionBack")
            wait_state(lambda v: any(key.startswith("content-quotas-") for key in v.get("tree", {}).get("keys", [])),
                       "open dashboard after successful connection", panel_probe)
            connection_action("connection")
            connection_tree("Connection")
            fixture["historyStatus"] = 503
            before = fixture["authorizedRequests"]
            connection_action("testConnection")
            wait_state(lambda _: fixture["authorizedRequests"] >= before + 2, "partial fresh requests")
            connection_state("partial", stats="ok", history="http")
            evidence["partial_tree"] = connection_tree("History")
            fixture["statsStatus"] = 503
            before = fixture["authorizedRequests"]
            connection_action("testConnection")
            wait_state(lambda _: fixture["authorizedRequests"] >= before + 2, "failure after cached success fresh requests")
            failed = connection_state("error", stats="http", history="http")
            assert failed.get("lastSuccess"), "failure test needs a retained successful snapshot"
            evidence["fresh_failure_tree"] = connection_tree("Stats")
            fixture["statsStatus"], fixture["historyStatus"] = 200, 200
            connection_action("testConnection")
            connection_state("ready", stats="ok", history="ok")
            connection_action("connectionBack")
            # Existing common acceptance below starts by opening the panel.
            command("panel-toggle", PLUGIN_ID + ":panel")
            evidence["connection_acceptance_passed"] = True
        ready = wait_status("ready")
        wait_idle()
        if not args.hub_url:
            if args.large_quotas:
                assert ready["count"] == 16 and ready["windowCount"] == 512, ready
                fixture["excessQuotas"] = True
                failed = refresh("quota-over-limit", status="error")
                assert failed["error"] == "too_large", failed
                assert (failed["count"], failed["windowCount"], failed["lastSuccess"]) == (ready["count"], ready["windowCount"], ready["lastSuccess"]), failed
                assert failed["analyticsStatus"] == "error", failed
                evidence["quota_limit"] = {"supported_windows": 512, "rejected_windows": 513,
                                           "retained_snapshot": True, "error": failed["error"]}
                fixture["excessQuotas"] = False
                ready = refresh("quota-limit-recovery")
                assert ready["zeroCount"] == 0 and ready["staleCount"] == 0, ready
            elif args.exercise_provider_icons:
                assert ready["count"] == len(icon_cases) and ready["windowCount"] == len(icon_cases), ready
                assert ready["zeroCount"] == 0 and ready["staleCount"] == 0, ready
            else:
                assert ready["count"] == 4 and ready["windowCount"] == 8, ready
                assert ready["zeroCount"] == 3 and ready["staleCount"] == 1, ready
            assert ready["dailyCount"] == len(history_fixture["daily"]) and ready["monthlyCount"] == len(history_fixture["monthly"]), ready
            assert ready["analyticsStatus"] == "ready", ready
        requests_before_open = fixture["authorizedRequests"]
        command("panel-toggle", PLUGIN_ID + ":panel")
        panel_stats = wait_state(lambda value: value.get("opens", 0) >= 1 and value.get("renders", 0) >= 1,
                                 "panel render captured on separate observer tick", probe.parent / "probe-panel.json")
        evidence["panel"] = panel_stats
        evidence["bar"] = read_json(probe.parent / "probe-bar.json")
        assert evidence["bar"].get("renders", 0) >= 1, evidence["bar"]
        assert panel_stats.get("opens", 0) >= 1 and panel_stats.get("renders", 0) >= 1, panel_stats
        assert panel_stats.get("tree", {}).get("maxChildren", 0) <= 256, "native parent exceeds 256 children"
        if not args.hub_url:
            evidence["requests_on_open"] = fixture["authorizedRequests"] - requests_before_open
            assert evidence["requests_on_open"] == 2 * int(settings.get("refresh_on_open", False))
            tree = panel_stats.get("tree", {})
            if settings.get("initial_view", "quotas") == "quotas" and settings.get("show_progress") is False:
                assert not tree.get("progress"), tree
            elif not args.large_quotas and settings.get("initial_view", "quotas") == "quotas" and settings.get("percentage_mode") == "used" and settings.get("panel_provider", "all") in ("all", "codex"):
                assert 1 in tree.get("progress", []), "zero remaining quota must display a full used meter"
        if not args.no_screenshot and not args.exercise_provider_icons:
            subprocess.run(["grim", str(base / "panel.png")], env=env, check=True, capture_output=True, timeout=4)
            evidence["screenshot"] = "panel.png"
        if args.exercise_provider_icons:
            checks = []
            evidence["all_provider_icons"] = {"version": catalog["tokenMonitorVersion"], "cases": checks,
                "aliases": catalog.get("aliases", {}), "gallery": []}
            def provider_action(event, payload):
                before = read_json(probe.parent / "probe-panel.json").get("renders", 0)
                command("plugin", PLUGIN_ID + ":panel", "all", event, payload)
                result = wait_state(lambda d: d.get("renders", 0) > before, event + ":" + payload,
                                    probe.parent / "probe-panel.json")
                assert result["tree"].get("maxChildren", 0) <= 256, result
                return result["tree"]
            def check_icon(tree, row, size):
                icons = [icon for icon in tree.get("icons", []) if icon["key"] == "provider-icon-" + row["id"]]
                assert len(icons) == 1, (row["id"], size, icons)
                icon = icons[0]
                if row.get("brand") is None:
                    assert icon.get("name") == "plug-connected", icon
                    assert icon.get("size", icon.get("width")) == size, icon
                else:
                    assert icon.get("fontFamily", "").startswith("Token Monitor Brands"), icon
                    assert icon.get("fontSize") == size and icon.get("width") == size and icon.get("height") == size, icon
                    assert icon.get("text") == chr(row["codepoint"]), (row, icon)
                return icon
            for row in icon_cases:
                tree = provider_action("test_provider", row["caseId"])
                assert row["cardName"] in tree.get("texts", []), (row, tree)
                assert len([key for key in tree["keys"] if re.fullmatch(r"account-\d+", key)]) == 1, tree
                panel_icon = check_icon(tree, row, 20)
                command("plugin", PLUGIN_ID + ":panel", "all", "test_pin_provider", row["caseId"])
                wait_state(lambda d: "fixture-icon-" + row["caseId"] in d.get("pinKey", ""), "pin identity " + row["caseId"])
                bar = wait_state(lambda b: "Synthetic " + row["caseId"] in json.dumps(b.get("tooltip", "")) and any(icon.get("key") == "provider-icon-" + row["id"] and
                    (icon.get("text") == chr(row["codepoint"]) if row.get("codepoint") else icon.get("name") == "plug-connected")
                    for icon in b.get("icons", [])),
                                 "pinned bar icon " + row["id"], probe.parent / "probe-bar.json")
                bar_icon = check_icon(bar, row, 15)
                assert row["cardName"] in json.dumps(bar.get("tooltip", "")), (row, bar)
                checks.append({"id": row["id"], "adapterId": row.get("adapterId"), "caseId": row["caseId"], "name": row["name"], "panel": panel_icon, "bar": bar_icon})
            for page in (1, 2):
                tree = provider_action("test_gallery", str(page))
                expected = icon_cases[(page - 1) * 16:page * 16]
                assert len(tree.get("icons", [])) == len(expected) * 2, tree
                for row in expected:
                    for size in (15, 20):
                        subset = dict(tree, icons=[icon for icon in tree["icons"] if icon.get("fontSize", icon.get("size")) == size and
                            (icon.get("text") == chr(row["codepoint"]) if row.get("codepoint") else icon.get("name") == "plug-connected")])
                        # Shared New API adapters intentionally produce identical glyphs.
                        matching = [icon for icon in subset["icons"] if icon["key"] == "provider-icon-" + row["id"]]
                        assert matching, (row, size)
                        check_icon(dict(subset, icons=matching[:1]), row, size)
                gallery = {"page": page, "providers": [row["caseId"] for row in expected], "tree": tree}
                if not args.no_screenshot:
                    time.sleep(.5)
                    filename = "provider-gallery-" + str(page) + ".png"
                    subprocess.run(["grim", str(base / filename)], env=env, check=True, capture_output=True, timeout=4)
                    gallery["screenshot"] = filename
                evidence["all_provider_icons"]["gallery"].append(gallery)
            evidence["all_provider_icons"]["passed"] = len(checks) == 32
        if args.capture_transitions:
            # Fixed geometry: 1000x900 private output, centered 580x720 panel.
            # These small padding patches avoid glyphs/text, selected indicators,
            # corners, and antialiasing. Trends stays inactive throughout.
            regions = {"settings": (626, 85, 5, 5), "refresh": (666, 85, 5, 5),
                       "close": (706, 85, 5, 5), "inactive_trends": (646, 135, 7, 5)}
            swaymsg = str(Path(args.sway).with_name("swaymsg"))
            sway_socket = next(runtime.glob("sway-ipc.*.sock"))
            subprocess.run([swaymsg, "-s", str(sway_socket), "seat", "seat0", "cursor", "set", "10", "850"],
                           env=env, check=True, capture_output=True, timeout=4)
            frame_dir = base / "transition-frames"
            frame_dir.mkdir()
            transitions = {"regions": regions, "cursor": [10, 850], "threshold_rgb": 3,
                           "animation_ms": 150, "capture": "native grim, no observer wait after test_action",
                           "cases": [], "passed": False}
            evidence["transitions"] = transitions
            def frame(path, origin):
                begin = time.monotonic()
                subprocess.run(["grim", "-l", "0", str(path)], env=env, check=True, capture_output=True, timeout=4)
                return {"file": str(path.relative_to(base)), "start_ms": round((begin - origin) * 1000, 3),
                        "end_ms": round((time.monotonic() - origin) * 1000, 3)}
            time.sleep(.5)
            current = settings.get("initial_view", "quotas")
            for index, target in enumerate(("models", "sessions", "activity", "models", "sessions", "activity")):
                case_dir = frame_dir / (str(index + 1) + "-" + current + "-to-" + target)
                case_dir.mkdir()
                origin = time.monotonic()
                before_frame = frame(case_dir / "before.png", origin)
                before_renders = read_json(probe.parent / "probe-panel.json").get("renders", 0)
                action_start = time.monotonic()
                command("plugin", PLUGIN_ID + ":panel", "all", "test_action", target)
                action_return = time.monotonic()
                frames = []
                while len(frames) < 12 or time.monotonic() - action_start < .25:
                    frames.append(frame(case_dir / (f"frame-{len(frames):03d}.png"), action_start))
                time.sleep(.5)
                stable = frame(case_dir / "stable.png", action_start)
                # Decode only after every transient frame is captured: PNG work
                # must never consume the 150ms animation sampling window.
                stable_rgb = png_region_means(base / stable["file"], regions)
                before_rgb = png_region_means(base / before_frame["file"], regions)
                for sample in frames:
                    sample["rgb"] = png_region_means(base / sample["file"], regions)
                    sample["deviation_rgb"] = {name: round(max(abs(a - b) for a, b in zip(values, stable_rgb[name])), 4)
                                               for name, values in sample["rgb"].items()}
                native_tree = read_json(probe.parent / "probe-panel.json")
                rendered_target = (native_tree.get("renders", 0) > before_renders and
                                   any(key.startswith("content-" + target + "-")
                                       for key in native_tree.get("tree", {}).get("keys", [])))
                sample_starts = [sample["start_ms"] for sample in frames]
                max_gap = max(b - a for a, b in zip(sample_starts, sample_starts[1:]))
                sampling_passed = (len(frames) >= 8 and sample_starts[0] <= 60 and
                                   frames[-1]["end_ms"] >= 150 and max_gap <= 60)
                peaks = {name: max(sample["deviation_rgb"][name] for sample in frames) for name in regions}
                stable_drift = {name: max(abs(a - b) for a, b in zip(before_rgb[name], stable_rgb[name])) for name in regions}
                case = {"from": current, "to": target, "action_command_ms": round((action_return - action_start) * 1000, 3),
                        "before": before_frame["file"], "before_rgb": before_rgb, "stable": stable["file"],
                        "stable_rgb": stable_rgb, "stable_drift_rgb": stable_drift, "frames": frames,
                        "peak_deviation_rgb": peaks, "native_target_rendered": rendered_target,
                        "sampling_passed": sampling_passed, "max_frame_gap_ms": round(max_gap, 3),
                        "passed": rendered_target and sampling_passed and max(peaks.values()) <= transitions["threshold_rgb"] and max(stable_drift.values()) <= 1}
                transitions["cases"].append(case)
                current = target
            transitions["passed"] = all(case["passed"] for case in transitions["cases"])
        if args.hub_url:
            evidence["real_view_smoke"] = []
            for name in ("models", "sessions", "activity", "trends", "quotas"):
                before = read_json(probe.parent / "probe-panel.json").get("renders", 0)
                command("plugin", PLUGIN_ID + ":panel", "all", "test_action", name)
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    value = read_json(probe.parent / "probe-panel.json")
                    if value.get("renders", 0) > before:
                        assert value.get("tree", {}).get("maxChildren", 0) <= 256, "native parent exceeds 256 children"
                        evidence["real_view_smoke"].append({"view": name, "nodes": value.get("tree", {}).get("nodes", 0),
                            "heatmapCellCount": value.get("tree", {}).get("heatmapCellCount", 0),
                            "maxChildren": value.get("tree", {}).get("maxChildren", 0)})
                        break
                    time.sleep(.1)
                else:
                    raise AssertionError("real view did not render: " + name)
        if args.exercise_ui:
            evidence["ui_actions"] = []
            def action(name):
                before = read_json(probe.parent / "probe-panel.json").get("renders", 0)
                command("plugin", PLUGIN_ID + ":panel", "all", "test_action", name)
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    value = read_json(probe.parent / "probe-panel.json")
                    if value.get("renders", 0) > before:
                        assert value["tree"].get("maxChildren", 0) <= 256, "native parent exceeds 256 children"
                        evidence["ui_actions"].append({"action": name, "tree": value["tree"]})
                        return value["tree"]
                    time.sleep(.1)
                raise AssertionError("panel action did not render: " + name)
            def cards(tree, prefix="account-"):
                pattern = r"account-\d+" if prefix == "account-" else r"session-codex:synthetic-session-\d+"
                return [key for key in tree["keys"] if re.fullmatch(pattern, key)]
            def screenshot(name):
                if not args.no_screenshot:
                    time.sleep(.5)
                    subprocess.run(["grim", str(base / (name + ".png"))], env=env, check=True, capture_output=True, timeout=4)
                    evidence.setdefault("view_screenshots", {})[name] = name + ".png"
            def texts(tree):
                return "\n".join(tree.get("texts", []))
            action("quotas")
            assert len(cards(action("codex"))) == 1
            assert len(cards(action("deepseek"))) == 1
            anti = action("antigravity")
            assert len(cards(anti)) == min(settings.get("accounts_per_page", 4), 2)
            if settings.get("accounts_per_page", 4) == 1:
                assert cards(action("next")) != cards(anti)
                assert cards(action("previous")) == cards(anti)
            expanded = action("expand")
            assert "Gemini Flash" in expanded["texts"], expanded
            quota = action("all")
            if settings.get("show_progress") is False:
                assert not quota.get("progress"), "show_progress applies to quota meters only"
            elif settings.get("percentage_mode") == "used":
                assert 1 in quota.get("progress", []), "zero quota is a full used meter"
            screenshot("quotas")

            action("models")
            for period in ("today", "month", "allTime"):
                model_tree = action(period)
                assert "Synthetic " + period + " model" in model_tree["texts"], model_tree
                assert "Synthetic zero model" in model_tree["texts"], model_tree
            collapsed_model = action("allTime")
            expanded_model = action("expandModel")
            assert "model-Synthetic allTime model" in expanded_model["keys"], expanded_model
            model_detail_key = "model-components-Synthetic allTime model"
            assert model_detail_key not in collapsed_model["keys"], collapsed_model
            assert model_detail_key in expanded_model["keys"], expanded_model
            action("allTime")
            screenshot("models")
            # Unsupported all-time sessions must be explicit, without substituting month.
            session_tree = action("sessions")
            assert not cards(session_tree, "session-"), session_tree
            assert "all-time sessions" in texts(session_tree), session_tree
            assert "choice-allTime" not in session_tree["keys"], "all-time option must not advertise unsupported sessions"
            assert "Synthetic allTime model" in action("models")["texts"], "switching views changed the selected period"
            action("sessions")
            session_tree = action("today")
            assert len(cards(session_tree, "session-")) == settings.get("details_per_page", 6), session_tree
            assert cards(action("next"), "session-") != cards(session_tree, "session-")
            assert cards(action("previous"), "session-") == cards(session_tree, "session-")
            session_expanded = action("expandSession")
            assert "Context window" in texts(session_expanded), session_expanded
            if settings.get("show_account_names") is False:
                for marker in ("Synthetic private title", "Synthetic private project", "synthetic-session-", "synthetic-project-id"):
                    assert marker not in texts(session_expanded), marker
            else:
                assert "Synthetic private title" in texts(session_expanded)
                assert "Synthetic private project" in texts(session_expanded)
                assert "synthetic-session-13" in texts(session_expanded)
            unsupported = action("allTime")
            assert not cards(unsupported, "session-"), unsupported
            assert "all-time sessions" in texts(unsupported), unsupported
            action("month")
            screenshot("sessions")

            heatmap = action("activity")
            heatmap = action("heatmap26Weeks")
            assert "activity-heatmap" in heatmap["keys"], heatmap
            assert heatmap.get("heatmapCellCount") == 26 * 7, heatmap
            quarter = action("heatmap13Weeks")
            assert quarter.get("heatmapCellCount") == 13 * 7, quarter
            screenshot("heatmap-13-weeks")
            heatmap = action("heatmap26Weeks")
            selected_day = (date.today() - timedelta(days=1)).isoformat() if args.heatmap_showcase else "2026-10-22"
            selected_key = "heatmap-day-" + selected_day
            source_row = next(row for row in history_fixture["daily"] if row["date"] == selected_day)
            for handler, metric in (("heatmapTokens", "tokens"), ("heatmapCost", "cost"), ("heatmapMessages", "messages")):
                heatmap = action(handler)
                cell = heatmap.get("cells", {}).get(selected_key, {})
                expected = "$" + format(source_row[metric], "g") if metric == "cost" else str(source_row[metric])
                assert cell.get("tooltip", "").endswith(": " + expected), (metric, cell)
                assert cell.get("clickable"), cell
            selected = action("selectDay")
            assert selected["cells"][selected_key].get("borderWidth") == 2, selected
            assert "selected-bucket-daily:" + selected_day in selected["keys"], selected
            assert selected_day in texts(selected), selected
            reset_range = action("heatmap13Weeks")
            assert "Model breakdown" not in texts(reset_range), "range changes must clear stale selected-day expansion"
            action("heatmap26Weeks")
            action("selectDay")
            if args.heatmap_showcase:
                zero_key = "heatmap-day-" + (date.today() - timedelta(days=2)).isoformat()
                missing_key = "heatmap-day-" + (date.today() - timedelta(days=3)).isoformat()
                unknown_key = "heatmap-day-" + date.today().isoformat()
                cells = selected["cells"]
                assert cells[zero_key]["fill"] == "on_surface/0.16" and cells[zero_key]["clickable"], cells[zero_key]
                assert cells[missing_key]["fill"] == "surface/0.2" and not cells[missing_key]["clickable"], cells[missing_key]
                assert cells[unknown_key]["fill"] == "secondary/0.1" and cells[unknown_key]["clickable"], cells[unknown_key]
                evidence["heatmap_zero_missing_unknown_passed"] = True
            else:
                # Original minimal fixture remains unchanged, including its exact trend values.
                cells = selected["cells"]
                assert cells["heatmap-day-2026-10-20"]["fill"] == "on_surface/0.16", selected
                assert cells["heatmap-day-2026-10-19"]["fill"] == "surface/0.2", selected
            screenshot("heatmap-messages")
            action("heatmapTokens")
            screenshot("heatmap-tokens")
            evidence["native_heatmap_handlers_passed"] = True
            action("activity")
            daily = action("daily")
            latest_day = history_fixture["daily"][-1]["date"]
            assert latest_day in daily["texts"], daily
            bucket = action("expandBucket")
            assert "Synthetic history model" in texts(bucket), bucket
            monthly = action("monthly")
            assert "bucket-monthly:" + history_fixture["monthly"][-1]["month"] in monthly["keys"], monthly
            assert not any(key.startswith("bucket-daily:") for key in monthly["keys"]), monthly
            screenshot("activity")
            action("trends")
            action("daily")
            for metric in ("tokens", "cost"):
                trend = action(metric)
                if not args.heatmap_showcase:
                    assert trend.get("bars") == [0, 1, .5], trend
                    assert "2026-10-20" in texts(trend) and "2026-10-22" in texts(trend), trend
            monthly = action("monthly")
            if not args.heatmap_showcase:
                assert monthly.get("bars") == [0, 1], monthly
                assert "2026-09" in texts(monthly) and "2026-10" in texts(monthly), monthly
            screenshot("trends")
            if settings.get("show_account_names") is False:
                assert "Fixture" not in json.dumps(evidence["ui_actions"])
                assert "Fixture" not in json.dumps(evidence["bar"])

            action("quotas")
            action("pin")
            pinned = wait_state(lambda d: d.get("pinReady") and bool(d.get("pinKey")), "pin selected")
            selection = read_json(probe.parent / "selection.json")
            assert selection.get("key") == pinned["pinKey"], "selected stable identity was not persisted"
            wait_idle()
            # Restart only the isolated Noctalia process to prove restoration through disk.
            process.terminate()
            process.wait(timeout=5)
            before_restart = fixture["authorizedRequests"]
            process = launch(["noctalia"], "runtime.log")
            wait_state(lambda _: fixture["authorizedRequests"] >= before_restart + 2, "restart reads")
            restored = wait_status("ready")
            wait_idle()
            wait_state(lambda d: d.get("pinKey") == pinned["pinKey"], "persisted native pin restoration")
            assert read_json(probe)["pinKey"] == pinned["pinKey"], "pin did not survive native restart"
            command("panel-toggle", PLUGIN_ID + ":panel")
            time.sleep(.5)
            fixture["reordered"] = True
            reordered = refresh("reorder")
            assert reordered["pinKey"] == pinned["pinKey"], reordered
            expected = "77%" if settings.get("percentage_mode") == "used" else "23%"
            if settings.get("bar_window", "first") != "session":
                wait_state(lambda b: expected in json.dumps(b), "pinned quota after reorder", probe.parent / "probe-bar.json")
            fixture["missingPin"] = True
            missing = refresh("missing-pin")
            assert missing["pinKey"] == pinned["pinKey"], "missing pin must retain identity"
            bar_missing = wait_state(lambda b: "pinned account is unavailable" in json.dumps(b), "missing pin label", probe.parent / "probe-bar.json")
            assert expected not in json.dumps(bar_missing), "missing pinned identity fell back to another account"
            action("clearPin")
            wait_state(lambda d: d.get("pinReady") and d.get("pinKey") == "", "pin cleared")
            fixture["missingPin"], fixture["reordered"] = False, False
            ready = refresh("restore-fixture")
            evidence["pin_persistence_reorder_and_missing_passed"] = True
            evidence["native_ui_handlers_passed"] = True
        if not args.hub_url and not args.exercise_provider_icons and not args.capture_transitions and settings.get("auto_refresh") is False:
            wait_idle()
            before = fixture["authorizedRequests"]
            command("plugin", PLUGIN_ID + ":service", "all", "test_tick")
            time.sleep(.35)
            assert fixture["authorizedRequests"] == before, "disabled periodic update sent HTTP"
            evidence["manual_mode_tick_suppressed"] = True
        if not args.hub_url and not args.exercise_provider_icons and not args.capture_transitions and not args.exercise_connection and not args.large_quotas:
            fixture["historyStatus"] = 503
            history_failed = refresh("history-failure", history="error")
            assert history_failed["count"] == 4 and history_failed["windowCount"] == 8, history_failed
            assert history_failed["dailyCount"] == len(history_fixture["daily"]) and history_failed["monthlyCount"] == len(history_fixture["monthly"]), history_failed
            assert history_failed["error"] == "" and history_failed["historyError"] == "http", history_failed
            fixture["historyStatus"] = 200
            refresh("history-recovery")
            fixture["statsStatus"] = 503
            failed = refresh("stats-failure", status="error")
            assert failed["count"] == ready["count"] and failed["windowCount"] == ready["windowCount"], failed
            assert failed["dailyCount"] == len(history_fixture["daily"]) and failed["monthlyCount"] == len(history_fixture["monthly"]) and failed["historyError"] == "", failed
            fixture["statsStatus"] = 200
            refresh("stats-recovery")
            evidence["independent_endpoint_recovery_passed"] = True
        if args.capture_settings:
            command("plugin", PLUGIN_ID + ":panel", "all", "test_action", "settings")
            time.sleep(1)
            subprocess.run(["grim", str(base / "settings.png")], env=env, check=True, capture_output=True, timeout=4)
            evidence["settings_screenshot"] = "settings.png"
        time.sleep(.5)
        log = re.sub(r"\x1b\[[0-9;]*m", "", (base / "runtime.log").read_text())
        errors = [line for line in log.splitlines() if ("token-monitor" in line or "service.luau" in line or "panel.luau" in line) and any(s in line.lower() for s in ("[error", "[err]", "failed:", "cpu budget", "runtime error"))]
        evidence["ui_warnings"] = [line for line in log.splitlines() if "[ui-tree]" in line and "[WRN]" in line]
        evidence["font_errors"] = [line for line in log.splitlines() if any(term in line.lower() for term in
            ("provider icon font could not be loaded", "failed to load font", "font loading failed", "font load failed"))]
        assert not evidence["font_errors"], evidence["font_errors"]
        evidence["plugin_runtime_errors"] = errors
        evidence["processing_diagnostics"] = [line for line in log.splitlines() if "Token Monitor processing:" in line]
        assert not evidence["processing_diagnostics"], evidence["processing_diagnostics"]
        evidence["cpu_budget_errors"] = log.count("exceeded its CPU budget")
        assert not errors and not evidence["cpu_budget_errors"] and not evidence["ui_warnings"], errors + evidence["ui_warnings"]
        if args.capture_transitions:
            assert evidence["transitions"]["passed"], "native ghost-button transition assertions failed; inspect transitions.cases pixels, target render, and sampling"
        evidence["passed"] = True
    except Exception as error:
        evidence["failure"] = str(error)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
        if server:
            server.shutdown(); server.server_close()
        evidence["fixture"] = fixture if not args.hub_url else None
        evidence["processes_reaped"] = all(p.poll() is not None for p in processes)
        # Private tree includes fixture secret; retain only sanitized evidence/logs.
        shutil.rmtree(private)
        (base / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps({"directory": str(base), "passed": evidence["passed"], "failure": evidence.get("failure")}))
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
