#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path


BRIDGE = Path(__file__).resolve().parents[1] / "varlink_bridge.py"


def call(socket: str, method: str) -> dict[str, object]:
    environment = os.environ.copy()
    environment["WIREVIEWD_VARLINK_ADDRESS"] = socket
    result = subprocess.run(
        [
            "python3",
            str(BRIDGE),
            "call",
            method,
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
        env=environment,
    )
    reply = json.loads(result.stdout)
    assert isinstance(reply, dict)
    return reply


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Check the plugin's read-only Varlink contract against a test daemon."
    )
    parser.add_argument("socket", help="Path to a disposable wireviewd socket")
    args = parser.parse_args()

    status = call(args.socket, "GetStatus")
    assert status["api_version"] in {1, 2}
    assert {"telemetry", "configuration-items", "device-control"} <= set(status["api_capabilities"])

    telemetry = call(args.socket, "GetTelemetry")
    for field in ("pin_voltages_v", "pin_currents_a", "pin_power_w"):
        assert len(telemetry[field]) == 6

    configuration = call(args.socket, "GetConfiguration")
    settings = json.loads(configuration["configuration_json"])
    assert "fan" in settings
    assert "display" in settings

    print("Direct wireviewd Varlink checks passed.")


if __name__ == "__main__":
    main()
