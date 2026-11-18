#!/usr/bin/env python3

"""Minimal WireView Varlink transport for Noctalia's socket-less Luau VM."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from collections.abc import Iterator
from typing import Any


DEFAULT_ADDRESS = "/run/wireviewd/io.github.Gustav0ar.WireView"
INTERFACE = "io.github.Gustav0ar.WireView"
MAX_FRAME_BYTES = 4 * 1024 * 1024


def messages(connection: socket.socket) -> Iterator[dict[str, Any]]:
    buffer = b""
    while True:
        chunk = connection.recv(64 * 1024)
        if not chunk:
            if buffer:
                raise RuntimeError("wireviewd closed the socket with an incomplete Varlink frame")
            return
        buffer += chunk
        if len(buffer) > MAX_FRAME_BYTES:
            raise RuntimeError("wireviewd returned an oversized Varlink frame")
        while b"\0" in buffer:
            frame, buffer = buffer.split(b"\0", 1)
            if not frame:
                continue
            decoded = json.loads(frame)
            if not isinstance(decoded, dict):
                raise RuntimeError("wireviewd returned a non-object Varlink reply")
            yield decoded


def emit_reply(reply: dict[str, Any]) -> bool:
    error = reply.get("error")
    if error is not None:
        parameters = reply.get("parameters")
        detail = parameters.get("message") if isinstance(parameters, dict) else None
        raise RuntimeError(f"{error}: {detail}" if detail else str(error))
    parameters = reply.get("parameters", {})
    print(json.dumps(parameters, separators=(",", ":")), flush=True)
    return reply.get("continues") is True


def request(method: str, parameters: dict[str, Any] | None, more: bool) -> None:
    address = os.environ.get("WIREVIEWD_VARLINK_ADDRESS", DEFAULT_ADDRESS)
    payload: dict[str, Any] = {"method": f"{INTERFACE}.{method}"}
    if parameters is not None:
        payload["parameters"] = parameters
    if more:
        payload["more"] = True

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(address)
        connection.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\0")
        if more:
            connection.settimeout(None)
        for reply in messages(connection):
            continues = emit_reply(reply)
            if not more or not continues:
                return
    raise RuntimeError("wireviewd closed the socket without a Varlink reply")


def main() -> None:
    parser = argparse.ArgumentParser(description="WireView plugin Varlink transport")
    commands = parser.add_subparsers(dest="command", required=True)
    call = commands.add_parser("call")
    call.add_argument("method")
    call.add_argument("parameters", nargs="?")
    commands.add_parser("monitor")
    arguments = parser.parse_args()

    if arguments.command == "monitor":
        request("Monitor", None, True)
        return

    parameters = json.loads(arguments.parameters) if arguments.parameters is not None else None
    if parameters is not None and not isinstance(parameters, dict):
        raise ValueError("Varlink parameters must be a JSON object")
    request(arguments.method, parameters, False)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
