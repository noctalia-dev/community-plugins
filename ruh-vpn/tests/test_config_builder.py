import json
import shutil
import subprocess

import pytest

from backend.routing.rules import PRESETS
from backend.singbox import config_builder

ALL = list(PRESETS.keys())


def test_rules_config_includes_presets():
    cfg = config_builder.build_rules_config(active_presets=ALL)
    tags = {rs["tag"] for rs in cfg["route"]["rule_set"]}
    expected = {rs["tag"] for p in PRESETS.values() for rs in p["rule_sets"]}
    assert expected <= tags
    proxy_rules = [r for r in cfg["route"]["rules"] if r.get("outbound") == "proxy" and "rule_set" in r]
    assert len(proxy_rules) == len(ALL)


def test_rules_config_dns_covers_domain_rule_sets():
    cfg = config_builder.build_rules_config(active_presets=ALL)
    dns_rule_sets = [r["rule_set"] for r in cfg["dns"]["rules"] if "rule_set" in r]
    flattened = {t for group in dns_rule_sets for t in group}
    assert "refilter_domains" in flattened
    assert "geosite_noncn" in flattened
    assert "geosite_sanctioned" in flattened


@pytest.mark.skipif(shutil.which("sing-box") is None, reason="sing-box not installed")
@pytest.mark.parametrize("presets", [[], ALL])
def test_sing_box_accepts_generated_configs(tmp_path, presets):
    for name, cfg in {
        "rules": config_builder.build_rules_config(active_presets=presets),
        "global": config_builder.build_global_config(),
    }.items():
        path = tmp_path / f"{name}.json"
        path.write_text(json.dumps(cfg))
        proc = subprocess.run(
            ["sing-box", "check", "-c", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        assert proc.returncode == 0, f"{name}: {proc.stderr}"
