"""Local OBS WebSocket v5 client. Credentials never leave this process."""

import argparse
import base64
import fcntl
import hashlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path

import websocket

OUTPUTS = {
    "record": ("GetRecordStatus", "StartRecord", "StopRecord"),
    "replay": ("GetReplayBufferStatus", "StartReplayBuffer", "StopReplayBuffer"),
    "stream": ("GetStreamStatus", "StartStream", "StopStream"),
}


def authentication(password, salt, challenge):
    secret = base64.b64encode(hashlib.sha256((password + salt).encode()).digest())
    return base64.b64encode(
        hashlib.sha256(secret + challenge.encode()).digest()
    ).decode()


def load_config():
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    path = config_home / "obs-studio/plugin_config/obs-websocket/config.json"
    config = json.loads(path.read_text())
    if not isinstance(config, dict):
        raise TypeError("OBS WebSocket configuration must be an object.")
    port = config.get("server_port", 4455)
    if config.get("server_enabled") is not True:
        raise ValueError("Enable the WebSocket server in OBS Tools settings.")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("OBS WebSocket port must be between 1 and 65535.")
    password = config.get("server_password", "")
    if not isinstance(password, str):
        raise TypeError("Invalid OBS WebSocket password configuration.")
    return port, password


class ObsClient:
    def __init__(self, port, password):
        self.ws = websocket.create_connection(
            f"ws://127.0.0.1:{port}", timeout=3, http_no_proxy=["127.0.0.1"]
        )
        self.sequence = 0
        try:
            hello = self.receive()
            if hello.get("op") != 0:
                raise ValueError("OBS did not send a WebSocket v5 Hello.")
            identify = {"rpcVersion": 1, "eventSubscriptions": 0}
            auth = hello["d"].get("authentication")
            if auth:
                identify["authentication"] = authentication(
                    password, auth["salt"], auth["challenge"]
                )
            self.send(1, identify)
            if self.receive().get("op") != 2:
                raise ValueError("OBS WebSocket authentication failed.")
        except Exception:
            self.ws.close()
            raise

    def receive(self):
        raw = self.ws.recv()
        if not raw:
            raise ConnectionError("OBS closed the WebSocket connection.")
        message = json.loads(raw)
        if not isinstance(message, dict) or not isinstance(message.get("d"), dict):
            raise TypeError("Invalid OBS WebSocket message.")
        return message

    def send(self, op, data):
        self.ws.send(json.dumps({"op": op, "d": data}))

    def request(self, request_type):
        self.sequence += 1
        request_id = str(self.sequence)
        self.send(6, {"requestType": request_type, "requestId": request_id})
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            message = self.receive()
            data = message.get("d", {})
            if message.get("op") != 7 or data.get("requestId") != request_id:
                continue
            status = data["requestStatus"]
            if not status.get("result"):
                raise ValueError(
                    f"{request_type}: {status.get('comment', 'request failed')} ({status.get('code')})"
                )
            return data.get("responseData", {})
        raise TimeoutError(f"{request_type}: response timed out")

    def close(self):
        self.ws.close()


def snapshot(client):
    result = {"connected": True}
    for name, (request, _, _) in OUTPUTS.items():
        data = client.request(request)
        result[name] = data.get("outputActive", False)
        if name == "record":
            result["record_time"] = data.get("outputTimecode", "")
            result["paused"] = data.get("outputPaused", False)
    result["virtualcam"] = client.request("GetVirtualCamStatus").get(
        "outputActive", False
    )
    return result


def process_identity(pid):
    """Include start time so a reused PID never becomes our process."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
        return stat[stat.rfind(")") + 2 :].split()[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


def obs_running():
    return (
        subprocess.run(
            ["pgrep", "-x", "obs"], check=False, stdout=subprocess.DEVNULL
        ).returncode
        == 0
    )


def launch(owner_file, managed):
    process = subprocess.Popen(
        ["obs", "--minimize-to-tray"],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if managed:
        owner_file.write_text(
            json.dumps({"pid": process.pid, "start": process_identity(process.pid)})
        )
        owner_file.chmod(0o600)


def close_owned_obs(owner_file, state):
    if (
        any(state.get(name) for name in (*OUTPUTS, "virtualcam"))
        or not owner_file.exists()
    ):
        return False
    owner = json.loads(owner_file.read_text())
    if not isinstance(owner, dict):
        raise TypeError("Invalid managed OBS process state.")
    pid, started = owner.get("pid"), owner.get("start")
    if type(pid) is not int or pid <= 0 or not isinstance(started, str):
        raise ValueError("Invalid managed OBS process state.")
    if process_identity(pid) != started:
        owner_file.unlink(missing_ok=True)
        return False
    os.kill(pid, signal.SIGTERM)
    owner_file.unlink(missing_ok=True)
    return True


def perform(client, action, owner_file, auto_close, open_videos):
    if action == "status":
        return snapshot(client)
    if action == "save-replay":
        client.request("SaveReplayBuffer")
        return {**snapshot(client), "message": "Replay saved"}
    if action == "open-videos":
        directory = client.request("GetRecordDirectory")["recordDirectory"]
        subprocess.Popen(
            ["xdg-open", directory],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return snapshot(client)
    output = action.removeprefix("toggle-")
    get_status, start, stop = OUTPUTS[output]
    was_active = client.request(get_status).get("outputActive", False)
    response = client.request(stop if was_active else start)
    state = snapshot(client)
    if was_active and auto_close:
        # Stop responses can arrive before OBS finishes transitioning the output.
        deadline = time.monotonic() + 3
        while state.get(output) and time.monotonic() < deadline:
            time.sleep(0.2)
            state = snapshot(client)
        state["closed"] = close_owned_obs(owner_file, state)
        if state["closed"]:
            state["connected"] = False
    if was_active and output == "record" and open_videos and response.get("outputPath"):
        subprocess.Popen(
            ["xdg-open", str(Path(response["outputPath"]).parent)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return {
        **state,
        "message": f"{output.capitalize()} {'stopped' if was_active else 'started'}",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=[
            "status",
            "launch",
            "open-videos",
            "save-replay",
            "toggle-record",
            "toggle-replay",
            "toggle-stream",
        ],
    )
    parser.add_argument("--auto-close", action="store_true")
    parser.add_argument("--open-videos", action="store_true")
    args = parser.parse_args()
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        raise ValueError("XDG_RUNTIME_DIR is required for session process ownership.")
    directory = Path(runtime) / "noctalia-obs-control"
    directory.mkdir(mode=0o700, exist_ok=True)
    owner_file = directory / "owner.json"
    with (directory / "action.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "launch":
            if not obs_running():
                launch(owner_file, False)
            return {"message": "OBS launched"}
        port, password = load_config()
        running = obs_running()
        if args.action == "status" and not running:
            return {"connected": False, "message": "OBS is not running"}
        if not running:
            if not args.action.startswith("toggle-"):
                raise ValueError("Launch OBS before using this action.")
            launch(owner_file, args.auto_close)
        deadline = time.monotonic() + (15 if not running else 3)
        while True:
            try:
                client = ObsClient(port, password)
                break
            except (
                ConnectionRefusedError,
                websocket.WebSocketConnectionClosedException,
            ):
                if time.monotonic() >= deadline:
                    raise ConnectionError(
                        "Cannot connect to the local OBS WebSocket server."
                    ) from None
                time.sleep(0.5)
        try:
            return perform(
                client, args.action, owner_file, args.auto_close, args.open_videos
            )
        finally:
            client.close()


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        TimeoutError,
        websocket.WebSocketException,
    ) as error:
        print(json.dumps({"connected": False, "error": str(error)}))
        raise SystemExit(1)
