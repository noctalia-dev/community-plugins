import base64
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "bridge", Path(__file__).resolve().parents[1] / "bridge.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class Variant:
    def __init__(self, value):
        self.value = value

    def unpack(self):
        return self.value


class DBusError(RuntimeError):
    """GLib errors also inherit RuntimeError, including remote D-Bus failures."""

    def __init__(self, name="UnknownObject"):
        super().__init__(
            "g-dbus-error-quark: GDBus.Error:org.freedesktop.DBus.Error."
            + name
            + ": No such object path '/modules/kdeconnect/devices/phone/notifications/100' (41)"
        )
        self.name = name

    def matches(self, domain, code):
        return domain == "g-dbus-error-quark" and code == self.name


class BridgeTests(unittest.TestCase):
    def test_missing_pygobject_reports_actionable_json_error(self):
        output = io.StringIO()
        with (
            patch.dict(sys.modules, {"gi": None, "gi.repository": None}),
            patch("sys.argv", ["bridge.py", "check"]),
            patch("sys.stdout", output),
        ):
            self.assertEqual(bridge.main(), 1)

        response = json.loads(output.getvalue())
        self.assertFalse(response["ok"])
        self.assertIn("PyGObject", response["message"])
        self.assertIn("python-gobject", response["message"])
        self.assertIn("python3-gi", response["message"])

    def test_large_request_reply_is_one_json_object(self):
        event = {
            "type": "threads",
            "device": "a",
            "items": [{"id": str(i), "body": "Unicode 👋\n" * 30} for i in range(700)],
        }
        output = io.StringIO()
        with (
            patch.object(bridge, "Bridge") as backend,
            patch("sys.argv", ["bridge.py", "request", '{"op":"sync","device":"a"}']),
            patch("sys.stdout", output),
        ):
            backend.return_value.request.return_value = [event]
            self.assertEqual(bridge.main(), 0)

        self.assertGreater(len(output.getvalue().encode("utf-8")), 64 * 1024)
        self.assertEqual(json.loads(output.getvalue()), {"ok": True, "events": [event]})

    def test_large_snapshot_stream_framing(self):
        event = {
            "type": "threads",
            "device": "a",
            "items": [{"id": str(i), "body": 'Multiline\n你好 👋 \\"' * 30} for i in range(700)],
        }
        lines = list(bridge.stream_lines(event))
        self.assertGreater(len(lines), 1)
        chunks = [json.loads(line) for line in lines]
        self.assertTrue(all(len(line.encode("utf-8")) < 64 * 1024 for line in lines))
        self.assertEqual([c["index"] for c in chunks], list(range(1, len(chunks) + 1)))
        self.assertTrue(all(c["count"] == len(chunks) for c in chunks))
        self.assertEqual(json.loads("".join(c["data"] for c in chunks)), event)
        small = {"type": "notification_removed", "id": "1"}
        self.assertEqual([json.loads(line) for line in bridge.stream_lines(small)], [small])

    def test_nested_message_and_attachments(self):
        value = Variant(
            (
                1,
                "Hello 👋\n你好 — O'Brien",
                [Variant(("+1 (555) 010-0100",))],
                123456789,
                2,
                0,
                42,
                7,
                3,
                [Variant((1, "image/png", "", "x"))],
            )
        )
        message = bridge.decode_message(value)
        self.assertEqual(message["thread"], "42")
        self.assertEqual(message["id"], "7")
        self.assertTrue(message["outgoing"])
        self.assertEqual(message["attachments"], 1)
        self.assertEqual(message["addresses"], ["+1 (555) 010-0100"])
        self.assertIn("你好", message["body"])

    def test_old_message_and_invalid_format(self):
        message = bridge.decode_message((1, "body", [("123",)], 1, 1, 1, 2, 3))
        self.assertFalse(message["outgoing"])
        self.assertEqual(message["subId"], "-1")
        with self.assertRaises(ValueError):
            bridge.decode_message(("unexpected",))

    def test_vcard_unicode_folding_multiple_numbers(self):
        contact = bridge.parse_vcard(
            "BEGIN:VCARD\r\nFN:Zoë\\, Long\r\n Name\r\n"
            "TEL;TYPE=CELL:tel:%2B1-555-0100\r\n"
            "item1.TEL;TYPE=HOME:+1 (555) 0200\r\nTEL:+1 555 0100\r\nEND:VCARD",
            "7",
        )
        self.assertEqual(contact["name"], "Zoë, LongName")
        self.assertEqual(contact["numbers"], ["+1-555-0100", "+1 (555) 0200"])
        self.assertIn("zoë", contact["search"])
        self.assertIsNone(bridge.parse_vcard("FN:No number", "8"))

    def test_contact_cache_is_device_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "kpeoplevcard" / "kdeconnect-phone_a"
            cache.mkdir(parents=True)
            (cache / "1.vcf").write_text("FN:Alex\nTEL:123", encoding="utf-8")
            (cache / "1.meta").write_text("FN:Ignore\nTEL:456", encoding="utf-8")
            self.assertEqual(len(bridge.read_contacts("phone_a", directory)), 1)
            self.assertEqual(bridge.read_contacts("phone_b", directory), [])

    def test_vcard_quoted_printable_names_and_soft_lines(self):
        contact = bridge.parse_vcard(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:=5A=6F=C3=AB=20=\r\n"
            "=E6=9D=8E\r\nTEL:123\r\nEND:VCARD",
            "quoted",
        )
        self.assertEqual(contact["name"], "Zoë 李")
        self.assertIn("zoë 李", contact["search"])
        fallback = bridge.parse_vcard(
            "N;ENCODING=QUOTED-PRINTABLE:=4D=6F=72=67=61=6E;=41=6C=65=78;;;\nTEL:123", "fallback"
        )
        self.assertEqual(fallback["name"], "Morgan Alex")

    def test_vcard_base64_and_legacy_charset(self):
        contact = bridge.parse_vcard('FN;CHARSET="UTF-8";ENCODING=b:Wm/Dqw==\nTEL:123', "base64")
        self.assertEqual(contact["name"], "Zoë")
        contact = bridge.parse_vcard(
            "FN;CHARSET=ISO-8859-1;ENCODING=QUOTED-PRINTABLE:Andr=E9\nTEL:123", "latin"
        )
        self.assertEqual(contact["name"], "André")
        contact = bridge.parse_vcard(
            b"FN;CHARSET=ISO-8859-1:Andr\xe9\nTEL:123".decode("utf-8", errors="surrogateescape"),
            "raw",
        )
        self.assertEqual(contact["name"], "André")
        self.assertIsNotNone(bridge.parse_vcard("FN;ENCODING=B:invalid!\nTEL:123", "bad"))

    def test_embedded_photo_formats_and_limits(self):
        # A tiny synthetic PNG; never use a real contact photo in test fixtures.
        encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII="
        raw = base64.b64decode(encoded)
        card = "FN:Alex\nTEL:123\nPHOTO;ENCODING=BASE64;PNG:" + encoded[:40] + "\n " + encoded[40:]
        self.assertEqual(bridge.parse_vcard(card, "photo")["photo"], raw)
        self.assertEqual(bridge.photo_bytes("PHOTO", "data:image/png;base64," + encoded), raw)
        for value in (
            "https://example.invalid/photo.jpg",
            "file:///etc/passwd",
            "data:image/svg+xml;base64,PHN2Zy8+",
        ):
            self.assertIsNone(bridge.photo_bytes("PHOTO", value))
        self.assertIsNone(bridge.photo_bytes("PHOTO;ENCODING=B", "invalid!"))
        self.assertIsNone(
            bridge.photo_bytes("PHOTO;ENCODING=B", "A" * (bridge.MAX_PHOTO_BYTES * 2))
        )

    def test_private_session_photo_cache_refresh_and_fallback(self):
        raw = b"\xff\xd8\xff" + b"synthetic jpeg content"
        with tempfile.TemporaryDirectory() as data, tempfile.TemporaryDirectory() as runtime:
            cache = Path(data) / "kpeoplevcard" / "kdeconnect-phone"
            cache.mkdir(parents=True)
            card = cache / "1.vcf"
            card.write_text(
                "FN:Alex\nTEL:123\nPHOTO;ENCODING=BASE64;JPEG:" + base64.b64encode(raw).decode()
            )
            contact = bridge.read_contacts("phone", data, runtime)[0]
            image = Path(contact["photo"])
            self.assertEqual(image.read_bytes(), raw)
            self.assertEqual(image.stat().st_mode & 0o777, 0o600)
            self.assertEqual(image.parent.stat().st_mode & 0o777, 0o700)
            self.assertNotIn("Alex", image.name)
            self.assertEqual(bridge.read_contacts("phone", data, runtime)[0]["photo"], str(image))
            self.assertNotEqual(bridge.photo_directory("other", runtime), image.parent)
            with patch.dict(os.environ, {"XDG_RUNTIME_DIR": ""}):
                self.assertNotIn("photo", bridge.read_contacts("phone", data)[0])
            os.utime(image, (1, 1))
            card.write_text("FN:Alex\nTEL:123")
            self.assertNotIn("photo", bridge.read_contacts("phone", data, runtime)[0])
            self.assertFalse(image.exists(), "Removed photos must be cleaned up")

    def test_number_matching_does_not_guess_country(self):
        self.assertEqual(bridge.normalize_number("+1 (555) 010-1000"), "+15550101000")
        self.assertNotEqual(bridge.normalize_number("5550101000"), "+15550101000")

    def fake_bridge(self):
        obj = bridge.Bridge.__new__(bridge.Bridge)
        obj.GLib = SimpleNamespace(Error=DBusError)
        obj.Gio = SimpleNamespace(
            dbus_error_quark=lambda: "g-dbus-error-quark",
            DBusError=SimpleNamespace(UNKNOWN_OBJECT="UnknownObject"),
        )
        obj.available = lambda device: True
        obj.calls = []

        def call(*args):
            obj.calls.append(args)
            if args[2] == "activeConversations":
                return Variant(([(1, "old", [("123",)], 1, 1, 1, 42, 3)],))

        obj.call = call
        return obj

    def test_pagination_and_existing_thread_reply(self):
        obj = self.fake_bridge()
        obj.request({"op": "history", "device": "phone", "thread": "42", "start": 50})
        self.assertEqual(obj.calls[-1][-1], (42, 50, 100))
        obj.request({"op": "sms_send", "device": "phone", "thread": "42", "text": "hello"})
        self.assertEqual(obj.calls[-1][2], "replyToConversation")
        self.assertEqual(obj.calls[-1][-1], (42, "hello", []))

    def test_connection_check_waits_for_signal_not_local_method_return(self):
        for responds in (True, False):
            with self.subTest(responds=responds):
                obj = self.fake_bridge()
                callbacks, order, cleanup = {}, [], []

                def subscribe(*args):
                    order.append("subscribe")
                    self.assertEqual(args[2], "propertiesChanged")
                    self.assertEqual(args[3], obj.path("phone") + "/mprisremote")
                    callbacks["signal"] = args[-1]
                    return 7

                def timer(seconds, callback):
                    self.assertEqual(seconds, 8)
                    callbacks["timeout"] = callback
                    return 8

                def call(path, interface, method):
                    order.append(method)
                    if method == "loadedPlugins":
                        return Variant((["kdeconnect_mprisremote"],))

                obj.call = call
                obj.bus = SimpleNamespace(
                    signal_subscribe=subscribe, signal_unsubscribe=cleanup.append
                )
                obj.Gio.DBusSignalFlags = SimpleNamespace(NONE=0)
                obj.GLib.timeout_add_seconds = timer
                obj.GLib.source_remove = cleanup.append
                obj.loop = SimpleNamespace(
                    run=lambda: callbacks["signal" if responds else "timeout"](), quit=lambda: None
                )
                self.assertEqual(
                    obj.request({"op": "connection_check", "device": "phone"}),
                    [
                        {
                            "type": "health",
                            "device": "phone",
                            "supported": True,
                            "responding": responds,
                        }
                    ],
                )
                self.assertEqual(order, ["loadedPlugins", "subscribe", "requestPlayerList"])
                self.assertEqual(cleanup, [7, 8] if responds else [7])

    def test_connection_check_skips_disabled_media_plugin(self):
        obj = self.fake_bridge()
        obj.call = lambda *_: Variant(([],))
        self.assertEqual(
            obj.request({"op": "connection_check", "device": "phone"}),
            [{"type": "health", "device": "phone", "supported": False}],
        )

    def test_missing_conversation_cannot_silently_accept_reply(self):
        obj = self.fake_bridge()
        with self.assertRaisesRegex(ValueError, "no longer synced"):
            obj.request({"op": "sms_send", "device": "phone", "thread": "99", "text": "hi"})
        self.assertEqual([call[2] for call in obj.calls], ["activeConversations"])

    def test_offline_request_reports_connection_loss(self):
        output = io.StringIO()
        with (
            patch.object(bridge, "Bridge") as backend,
            patch("sys.argv", ["bridge.py", "request", '{"op":"sms_send","device":"phone"}']),
            patch("sys.stdout", output),
        ):
            backend.return_value.request.side_effect = bridge.PhoneUnavailable(
                "Phone is disconnected"
            )
            self.assertEqual(bridge.main(), 1)
        response = json.loads(output.getvalue())
        self.assertFalse(response["ok"])
        self.assertEqual(
            response["events"], [{"type": "connection", "device": "phone", "connected": False}]
        )

    def test_expired_notification_and_offline_actions(self):
        obj = self.fake_bridge()
        obj.notification = lambda *_: {"id": "1", "replyId": "new", "dismissable": False}
        with self.assertRaisesRegex(ValueError, "no longer"):
            obj.request(
                {
                    "op": "notification_reply",
                    "device": "phone",
                    "notification": "1",
                    "replyId": "old",
                    "text": "hi",
                }
            )
        with self.assertRaisesRegex(ValueError, "cannot be dismissed"):
            obj.request({"op": "notification_dismiss", "device": "phone", "notification": "1"})
        obj.available = lambda *_: False
        with self.assertRaisesRegex(ValueError, "disconnected"):
            obj.request({"op": "sms_send", "device": "phone", "text": "hi"})
        self.assertEqual(obj.calls, [])

    def test_notification_expires_before_posted_or_updated_signal_is_read(self):
        obj = self.fake_bridge()
        with (
            patch.object(obj, "properties", side_effect=DBusError()),
            patch.object(bridge, "emit") as emit,
        ):
            for signal in ("notificationPosted", "notificationUpdated"):
                with self.subTest(signal=signal):
                    obj.signal(
                        None,
                        None,
                        obj.path("phone") + "/notifications",
                        bridge.DEVICE + ".notifications",
                        signal,
                        Variant(("100",)),
                    )
                    emit.assert_called_with(
                        {"type": "notification_removed", "device": "phone", "id": "100"}
                    )
            self.assertEqual(emit.call_count, 2)
        self.assertEqual(obj.calls, [], "Expiration must not perform a phone action")

    def test_notification_signal_keeps_other_bus_failures_visible(self):
        obj = self.fake_bridge()
        with (
            patch.object(obj, "properties", side_effect=DBusError("AccessDenied")),
            patch.object(bridge, "emit") as emit,
        ):
            obj.signal(
                None,
                None,
                obj.path("phone") + "/notifications",
                bridge.DEVICE + ".notifications",
                "notificationPosted",
                Variant(("100",)),
            )
        self.assertEqual(emit.call_count, 1)
        self.assertEqual(emit.call_args.args[0]["type"], "error")
        self.assertEqual(emit.call_args.args[0]["device"], "phone")
        self.assertNotIn("g-dbus", emit.call_args.args[0]["message"])

    def test_notification_snapshot_skips_only_expired_objects(self):
        obj = self.fake_bridge()
        obj.interfaces = lambda _: set()
        obj.call = lambda path, interface, method: {
            "loadedPlugins": [["kdeconnect_notifications"]],
            "activeNotifications": [["100", "101"]],
        }[method]
        current = {"id": "101", "title": "Current notification"}
        with patch.object(obj, "notification", side_effect=[DBusError(), current]):
            events = obj.snapshot("phone")
        self.assertEqual(
            events[-1], {"type": "notifications", "device": "phone", "items": [current]}
        )
        with patch.object(obj, "notification", side_effect=DBusError("AccessDenied")):
            with self.assertRaises(DBusError):
                obj.snapshot("phone")

    def test_error_does_not_expose_message_arguments(self):
        error = Exception("GDBus call failed sending private message text")
        self.assertNotIn("private", bridge.safe_error(error))
        self.assertIn("unknown", bridge.safe_error(Exception("operation timed out")))

    def test_glib_runtime_errors_are_sanitized(self):
        self.assertEqual(
            bridge.safe_error(DBusError()),
            "KDE Connect feature or notification is no longer available",
        )
        self.assertNotIn("/modules/", bridge.safe_error(DBusError("AccessDenied")))
        self.assertNotIn("private", bridge.safe_error(RuntimeError("private backend details")))


if __name__ == "__main__":
    unittest.main()
