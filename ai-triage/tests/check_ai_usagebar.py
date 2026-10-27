#!/usr/bin/env python3
"""Check the installed CLI catalog/contract and optionally render a live report.

Run from the repository root: python tests/check_ai_usagebar.py [--live]
Only --live queries configured providers. No credentials are read by this script.
"""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import tomllib


def lua(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        # JSON/Lua share these escapes; escape remaining control bytes as hex.
        text = json.dumps(value, ensure_ascii=False)
        return re.sub(r"\\u00([0-9a-fA-F]{2})", r"\\x\1", text)
    if isinstance(value, list):
        return "{" + ",".join(lua(v) for v in value) + "}"
    return "{" + ",".join(f"[{lua(k)}]={lua(v)}" for k, v in value.items()) + "}"


def cli(*args):
    return subprocess.check_output(["ai-usagebar", *args], text=True, timeout=180)


def check_query_process(env):
    command = subprocess.check_output(
        ["lua", "tests/compatibility_test.lua", "--query-command"], text=True, env=env)
    with tempfile.TemporaryDirectory(prefix="ai-triage-process-") as directory:
        fake = Path(directory) / "ai-usagebar"
        fake.write_text("#!/usr/bin/env python3\nimport os,time\n"
                        "time.sleep(float(os.getenv('TRIAGE_TEST_DELAY','0')))\n"
                        "print('{\"schema_version\":1,\"entries\":[]}')\n"
                        "raise SystemExit(int(os.getenv('TRIAGE_TEST_EXIT','0')))\n")
        fake.chmod(0o700)
        for code, delay, deadline in [(0, "0", "180"), (127, "0", "180"), (124, "2", "0.05")]:
            test_env = {**env, "PATH": directory + os.pathsep + env["PATH"],
                        "TRIAGE_TEST_EXIT": str(code if code != 124 else 0), "TRIAGE_TEST_DELAY": delay}
            result = subprocess.run(["/bin/sh", "-c", command.replace("180s ai-usagebar", deadline + "s ai-usagebar")],
                                    text=True, capture_output=True, check=True, timeout=5, env=test_env)
            assert result.stdout.splitlines()[-1] == f"__AI_TRIAGE_EXIT__{code}", "query completion marker lost"
    print("ok: real query wrapper handles successful, missing-command and timed-out child processes", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    manifest = tomllib.loads(Path("plugin.toml").read_text())
    offered = next(s for widget in manifest["widget"] for s in widget.get("setting", [])
                   if s["key"] == "vendor")["options"]
    catalog = json.loads(cli("vendors", "--json"))["vendors"]
    expected = json.loads(Path("tests/fixtures/ai_usagebar_1_43_catalog.json").read_text())
    ids = {entry["id"] for entry in catalog}
    assert ids == {entry["id"] for entry in expected}, "CLI provider catalog changed: review compatibility"
    assert ids <= {option["value"] for option in offered}, "provider selector misses CLI providers"
    for path in Path("translations").glob("*.json"):
        translations = json.loads(path.read_text())
        for option in offered:
            node = translations
            for key in option["label_key"].split("."):
                node = node.get(key, {})
            assert isinstance(node, str), f"missing {path}: {option['label_key']}"
        diagnostic = translations["ui"]["diagnostic"]
        english = json.loads(Path("translations/en.json").read_text())["ui"]["diagnostic"]
        for group in ["cause", "action"]:
            assert diagnostic[group].keys() == english[group].keys(), f"incomplete {path}: diagnostic {group}"
            for key, message in diagnostic[group].items():
                assert set(re.findall(r"{(\w+)}", message)) == set(re.findall(r"{(\w+)}", english[group][key])), \
                    f"incorrect diagnostic placeholders: {path} {key}"
    print(f"ok: {cli('--version').strip()}, {len(ids)} providers selectable; translations complete", flush=True)
    command = ["lua", "tests/compatibility_test.lua"]
    env = {**os.environ, "TZ": "America/New_York"}
    check_query_process(env)
    if args.live:
        report = json.loads(cli("usage", "--json"))
        assert report["schema_version"] == 1 and isinstance(report["entries"], list)
        with tempfile.TemporaryDirectory(prefix="ai-triage-contract-") as directory:
            path = Path(directory) / "report.lua"
            path.write_text("return " + lua(report))
            path.chmod(0o600)
            subprocess.run(command + [str(path)], check=True, env=env)
        for entry in report["entries"]:
            print(f"live: {entry['id']} status={entry['status']} stale={entry['stale']}")
    else:
        subprocess.run(command, check=True, env=env)


if __name__ == "__main__":
    main()
