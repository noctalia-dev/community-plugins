#!/usr/bin/env python3
"""KDE Connect D-Bus adapter. JSON on stdout; no persistent message archive.

watch subscribes before taking snapshots. request performs one explicit operation.
The Luau service owns the UI model. Watch mode emits framed JSON events;
request and check modes return one JSON object followed by process exit.
Embedded contact photos are decoded into a private, session-only runtime cache.
"""

import argparse
import base64
import binascii
import hashlib
import json
import os
import quopri
import re
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote

SERVICE = "org.kde.kdeconnect"
ROOT = "/modules/kdeconnect"
DEVICE = SERVICE + ".device"
PROPERTIES = "org.freedesktop.DBus.Properties"
PAGE_SIZE = 50
MAX_PHOTO_BYTES = 256 * 1024


def unpack(value):
    """Recursively unwrap variants, including variants inside message structs."""
    if hasattr(value, "unpack"):
        return unpack(value.unpack())
    if isinstance(value, dict):
        return {str(k): unpack(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [unpack(v) for v in value]
    return value


def normalize_number(number):
    """Normalize contact-cache numbers without guessing international prefixes."""
    number = unquote(str(number).removeprefix("tel:"))
    # Do not guess country codes or match ambiguous number suffixes.
    return re.sub(r"[\s().-]", "", number).casefold()


def decode_message(value):
    """Convert KDE Connect's 8-, 9- or 10-field message tuple to a named record.

    String IDs survive JSON transport without integer precision loss. Dates are
    milliseconds since the epoch. Outgoing includes sent, draft, outbox, failed
    and queued Android message types; it does not imply successful delivery.
    """
    record = unpack(value)
    if not isinstance(record, list) or len(record) not in (8, 9, 10):
        raise ValueError("Unsupported KDE Connect message format")
    event, body, addresses, date, kind, read, thread, message_id = record[:8]
    if not isinstance(body, str) or not isinstance(addresses, list):
        raise ValueError("Invalid KDE Connect message")
    numbers = []
    for address in addresses:
        if isinstance(address, list) and address and isinstance(address[0], str):
            numbers.append(address[0])
    return {
        "id": str(message_id),
        "thread": str(thread),
        "body": body,
        "addresses": numbers,
        "date": int(date),
        "type": int(kind),
        "read": bool(read),
        "outgoing": int(kind) in (2, 3, 4, 5, 6),
        "attachments": len(record[9]) if len(record) > 9 else 0,
        "subId": str(record[8]) if len(record) > 8 else "-1",
        "event": int(event),
    }


def vcard_text(value):
    """Unescape vCard text delimiters after transfer-encoding decoding."""
    return re.sub(r"\\([nN,;\\])", lambda m: "\n" if m[1].lower() == "n" else m[1], value)


def vcard_lines(text):
    """Unfold vCard lines, including v2.1 quoted-printable soft line breaks."""
    current = ""
    for line in text.splitlines():
        head = current.partition(":")[0].upper()
        quoted = "ENCODING=QUOTED-PRINTABLE" in head
        if current and quoted and current.endswith("="):
            current = current[:-1] + line.lstrip(" \t")
        elif current and line.startswith((" ", "\t")):
            current += line[1:]
        elif (
            current
            and re.search(r";ENCODING=(?:B|BASE64)(?:;|$)", head)
            and line
            and ":" not in line
        ):
            current += line.strip()
        else:
            if current:
                yield current
            current = line
    if current:
        yield current


def vcard_value(head, value):
    """Decode a property's transfer encoding and charset with a per-value fallback."""
    params = {}
    for param in head.split(";")[1:]:
        key, sep, item = param.partition("=")
        if sep:
            params[key.upper()] = item.strip('"')
    raw = value.encode("utf-8", errors="surrogateescape")
    encoding = params.get("ENCODING", "").upper()
    if encoding == "QUOTED-PRINTABLE":
        raw = quopri.decodestring(raw)
    elif encoding in ("B", "BASE64"):
        try:
            raw = base64.b64decode(re.sub(rb"\s", b"", raw), validate=True)
        except (ValueError, binascii.Error):
            return value  # A malformed contact must not discard the address book.
    try:
        return raw.decode(params.get("CHARSET", "utf-8"), errors="replace")
    except (LookupError, ValueError):
        return raw.decode("utf-8", errors="replace")


def photo_bytes(head, value):
    """Accept bounded embedded raster photos only; never fetch photo URIs."""
    if value.lower().startswith("data:image/"):
        meta, sep, value = value.partition(",")
        if not sep or not meta.lower().endswith(";base64"):
            return None
    elif not re.search(r";ENCODING=(?:B|BASE64)(?:;|$)", head, re.I):
        return None
    if len(value) > (MAX_PHOTO_BYTES * 4 // 3) + 16:
        return None
    try:
        raw = base64.b64decode(re.sub(r"\s", "", value), validate=True)
    except (ValueError, binascii.Error):
        return None
    if len(raw) > MAX_PHOTO_BYTES or not photo_extension(raw):
        return None
    return raw


def photo_extension(raw):
    """Return the supported raster extension from content, never a supplied path."""
    if raw.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if raw.startswith(b"RIFF") and raw[8:12] == b"WEBP":
        return ".webp"
    return None


def photo_directory(device, runtime_dir=None, create=True):
    """Find or create a private session cache for one device; return None on failure."""
    runtime = runtime_dir or os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        return None
    root = Path(runtime)
    try:
        if not root.is_dir() or root.stat().st_uid != os.getuid():
            return None
        directory = (
            root / "noctalia-phone-connect" / hashlib.sha256(device.encode()).hexdigest()[:24]
        )
        if not create and not directory.is_dir():
            return None
        for folder in (directory.parent, directory):
            folder.mkdir(mode=0o700, exist_ok=True)
            if folder.is_symlink() or folder.stat().st_uid != os.getuid():
                return None
            folder.chmod(0o700)
        return directory
    except OSError:
        return None


def cache_photo(directory, raw):
    """Atomically store a photo by content hash and return its local image path."""
    if directory is None:
        return None
    path = directory / (hashlib.sha256(raw).hexdigest() + photo_extension(raw))
    temporary = None
    try:
        if path.is_file() and not path.is_symlink() and path.read_bytes() == raw:
            return str(path)
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".photo-", delete=False) as output:
            temporary = Path(output.name)
            output.write(raw)  # NamedTemporaryFile uses mode 0600; replace is atomic.
        temporary.replace(path)
        return str(path)
    except OSError:
        return None
    finally:
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass


def parse_vcard(text, identifier):
    """Return one contact with distinct phone numbers, or None if it has no number.

    Embedded photo bytes are temporary parser output. read_contacts replaces
    them with a native-readable cache path before emitting the contact.
    """
    name, fallback, numbers, photo = "", "", [], None
    for line in vcard_lines(text):
        head, sep, value = line.partition(":")
        if not sep:
            continue
        field = head.split(";", 1)[0].split(".")[-1].upper()
        if field == "PHOTO":
            photo = photo_bytes(head, value) or photo
            continue
        if field not in ("FN", "N", "TEL"):
            continue
        value = vcard_value(head, value)
        if field == "FN":
            name = vcard_text(value)
        elif field == "N":
            fallback = " ".join(vcard_text(v) for v in value.split(";") if v)
        elif field == "TEL":
            number = unquote(value.removeprefix("tel:"))
            if number and normalize_number(number) not in {normalize_number(n) for n in numbers}:
                numbers.append(number)
    if not numbers:
        return None
    name = name or fallback or numbers[0]
    contact = {
        "id": identifier,
        "name": name,
        "numbers": numbers,
        "search": (
            name + " " + " ".join(numbers) + " " + " ".join(map(normalize_number, numbers))
        ).casefold(),
    }
    if photo:
        contact["photo"] = photo
    return contact


def read_contacts(device, data_home=None, runtime_dir=None):
    """Read KDE Connect's vCards and maintain only the derived runtime photo cache.

    Contact files are never modified. Cache/write failures degrade to initials;
    concurrent synchronization may replace a vCard between listing and reading.
    """
    base = Path(data_home or os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    directory = base / "kpeoplevcard" / ("kdeconnect-" + device)
    contacts = []
    photos = None
    retained = set()
    if directory.is_dir():
        for path in sorted(directory.iterdir()):
            if path.suffix not in (".vcf", ".vcard") or not path.is_file():
                continue
            try:
                contact = parse_vcard(
                    path.read_text(encoding="utf-8", errors="surrogateescape"), path.stem
                )
                if contact:
                    raw_photo = contact.pop("photo", None)
                    if raw_photo:
                        photos = photos or photo_directory(device, runtime_dir)
                        photo = cache_photo(photos, raw_photo)
                        if photo:
                            contact["photo"] = photo
                            retained.add(Path(photo).name)
                    contacts.append(contact)
            except OSError:
                continue  # A concurrent contact sync may replace a file.
    # Drop replaced/removed photos after a short grace period for open panels and
    # concurrent readers. The runtime directory is also removed at logout.
    photos = photos or photo_directory(device, runtime_dir, create=False)
    if photos:
        try:
            cached = list(photos.iterdir())
        except OSError:
            cached = []
        for path in cached:
            try:
                if (
                    re.fullmatch(r"[0-9a-f]{64}\.(jpg|png|webp)", path.name)
                    and path.name not in retained
                    and path.stat().st_mtime < time.time() - 60
                ):
                    path.unlink()
            except OSError:
                pass
    return sorted(contacts, key=lambda c: (c["name"].casefold(), c["id"]))


def stream_lines(event):
    """Yield bounded JSON lines for watch mode, framing oversized snapshots."""
    encoded = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) <= 48 * 1024:
        yield encoded
        return
    # Noctalia drops unfinished stream lines over 64 KiB. Large conversation
    # and contact snapshots need framing; ASCII fragments cannot split UTF-8.
    encoded = json.dumps(event, ensure_ascii=True, separators=(",", ":"))
    size = 16 * 1024
    count = (len(encoded) + size - 1) // size
    for index in range(count):
        yield json.dumps(
            {
                "type": "chunk",
                "index": index + 1,
                "count": count,
                "data": encoded[index * size : (index + 1) * size],
            },
            separators=(",", ":"),
        )


def emit(event):
    """Write a watch event, flushing each line for the long-running subscriber."""
    for line in stream_lines(event):
        print(line, flush=True)


def write_response(response):
    """Write one complete JSON result for runAsync, which decodes stdout once."""
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


class Bridge:
    """Translate session D-Bus calls and signals into the Luau service protocol.

    Calls are synchronous inside this separate process, with a 10-second D-Bus
    timeout. The class owns subscriptions, but never stores conversation history.
    """

    def __init__(self):
        try:
            from gi.repository import Gio, GLib
        except ImportError as exc:
            raise RuntimeError(
                "Install Python 3 and PyGObject (python-gobject on Arch; python3-gi on Debian/Ubuntu)."
            ) from exc
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.loop = GLib.MainLoop()
        self.pending_snapshots = set()

    def call(self, path, interface, method, signature=None, args=()):
        """Invoke a method with an explicit GVariant argument signature."""
        params = self.GLib.Variant(signature, args) if signature else None
        return self.bus.call_sync(
            SERVICE, path, interface, method, params, None, self.Gio.DBusCallFlags.NONE, 10000, None
        )

    def properties(self, path, interface):
        return unpack(self.call(path, PROPERTIES, "GetAll", "(s)", (interface,)))[0]

    def path(self, device):
        if not re.fullmatch(r"[A-Za-z0-9_]+", device):
            raise ValueError("Invalid device ID")
        return ROOT + "/devices/" + device

    def interfaces(self, path):
        xml = unpack(self.call(path, "org.freedesktop.DBus.Introspectable", "Introspect"))[0]
        return {n.attrib["name"] for n in ET.fromstring(xml).findall("interface")}

    def available(self, device):
        properties = self.properties(self.path(device), DEVICE)
        return bool(properties.get("isPaired") and properties.get("isReachable"))

    def notification(self, device, public_id):
        """Read current notification actions; callers must tolerate expiration."""
        if not re.fullmatch(r"[A-Za-z0-9_]+", public_id):
            raise ValueError("Invalid notification ID")
        path = self.path(device) + "/notifications/" + public_id
        properties = self.properties(path, DEVICE + ".notifications.notification")
        return {
            "id": public_id,
            "app": properties.get("appName", ""),
            "title": properties.get("title", ""),
            "text": properties.get("text", ""),
            "replyId": properties.get("replyId", ""),
            "dismissable": properties.get("dismissable", False),
            "icon": properties.get("iconPath", ""),
        }

    def snapshot(self, device):
        """Read capabilities and current caches without fetching full SMS histories."""
        path = self.path(device)
        if not self.available(device):
            return [{"type": "connection", "device": device, "connected": False}]
        interfaces = self.interfaces(path)
        loaded = unpack(self.call(path, DEVICE, "loadedPlugins"))[0]
        capabilities = {
            "messages": DEVICE + ".conversations" in interfaces,
            "contacts": "kdeconnect_contacts" in loaded,
            "notifications": "kdeconnect_notifications" in loaded,
            "calls": "kdeconnect_telephony" in loaded,
        }
        events = [
            {
                "type": "capabilities",
                "device": device,
                "capabilities": capabilities,
                "connected": True,
            }
        ]
        if capabilities["contacts"]:
            events.append({"type": "contacts", "device": device, "items": read_contacts(device)})
        if capabilities["messages"]:
            records = unpack(self.call(path, DEVICE + ".conversations", "activeConversations"))[0]
            events.append(
                {"type": "threads", "device": device, "items": [decode_message(m) for m in records]}
            )
        if capabilities["notifications"]:
            ids = unpack(
                self.call(path + "/notifications", DEVICE + ".notifications", "activeNotifications")
            )[0]
            items = []
            for public_id in ids:
                try:
                    items.append(self.notification(device, public_id))
                except self.GLib.Error:
                    pass  # Dismissed between listing and reading.
            events.append({"type": "notifications", "device": device, "items": items})
        return events

    def request(self, command):
        """Perform one validated operation and return immediate snapshot events.

        History contents arrive through the watch subscription. A successful
        send means the D-Bus method accepted the request, not that it was delivered.
        """
        device, operation = command.get("device", ""), command.get("op")
        path = self.path(device)
        if not self.available(device):
            raise ValueError("Phone is disconnected or unpaired")
        conversation_interface = DEVICE + ".conversations"
        if operation == "sync":
            events = self.snapshot(device)
            capabilities = events[0].get("capabilities", {})
            if capabilities.get("messages"):
                self.call(path, conversation_interface, "requestAllConversationThreads")
            return events
        if operation == "contacts_sync":
            self.call(path + "/contacts", DEVICE + ".contacts", "synchronizeRemoteWithLocal")
        elif operation == "history":
            start = max(0, int(command.get("start", 0)))
            self.call(
                path,
                conversation_interface,
                "requestConversation",
                "(xii)",
                (int(command["thread"]), start, start + PAGE_SIZE),
            )
        elif operation in ("sms_send", "notification_reply"):
            text = command.get("text", "")
            if not isinstance(text, str) or not text.strip():
                raise ValueError("Message is empty")
            if operation == "notification_reply":
                notification = self.notification(device, command["notification"])
                if not notification["replyId"] or notification["replyId"] != command.get("replyId"):
                    raise ValueError("Notification reply is no longer available")
                self.call(
                    path + "/notifications",
                    DEVICE + ".notifications",
                    "sendReply",
                    "(ss)",
                    (notification["replyId"], text),
                )
            else:
                attachments = (
                    [self.GLib.Variant("s", command["attachment"])]
                    if command.get("attachment")
                    else []
                )
                if command.get("thread"):
                    self.call(
                        path,
                        conversation_interface,
                        "replyToConversation",
                        "(xsav)",
                        (int(command["thread"]), text, attachments),
                    )
                else:
                    number = command.get("destination", "").strip()
                    if not number:
                        raise ValueError("Choose a recipient")
                    self.call(
                        path,
                        conversation_interface,
                        "sendWithoutConversation",
                        "(avsav)",
                        ([self.GLib.Variant("(s)", (number,))], text, attachments),
                    )
        elif operation == "notification_dismiss":
            notification = self.notification(device, command["notification"])
            if not notification["dismissable"]:
                raise ValueError("Notification cannot be dismissed")
            self.call(
                path + "/notifications/" + notification["id"],
                DEVICE + ".notifications.notification",
                "dismiss",
            )
        else:
            raise ValueError("Unsupported operation")
        return []

    def snapshot_later(self, device):
        """Coalesce device/plugin-change signals into one delayed snapshot."""
        if device in self.pending_snapshots:
            return
        self.pending_snapshots.add(device)

        def refresh():
            self.pending_snapshots.discard(device)
            try:
                for event in self.snapshot(device):
                    emit(event)
            except (self.GLib.Error, ValueError) as exc:
                emit({"type": "error", "device": device, "message": safe_error(exc)})
            return False

        self.GLib.timeout_add(250, refresh)

    def signal(self, _bus, _sender, path, interface, signal, params, _data=None):
        """Map subscribed KDE Connect signals to typed, device-scoped events."""
        try:
            values = unpack(params)
            if path == ROOT:
                if signal in ("deviceAdded", "deviceVisibilityChanged") and values:
                    self.snapshot_later(values[0])
                elif signal == "deviceRemoved" and values:
                    emit({"type": "removed", "device": values[0]})
                return
            match = re.match(re.escape(ROOT) + r"/devices/([A-Za-z0-9_]+)(?:/|$)", path)
            if not match:
                return
            device = match[1]
            event = {"device": device}
            if interface == DEVICE + ".conversations":
                if signal in ("conversationCreated", "conversationUpdated"):
                    event.update(type="message", message=decode_message(values[0]))
                elif signal == "conversationRemoved":
                    event.update(type="thread_removed", thread=str(values[0]))
                elif signal == "conversationLoaded":
                    event.update(type="loaded", thread=str(values[0]), count=int(values[1]))
                else:
                    return
            elif interface == DEVICE + ".notifications":
                if signal in ("notificationPosted", "notificationUpdated"):
                    event.update(
                        type="notification", notification=self.notification(device, values[0])
                    )
                elif signal == "notificationRemoved":
                    event.update(type="notification_removed", id=values[0])
                elif signal == "allNotificationsRemoved":
                    event.update(type="notifications", items=[])
                else:
                    return
            elif interface == DEVICE + ".contacts" and signal == "localCacheSynchronized":
                event.update(type="contacts", items=read_contacts(device))
            elif interface == DEVICE + ".telephony" and signal == "callReceived":
                event.update(
                    type="call",
                    call={
                        "event": values[0],
                        "number": values[1],
                        "name": values[2],
                        "date": int(time.time()),
                    },
                )
            elif interface == DEVICE and signal in (
                "reachableChanged",
                "pairStateChanged",
                "pluginsChanged",
            ):
                self.snapshot_later(device)
                return
            else:
                return
            emit(event)
        except (self.GLib.Error, ValueError, IndexError, TypeError) as exc:
            emit({"type": "error", "message": safe_error(exc)})

    def initial(self):
        """Queue paired-device snapshots and release deferred service requests."""
        try:
            devices = unpack(
                self.call(ROOT, SERVICE + ".daemon", "devices", "(bb)", (False, True))
            )[0]
            for device in devices:
                self.snapshot_later(device)
            emit({"type": "ready"})
        except self.GLib.Error as exc:
            emit({"type": "error", "message": safe_error(exc)})

    def owner_changed(self, _bus, _sender, _path, _interface, _signal, params, _data=None):
        """Invalidate outstanding requests when the daemon's bus owner changes."""
        _name, _old, new = unpack(params)
        emit({"type": "reset"})
        if new:
            self.initial()

    def watch(self):
        """Subscribe before snapshots and announce readiness before any history load."""
        self.bus.signal_subscribe(
            SERVICE, None, None, None, None, self.Gio.DBusSignalFlags.NONE, self.signal
        )
        self.bus.signal_subscribe(
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            "/org/freedesktop/DBus",
            SERVICE,
            self.Gio.DBusSignalFlags.NONE,
            self.owner_changed,
        )
        self.initial()

        def heartbeat():
            emit({"type": "heartbeat"})
            return True

        self.GLib.timeout_add_seconds(10, heartbeat)
        self.loop.run()


def safe_error(exc):
    """Map backend errors to UI text without including message bodies or arguments."""
    if isinstance(exc, (ValueError, RuntimeError)):
        return str(exc)
    text = str(exc)
    if "UnknownObject" in text or "UnknownMethod" in text:
        return "KDE Connect feature or notification is no longer available"
    if "ServiceUnknown" in text or "NameHasNoOwner" in text:
        return "KDE Connect is not running"
    if "Timeout" in text or "timed out" in text:
        return (
            "KDE Connect did not respond; the outcome is unknown. Check the phone before retrying."
        )
    return "KDE Connect request failed; check the connection and phone permissions"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("watch", "request", "check"))
    parser.add_argument("command", nargs="?")
    args = parser.parse_args()
    try:
        bridge = Bridge()
        if args.mode == "watch":
            bridge.watch()
        elif args.mode == "request":
            write_response({"ok": True, "events": bridge.request(json.loads(args.command or "{}"))})
        else:
            write_response({"ok": True})
        return 0
    except Exception as exc:
        response = {"type": "error", "ok": False, "message": safe_error(exc)}
        if args.mode == "watch":
            emit(response)
        else:
            write_response(response)
        return 1


if __name__ == "__main__":
    sys.exit(main())
