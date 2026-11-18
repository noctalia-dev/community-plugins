from backend.routing.rules import (
    PRESETS,
    preset_domain_tags,
    preset_route_rules,
    preset_rule_sets,
)

ALL = list(PRESETS.keys())


def test_presets_shape():
    for key, preset in PRESETS.items():
        assert preset["key"] == key
        assert preset["name"] and preset["flag"] and preset["description"]
        assert preset["rule_sets"], key
        for rs in preset["rule_sets"]:
            assert rs["type"] == "remote"
            assert rs["format"] == "binary"
            assert rs["url"].startswith("https://")
            assert rs["download_detour"] == "direct"


def test_rule_set_tags_unique_across_presets():
    tags = [rs["tag"] for p in PRESETS.values() for rs in p["rule_sets"]]
    assert len(tags) == len(set(tags))


def test_route_rules_target_proxy():
    rules = preset_route_rules(ALL)
    assert len(rules) == len(ALL)
    for rule in rules:
        assert rule["outbound"] == "proxy"
        assert rule["rule_set"]


def test_every_preset_has_a_domain_rule_set():
    # The DNS layer resolves proxied domains through the tunnel; a preset
    # whose tags all look IP-only would silently skip that protection.
    for key in ALL:
        assert preset_domain_tags([key]), key


def test_unknown_preset_ignored():
    assert preset_rule_sets(["nope"]) == []
    assert preset_route_rules(["nope"]) == []
