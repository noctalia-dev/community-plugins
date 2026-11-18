"""One SSH master per profile. Systemd owns retries, lifetime and shutdown."""

from __future__ import annotations

import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from .model import RUNTIME, Profile, atomic_json, check_ports, forward_spec, load, private_dir
from .supervisor import notify, state_file
from .tools import executable


def master_argv(profile: Profile, path: Path) -> list[str]:
    # Clearing config forwards keeps the profile authoritative. Identity, routing
    # and host-key policy still come from the user's normal SSH configuration.
    options = [
        "BatchMode=yes",
        "ExitOnForwardFailure=yes",
        "ServerAliveInterval=10",
        "ServerAliveCountMax=2",
        "ConnectTimeout=10",
        "ConnectionAttempts=1",
        "ClearAllForwardings=yes",
        "ControlMaster=yes",
        "ControlPersist=no",
        "ForkAfterAuthentication=no",
        "RequestTTY=no",
        "RemoteCommand=none",
        "SessionType=none",
        "PermitLocalCommand=no",
        "GatewayPorts=no",
    ]
    argv = [executable("ssh"), "-NT", "-S", str(path)]
    for option in options:
        argv.extend(["-o", option])
    return [*argv, profile["host"]]


def mux_argv(profile: Profile, path: Path, action: str) -> list[str]:
    # The master already resolved config and authenticated. A config-free mux
    # request prevents inherited forwards from being added a second time.
    argv = [
        executable("ssh"),
        "-F",
        "/dev/null",
        "-S",
        str(path),
        "-O",
        action,
        "-o",
        "ExitOnForwardFailure=yes",
    ]
    if action == "forward":
        for mapping in profile["mappings"]:
            argv.extend(["-L", forward_spec(mapping)])
    return [*argv, profile["host"]]


def permanent_error(message: str) -> bool:
    return any(
        part in message.lower()
        for part in (
            "permission denied",
            "authentication failed",
            "host key verification failed",
            "remote host identification has changed",
            "address already in use",
            "cannot listen",
            "bad configuration option",
            "bad owner or permissions",
            "unprotected private key",
            "invalid format",
            "administratively prohibited",
            "sign_and_send_pubkey: signing failed",
        )
    )


def useful_error(message: str) -> str:
    if "permission denied" in message.lower() or "authentication failed" in message.lower():
        return (
            f"SSH authentication failed. Check the SSH user, key or unlocked ssh-agent. {message}"
        )
    if "address already in use" in message.lower() or "cannot listen" in message.lower():
        return (
            "Local port conflict. Stop its owner or edit the mapping; "
            f"ports are preserved. {message}"
        )
    if "host key" in message.lower() or "identification has changed" in message.lower():
        return f"SSH host-key verification failed. Verify this host in a terminal. {message}"
    return message


def owns_listeners(pid: int, ports: set[int]) -> bool:
    """Read-only ownership check; never probe arbitrary forwarded applications."""
    try:
        inodes: set[str] = set()
        for link in Path(f"/proc/{pid}/fd").iterdir():
            try:
                inodes.add(link.readlink().name)
            except FileNotFoundError:
                continue  # An unrelated transient descriptor may close during the scan.
        listening: set[int] = set()
        for row in Path("/proc/net/tcp").read_text().splitlines()[1:]:
            fields = row.split()
            address, hex_port = fields[1].split(":")
            loopback = "0100007F" if sys.byteorder == "little" else "7F000001"
            if address == loopback and fields[3] == "0A" and f"socket:[{fields[9]}]" in inodes:
                listening.add(int(hex_port, 16))
        return ports <= listening
    except (FileNotFoundError, ProcessLookupError):
        return False
    except OSError as error:
        raise ValueError(
            "Cannot inspect SSH loopback listeners in /proc. Check process-inspection permissions."
        ) from error


def run(profile_id: str) -> int:
    stopping = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    profile = load().get(profile_id)
    if profile is None:
        raise ValueError(f"Unknown profile: {profile_id}")
    private_dir(RUNTIME)
    path = RUNTIME / f"{profile_id}.sock"
    path.unlink(missing_ok=True)
    destination = state_file(profile_id)

    def publish(phase: str, error: str = "") -> None:
        atomic_json(
            destination,
            {"state": phase, "error": error, "pid": os.getpid(), "updated": time.time()},
        )
        notify(f"STATUS={phase}: {error}".strip())

    try:
        check_ports(profile)
    except ValueError as error:
        publish("error", str(error))
        print(error, flush=True)
        return 78
    publish("connecting")
    process = subprocess.Popen(
        master_argv(profile, path),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    lines: queue.SimpleQueue[str] = queue.SimpleQueue()

    def read_errors() -> None:
        assert process.stderr is not None
        for line in process.stderr:
            text = line.strip()
            if text:
                print(text, flush=True)
                lines.put(text)

    reader = threading.Thread(target=read_errors, daemon=True)
    reader.start()
    deadline = time.monotonic() + 20
    established = False
    last_error = ""
    fatal = False
    try:
        while not stopping.is_set():
            while not lines.empty():
                last_error = useful_error(lines.get())
                fatal = fatal or permanent_error(last_error)
                if established:
                    publish("connected", last_error)
            if process.poll() is not None:
                reader.join(timeout=1)
                while not lines.empty():
                    last_error = useful_error(lines.get())
                    fatal = fatal or permanent_error(last_error)
                break
            if not established and path.exists():
                check = subprocess.run(
                    mux_argv(profile, path, "check"),
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )
                if check.returncode == 0:
                    result = subprocess.run(
                        mux_argv(profile, path, "forward"),
                        capture_output=True,
                        text=True,
                        timeout=5,
                        check=False,
                    )
                    if result.returncode:
                        last_error = useful_error(
                            result.stderr.strip() or "SSH refused the forwarding request."
                        )
                        fatal = permanent_error(last_error)
                        break
                    ports = {mapping["local_port"] for mapping in profile["mappings"]}
                    if not owns_listeners(process.pid, ports):
                        last_error = "SSH did not create all configured loopback listeners."
                        fatal = True
                        break
                    established = True
                    publish("connected")
                    notify("READY=1")
            if not established and time.monotonic() > deadline:
                last_error = last_error or "SSH connection timed out; retrying automatically."
                break
            stopping.wait(0.25)
        if stopping.is_set():
            publish("disconnected")
            return 0
        last_error = (
            last_error
            or f"SSH connection ended (exit {process.returncode}); retrying automatically."
        )
        publish("error" if fatal else "reconnecting", last_error)
        print(last_error, flush=True)
        return 78 if fatal else 1
    except ValueError as error:
        publish("error", str(error))
        print(error, flush=True)
        return 78
    except subprocess.TimeoutExpired:
        message = "SSH control request timed out; retrying automatically."
        publish("reconnecting", message)
        print(message, flush=True)
        return 1
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        reader.join(timeout=1)
        if process.stderr is not None:
            process.stderr.close()
        path.unlink(missing_ok=True)
