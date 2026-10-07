"""Regression tests for authentication, output control and process ownership."""

import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import obs_control as obs


class ObsControlTests(unittest.TestCase):
    def test_malformed_websocket_message_is_rejected(self):
        client = obs.ObsClient.__new__(obs.ObsClient)
        client.ws = Mock()
        for message in ([], {"op": 0, "d": []}):
            with self.subTest(message=message):
                client.ws.recv.return_value = json.dumps(message)
                with self.assertRaisesRegex(TypeError, "Invalid OBS WebSocket"):
                    client.receive()

    def test_malformed_owner_state_never_signals_a_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            owner = Path(tmp) / "owner.json"
            owner.write_text("[]")
            with patch.object(obs.os, "kill") as kill:
                with self.assertRaisesRegex(TypeError, "managed OBS process state"):
                    obs.close_owned_obs(owner, {})
                kill.assert_not_called()

    def test_authentication_matches_obs_protocol(self):
        secret = base64.b64encode(hashlib.sha256(b"passwordsalt").digest())
        expected = base64.b64encode(
            hashlib.sha256(secret + b"challenge").digest()
        ).decode()
        self.assertEqual(obs.authentication("password", "salt", "challenge"), expected)

    def test_authenticated_handshake_and_request_ignore_events(self):
        ws = Mock()
        ws.recv.side_effect = [
            json.dumps(
                {"op": 0, "d": {"authentication": {"salt": "s", "challenge": "c"}}}
            ),
            json.dumps({"op": 2, "d": {}}),
            json.dumps({"op": 5, "d": {"eventType": "RecordStateChanged"}}),
            json.dumps(
                {
                    "op": 7,
                    "d": {
                        "requestId": "1",
                        "requestStatus": {"result": True},
                        "responseData": {"outputActive": True},
                    },
                }
            ),
        ]
        with patch.object(
            obs.websocket, "create_connection", return_value=ws
        ) as connect:
            client = obs.ObsClient(4455, "secret")
            self.assertEqual(client.request("GetRecordStatus"), {"outputActive": True})
        self.assertEqual(connect.call_args.args[0], "ws://127.0.0.1:4455")
        identify = json.loads(ws.send.call_args_list[0].args[0])
        self.assertEqual(
            identify["d"]["authentication"], obs.authentication("secret", "s", "c")
        )
        self.assertEqual(identify["d"]["eventSubscriptions"], 0)

    def test_request_preserves_obs_error(self):
        client = obs.ObsClient.__new__(obs.ObsClient)
        client.sequence = 0
        client.ws = Mock()
        client.ws.recv.return_value = json.dumps(
            {
                "op": 7,
                "d": {
                    "requestId": "1",
                    "requestStatus": {
                        "result": False,
                        "comment": "Replay buffer not active",
                        "code": 501,
                    },
                },
            }
        )
        with self.assertRaisesRegex(ValueError, "Replay buffer not active.*501"):
            client.request("SaveReplayBuffer")

    def test_toggle_selects_start_and_stop_for_each_output(self):
        for output, (status, start, stop) in obs.OUTPUTS.items():
            for active in (False, True):
                with self.subTest(output=output, active=active):
                    client = Mock()
                    client.request.side_effect = [{"outputActive": active}, {}]
                    with patch.object(
                        obs, "snapshot", return_value={"connected": True}
                    ):
                        obs.perform(
                            client, "toggle-" + output, Path("/unused"), False, False
                        )
                    self.assertEqual(client.request.call_args_list[0].args, (status,))
                    self.assertEqual(
                        client.request.call_args_list[1].args,
                        (stop if active else start,),
                    )

    def test_auto_close_preserves_every_active_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            owner = Path(tmp) / "owner.json"
            owner.write_text(json.dumps({"pid": 123, "start": "456"}))
            for output in (*obs.OUTPUTS, "virtualcam"):
                with self.subTest(output=output), patch.object(obs.os, "kill") as kill:
                    self.assertFalse(obs.close_owned_obs(owner, {output: True}))
                    kill.assert_not_called()
                    self.assertTrue(owner.exists())

    def test_auto_close_never_kills_reused_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            owner = Path(tmp) / "owner.json"
            owner.write_text(json.dumps({"pid": 123, "start": "456"}))
            with (
                patch.object(obs, "process_identity", return_value="999"),
                patch.object(obs.os, "kill") as kill,
            ):
                self.assertFalse(obs.close_owned_obs(owner, {}))
                kill.assert_not_called()
            self.assertFalse(owner.exists())

    def test_auto_close_only_signals_owned_idle_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            owner = Path(tmp) / "owner.json"
            owner.write_text(json.dumps({"pid": 123, "start": "456"}))
            with (
                patch.object(obs, "process_identity", return_value="456"),
                patch.object(obs.os, "kill") as kill,
            ):
                self.assertTrue(obs.close_owned_obs(owner, {}))
                kill.assert_called_once_with(123, obs.signal.SIGTERM)
            self.assertFalse(owner.exists())

    def test_stop_waits_for_output_transition_before_auto_close(self):
        client = Mock()
        client.request.side_effect = [{"outputActive": True}, {}]
        with (
            patch.object(
                obs, "snapshot", side_effect=[{"record": True}, {"record": False}]
            ),
            patch.object(obs.time, "sleep"),
            patch.object(obs, "close_owned_obs", return_value=True) as close,
        ):
            result = obs.perform(client, "toggle-record", Path("/unused"), True, False)
        close.assert_called_once()
        self.assertEqual(close.call_args.args[0], Path("/unused"))
        self.assertFalse(close.call_args.args[1]["record"])
        self.assertTrue(result["closed"])
        self.assertFalse(result["connected"])

    def test_config_rejects_non_object_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "obs-studio/plugin_config/obs-websocket/config.json"
            config.parent.mkdir(parents=True)
            config.write_text("[]")
            with (
                patch.dict(obs.os.environ, {"XDG_CONFIG_HOME": tmp}),
                self.assertRaises(TypeError),
            ):
                obs.load_config()

    def test_invalid_port_is_rejected_before_connecting(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "obs-studio/plugin_config/obs-websocket/config.json"
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps({"server_enabled": True, "server_port": True}))
            with (
                patch.dict(obs.os.environ, {"XDG_CONFIG_HOME": tmp}),
                self.assertRaisesRegex(ValueError, "port"),
            ):
                obs.load_config()


if __name__ == "__main__":
    unittest.main()
