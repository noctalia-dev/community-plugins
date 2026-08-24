#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    manifest = tomllib.loads((ROOT / "plugin.toml").read_text())
    assert manifest["id"] == "gustav0ar/wireview-pro-ii"
    assert manifest["version"] == "0.3.0"
    assert manifest["plugin_api"] == 9
    assert "wireview" not in manifest["dependencies"]
    assert "python3" in manifest["dependencies"]
    dashboard = manifest["panel"][0]
    assert dashboard["placement"] == "attached"
    assert dashboard["position"] == "auto"
    assert dashboard["open_near_click"] is True
    fault_layout = dashboard["setting"][0]
    assert fault_layout["key"] == "faults_layout"
    assert fault_layout["default"] == "side_by_side"
    assert {option["value"] for option in fault_layout["options"]} == {"side_by_side", "stacked"}

    service = (ROOT / "service.luau").read_text()
    assert "SUPPORTED_APIS = { [1] = true, [2] = true }" in service
    assert "wireview telemetry" not in service
    assert "varlinkctl" not in service
    for method in (
        "GetStatus",
        "GetTelemetry",
        "Monitor",
        "GetConfiguration",
        "SetConfigurationItem",
        "SetPollInterval",
        "SetScreen",
        "ClearFaults",
    ):
        assert method in service

    bridge = (ROOT / "varlink_bridge.py").read_text()
    assert "/run/wireviewd/io.github.Gustav0ar.WireView" in bridge
    assert "socket.AF_UNIX" in bridge
    assert 'b"\\0"' in bridge

    telemetry = json.loads((ROOT / "tests" / "telemetry.json").read_text())
    for field in ("pin_voltages_v", "pin_currents_a", "pin_power_w"):
        assert len(telemetry[field]) == 6
    assert 0 <= telemetry["total_power_w"] / telemetry["cable_capability_w"] <= 1
    assert abs(sum(telemetry["pin_power_w"]) - telemetry["total_power_w"]) < 1

    panel = (ROOT / "panel.luau").read_text()
    assert "varlink" not in panel.lower()
    for tab in ("OVERVIEW", "PINS", "FAULTS", "CONFIGURE"):
        assert tab in panel
    for role in (
        '"primary"',
        '"error"',
        '"surface"',
        '"on_surface"',
        '"on_surface_variant"',
        '"outline/0.55"',
    ):
        assert role in panel
    assert re.search(r"#[0-9a-fA-F]{3,8}", panel) is None
    assert "flexGrow = 1" in panel
    assert "height = 72" in panel
    assert "height = 96" in panel
    assert "height = 292" in panel
    assert "height = 312" in panel
    assert 'align = "stretch"' in panel
    assert "local function faultPane" in panel
    assert '"SAMPLE "' not in panel
    for fault in (
        "chip_over_temperature",
        "sensor_over_temperature",
        "over_current",
        "wire_over_current",
        "over_power",
        "current_imbalance",
    ):
        assert fault in panel
    for human_label in (
        "Monitoring chip is too hot",
        "Connector temperature is too high",
        "Total current is too high",
        "A conductor is carrying too much current",
        "Total power is too high",
        "Current is uneven across conductors",
    ):
        assert human_label in panel
    assert "ACTIVE MASK" not in panel
    assert "LOGGED MASK" not in panel
    assert '"HEX"' not in panel
    assert "local function exceedsThreshold" in panel
    assert 'exceedsThreshold(current, "wire_current_a")' in panel
    assert 'exceedsThreshold(value, "temperature_c")' in panel
    assert 'exceedsThreshold(snapshot and snapshot.total_current_a, "total_current_a")' in panel
    assert 'exceedsThreshold(snapshot and snapshot.total_power_w, "total_power_w")' in panel
    assert 'color = currentHigh and DANGER or MUTED' in panel
    assert 'color = totalPowerIsHigh() and DANGER or TEXT' in panel
    for threshold in (
        "fault_thresholds.temperature_c",
        "fault_thresholds.total_current_a",
        "fault_thresholds.wire_current_a",
        "fault_thresholds.total_power_w",
        "fault_thresholds.current_imbalance_percent",
        "fault_thresholds.current_imbalance_min_load_a",
    ):
        assert threshold in panel
        assert threshold in service
    assert "FAULT LIMITS" in panel
    assert "ABOVE LIMIT" in panel
    assert "Clear this conductor alarm on the device" in panel
    assert "Clear this active alarm on the device" in panel
    assert 'action = "clear"' in panel
    assert 'methodCommand("ClearFaults"' in service
    assert 'methodCommand("SetScreen"' in service
    assert 'hasCapability(status, "device-control")' in service
    assert 'SCREEN_REQUEST_KEY = "wireview.screen.request"' in service
    assert 'noctalia.state.watch(SCREEN_REQUEST_KEY, handleScreenRequest)' in service
    assert 'confirm = true' in service
    assert 'FAULT_OBSERVATIONS_KEY = "wireview.fault.observations"' in service
    assert "publishFaultObservations(snapshot)" in service
    assert "observed_at_ms" in service
    assert "masksOverlap(refreshed.logged_fault_mask, loggedMask)" in service
    assert "updated_at = os.time()" in service
    assert "function onIpc(event, payload)" in panel
    assert "REVIEW DEVICE STORE" in panel
    assert "STORE TO DEVICE" in panel
    assert 'noctalia.getConfig("faults_layout") == "stacked"' in panel
    assert "TELEMETRY UNAVAILABLE" in panel
    assert "Values frozen" in panel
    assert "History first observed" in panel
    assert "CONDITION STILL PRESENT" in panel
    assert 'panel.setWantsSecondTicks(true)' in panel
    assert "preview-release" not in panel
    assert "Screen shown now" in panel
    assert "Choose screen" in panel
    assert 'action = "set"' in panel
    assert 'noctalia.state.watch("wireview.screen.operation"' in panel

    widget = (ROOT / "widget.luau").read_text()
    assert '"primary"' in widget
    assert '"on_surface"' in widget
    assert '"on_surface_variant"' in widget
    assert "active_fault_mask" in widget
    assert 'return "error"' in widget
    assert 'noctalia.togglePanel("gustav0ar/wireview-pro-ii:dashboard")' in widget
    assert 'or "STALE"' in widget

    for user_facing_protocol_copy in (
        "Live Varlink telemetry",
        "Writing verified settings through Varlink",
        "Varlink monitor",
        "Varlink socket",
        "Varlink request failed",
    ):
        assert user_facing_protocol_copy not in service
    assert re.search(r"#[0-9a-fA-F]{3,8}", widget) is None

    translations = json.loads((ROOT / "translations" / "en.json").read_text())
    fault_layout_translations = translations["settings"]["faults_layout"]
    assert fault_layout_translations["label"] == "Fault page layout"
    assert fault_layout_translations["stacked"] == "Stacked"

    catalog_path = ROOT.parent / "catalog.toml"
    if catalog_path.is_file():
        catalog = tomllib.loads(catalog_path.read_text())
        matching_entries = [
            entry for entry in catalog.get("plugin", []) if entry["id"] == manifest["id"]
        ]
        if matching_entries:
            catalog_entry = matching_entries[0]
            assert catalog_entry["version"] == manifest["version"]
            assert catalog_entry["plugin_api"] == manifest["plugin_api"]
    assert (ROOT / "CHANGELOG.md").is_file()

    print("WireView Pro II plugin contract checks passed.")


if __name__ == "__main__":
    main()
