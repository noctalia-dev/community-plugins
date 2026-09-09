#!/usr/bin/env python3
"""NetworkManager secret agent backed by KWallet.

Registers on the system bus as a NetworkManager secret agent and answers
GetSecrets out of KWallet's legacy store (org.kde.KWallet on kwalletd6,
folder "Network Management") -- the same folder plasma-nm writes to, keyed
"{uuid};<setting-name>".

Why this exists: on a niri/Noctalia session the shell's own secret agent has
no persistent store, so every agent-owned profile (psk-flags=1) pops a
password prompt. Registering this agent alongside it makes those profiles
connect from the wallet instead, without needing kded6/plasma-nm alive.

Secret VALUES are never logged -- only ssid/uuid/setting names and hit/miss.
"""

import argparse
import logging
import os
import signal
import socket
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

try:  # GLib.unix_signal_add is deprecated in newer PyGObject
    from gi.repository import GLibUnix

    unix_signal_add = GLibUnix.signal_add
except ImportError:
    unix_signal_add = GLib.unix_signal_add

# ---------------------------------------------------------------------------
# Configuration constants (overridable on the command line, see parse_args)
# ---------------------------------------------------------------------------

NM_SERVICE = "org.freedesktop.NetworkManager"                   # NM bus name (system bus)
NM_AGENT_MANAGER_PATH = "/org/freedesktop/NetworkManager/AgentManager"
NM_AGENT_MANAGER_IFACE = "org.freedesktop.NetworkManager.AgentManager"
NM_SECRET_AGENT_PATH = "/org/freedesktop/NetworkManager/SecretAgent"  # path NM calls back on
NM_SECRET_AGENT_IFACE = "org.freedesktop.NetworkManager.SecretAgent"

KWALLET_SERVICE = "org.kde.kwalletd6"                           # legacy KWallet daemon
KWALLET_PATH = "/modules/kwalletd6"
KWALLET_IFACE = "org.kde.KWallet"

# NMSecretAgentGetSecretsFlags
FLAG_ALLOW_INTERACTION = 0x1
FLAG_REQUEST_NEW = 0x2

# Secret keys we are willing to store per setting, mirroring plasma-nm.
SECRET_KEYS = {
    "802-11-wireless-security": (
        "psk",
        "wep-key0",
        "wep-key1",
        "wep-key2",
        "wep-key3",
        "leap-password",
    ),
    "802-1x": (
        "password",
        "pin",
        "private-key-password",
        "phase2-private-key-password",
    ),
}

log = logging.getLogger("kwallet-nm-agent")


class NoSecretsError(dbus.DBusException):
    """Tells NM "not mine" so it moves on to the next registered agent."""

    _dbus_error_name = "org.freedesktop.NetworkManager.SecretManager.NoSecrets"


# ---------------------------------------------------------------------------
# QDataStream <QMap<QString, QString>> codec
#
# KWallet map entries are a raw QDataStream dump: quint32 pair count, then
# key/value QStrings, each a quint32 byte length (0xFFFFFFFF == null) followed
# by UTF-16 big-endian data. Stable across Qt 5/6.
# ---------------------------------------------------------------------------


def decode_qmap(blob):
    buf = bytes(bytearray(blob))
    off = 0

    def u32():
        nonlocal off
        if off + 4 > len(buf):
            raise ValueError("truncated map")
        val = int.from_bytes(buf[off:off + 4], "big")
        off += 4
        return val

    def qstring():
        nonlocal off
        size = u32()
        if size == 0xFFFFFFFF:
            return None
        if off + size > len(buf):
            raise ValueError("truncated string")
        text = buf[off:off + size].decode("utf-16-be")
        off += size
        return text

    out = {}
    for _ in range(u32()):
        key = qstring()
        out[key] = qstring()
    return out


def encode_qmap(mapping):
    out = bytearray(len(mapping).to_bytes(4, "big"))
    for key, value in mapping.items():
        for text in (key, value):
            if text is None:
                out += b"\xff\xff\xff\xff"
            else:
                raw = text.encode("utf-16-be")
                out += len(raw).to_bytes(4, "big") + raw
    return dbus.ByteArray(bytes(out))


# ---------------------------------------------------------------------------
# KWallet
# ---------------------------------------------------------------------------


class Wallet:
    """Thin wrapper over the legacy KWallet D-Bus API.

    Every call is time-boxed: kwalletd6 has been seen to deadlock, and a stuck
    wallet must degrade to "no secrets" rather than wedge the agent.
    """

    def __init__(self, bus, wallet_name, folder, app_id, allow_prompt, timeout):
        self._bus = bus
        self._wallet_name = wallet_name
        self._folder = folder
        self._app_id = app_id
        self._allow_prompt = allow_prompt
        self._timeout = timeout
        self._handle = None

    def _iface(self):
        obj = self._bus.get_object(KWALLET_SERVICE, KWALLET_PATH, introspect=False)
        return dbus.Interface(obj, KWALLET_IFACE)

    def name(self):
        if self._wallet_name:
            return self._wallet_name
        self._wallet_name = str(self._iface().networkWallet(timeout=self._timeout))
        return self._wallet_name

    def _open(self):
        """Return a wallet handle, reusing the cached one while it stays valid."""
        api = self._iface()
        name = self.name()
        if self._handle is not None:
            try:
                if bool(api.isOpen(name, timeout=self._timeout)):
                    return self._handle
            except dbus.DBusException:
                pass
            self._handle = None

        if not self._allow_prompt and not bool(api.isOpen(name, timeout=self._timeout)):
            raise RuntimeError("wallet %r is locked and prompting is disabled" % name)

        handle = int(api.open(name, dbus.Int64(0), self._app_id, timeout=self._timeout))
        if handle <= 0:
            raise RuntimeError("could not open wallet %r (handle %d)" % (name, handle))
        self._handle = handle
        return handle

    def read_map(self, key):
        api = self._iface()
        handle = self._open()
        if not bool(api.hasEntry(handle, self._folder, key, self._app_id, timeout=self._timeout)):
            return None
        blob = api.readMap(handle, self._folder, key, self._app_id, timeout=self._timeout)
        if not blob:
            return None
        return decode_qmap(blob)

    def write_map(self, key, mapping):
        api = self._iface()
        handle = self._open()
        if not bool(api.hasFolder(handle, self._folder, self._app_id, timeout=self._timeout)):
            api.createFolder(handle, self._folder, self._app_id, timeout=self._timeout)
        rc = int(api.writeMap(handle, self._folder, key, encode_qmap(mapping),
                              self._app_id, timeout=self._timeout))
        if rc != 0:
            raise RuntimeError("writeMap returned %d" % rc)

    def remove(self, key):
        api = self._iface()
        handle = self._open()
        if bool(api.hasEntry(handle, self._folder, key, self._app_id, timeout=self._timeout)):
            api.removeEntry(handle, self._folder, key, self._app_id, timeout=self._timeout)

    def entries(self):
        api = self._iface()
        handle = self._open()
        if not bool(api.hasFolder(handle, self._folder, self._app_id, timeout=self._timeout)):
            return []
        return [str(e) for e in api.entryList(handle, self._folder, self._app_id,
                                              timeout=self._timeout)]


# ---------------------------------------------------------------------------
# The agent
# ---------------------------------------------------------------------------


def entry_key(uuid, setting_name):
    """plasma-nm's key layout: the braced UUID, a semicolon, the setting name."""
    return "{%s};%s" % (uuid, setting_name)


def connection_ids(connection):
    """Pull (uuid, human-readable id) out of an NM connection dict."""
    base = connection.get("connection", {})
    return str(base.get("uuid", "")), str(base.get("id", "?"))


class KWalletSecretAgent(dbus.service.Object):
    def __init__(self, system_bus, wallet, settings):
        super().__init__(system_bus, NM_SECRET_AGENT_PATH)
        self._wallet = wallet
        self._settings = settings

    # -- NM -> us ----------------------------------------------------------

    @dbus.service.method(NM_SECRET_AGENT_IFACE,
                         in_signature="a{sa{sv}}osasu", out_signature="a{sa{sv}}")
    def GetSecrets(self, connection, connection_path, setting_name, hints, flags):
        setting_name = str(setting_name)
        uuid, name = connection_ids(connection)

        if setting_name not in self._settings:
            log.debug("skip %s (%s): setting %s not handled", name, uuid, setting_name)
            raise NoSecretsError("setting not handled")

        # REQUEST_NEW means the stored secret was rejected; handing the same
        # one back would just loop. Let an interactive agent prompt instead.
        if flags & FLAG_REQUEST_NEW:
            log.info("skip %s (%s): NM asked for a new secret", name, uuid)
            raise NoSecretsError("stored secret was rejected")

        try:
            stored = self._wallet.read_map(entry_key(uuid, setting_name))
        except (dbus.DBusException, RuntimeError, ValueError) as exc:
            log.warning("wallet lookup failed for %s (%s): %s", name, uuid, exc)
            raise NoSecretsError("wallet unavailable")

        secrets = {k: v for k, v in (stored or {}).items() if k and v}
        if not secrets:
            log.info("miss %s (%s) %s", name, uuid, setting_name)
            raise NoSecretsError("no wallet entry")

        log.info("hit %s (%s) %s -> %d key(s) [%s]",
                 name, uuid, setting_name, len(secrets), ", ".join(sorted(secrets)))
        return dbus.Dictionary(
            {setting_name: dbus.Dictionary(
                {k: dbus.String(v) for k, v in secrets.items()}, signature="sv")},
            signature="sa{sv}")

    @dbus.service.method(NM_SECRET_AGENT_IFACE, in_signature="os", out_signature="")
    def CancelGetSecrets(self, connection_path, setting_name):
        # Lookups are short and time-boxed, so there is nothing to cancel.
        log.debug("cancel %s %s", connection_path, setting_name)

    @dbus.service.method(NM_SECRET_AGENT_IFACE, in_signature="a{sa{sv}}o", out_signature="")
    def SaveSecrets(self, connection, connection_path):
        uuid, name = connection_ids(connection)
        for setting_name in self._settings:
            wanted = SECRET_KEYS.get(setting_name, ())
            setting = connection.get(setting_name, {})
            secrets = {}
            for key in wanted:
                value = setting.get(key)
                if value is not None and str(value):
                    secrets[key] = str(value)
            if not secrets:
                continue
            try:
                self._wallet.write_map(entry_key(uuid, setting_name), secrets)
                log.info("saved %s (%s) %s -> %d key(s) [%s]",
                         name, uuid, setting_name, len(secrets), ", ".join(sorted(secrets)))
            except (dbus.DBusException, RuntimeError) as exc:
                log.warning("could not save %s (%s) %s: %s", name, uuid, setting_name, exc)

    @dbus.service.method(NM_SECRET_AGENT_IFACE, in_signature="a{sa{sv}}o", out_signature="")
    def DeleteSecrets(self, connection, connection_path):
        uuid, name = connection_ids(connection)
        for setting_name in self._settings:
            try:
                self._wallet.remove(entry_key(uuid, setting_name))
            except (dbus.DBusException, RuntimeError) as exc:
                log.warning("could not delete %s (%s) %s: %s", name, uuid, setting_name, exc)
                continue
            log.info("deleted %s (%s) %s", name, uuid, setting_name)


class Registration:
    """Keeps the agent registered, re-registering whenever NM comes back."""

    def __init__(self, system_bus, identifier):
        self._bus = system_bus
        self._identifier = identifier
        self._registered = False
        self._bus.watch_name_owner(NM_SERVICE, self._owner_changed)

    def _manager(self):
        obj = self._bus.get_object(NM_SERVICE, NM_AGENT_MANAGER_PATH, introspect=False)
        return dbus.Interface(obj, NM_AGENT_MANAGER_IFACE)

    def _owner_changed(self, owner):
        # Fires once on startup with the current owner, then on every NM restart.
        if not owner:
            log.warning("NetworkManager went away; will re-register when it returns")
            self._registered = False
            return
        if not self._registered:
            self.register()

    def register(self):
        try:
            self._manager().Register(self._identifier, timeout=20)
        except dbus.DBusException as exc:
            log.error("agent registration failed: %s", exc.get_dbus_message())
            self._registered = False
            GLib.timeout_add_seconds(5, self._retry)
            return
        self._registered = True
        log.info("registered with NetworkManager as %s", self._identifier)

    def _retry(self):
        if not self._registered:
            self.register()
        return False

    def unregister(self):
        if not self._registered:
            return
        try:
            self._manager().Unregister(timeout=5)
        except dbus.DBusException:
            pass
        self._registered = False


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------


def claim_single_instance(uid):
    """Abstract-socket lock: a second copy exits quietly instead of racing."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind("\0noctalia-kwallet-nm-agent-%d" % uid)
    except OSError:
        return None
    return sock


def run_check(wallet, settings):
    """Print which wallet entries exist. Never prints a secret value."""
    print("wallet : %s" % wallet.name())
    try:
        entries = wallet.entries()
    except (dbus.DBusException, RuntimeError) as exc:
        print("error  : %s" % exc)
        return 1
    print("entries: %d" % len(entries))
    for entry in sorted(entries):
        _, _, setting = entry.partition(";")
        if setting in settings:
            try:
                keys = sorted((wallet.read_map(entry) or {}).keys())
            except (dbus.DBusException, RuntimeError, ValueError) as exc:
                keys = ["<unreadable: %s>" % exc]
            print("  %-58s %s" % (entry, ", ".join(keys)))
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wallet", default="",
                        help="wallet name (default: KWallet's configured network wallet)")
    parser.add_argument("--folder", default="Network Management",
                        help="wallet folder holding the entries")
    parser.add_argument("--app-id", default="Noctalia KWallet Secrets",
                        help="application id shown in KWallet access dialogs")
    parser.add_argument("--identifier", default="io.github.grassyloki.kwalletSecrets",
                        help="identifier registered with NetworkManager")
    parser.add_argument("--with-8021x", action="store_true",
                        help="also answer 802-1x (enterprise) secret requests")
    parser.add_argument("--no-unlock-prompt", action="store_true",
                        help="never let KWallet prompt; treat a locked wallet as a miss")
    parser.add_argument("--timeout", type=float, default=15.0,
                        help="per-call KWallet D-Bus timeout in seconds")
    parser.add_argument("--debug", action="store_true", help="verbose logging")
    parser.add_argument("--check", action="store_true",
                        help="list wallet entries and exit (no secret values printed)")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(levelname)s %(message)s",
        stream=sys.stderr,
    )

    settings = ["802-11-wireless-security"]
    if args.with_8021x:
        settings.append("802-1x")

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    session_bus = dbus.SessionBus()
    wallet = Wallet(session_bus, args.wallet, args.folder, args.app_id,
                    not args.no_unlock_prompt, args.timeout)

    if args.check:
        return run_check(wallet, settings)

    lock = claim_single_instance(os.getuid())
    if lock is None:
        log.info("another agent instance is already running; exiting")
        return 0

    system_bus = dbus.SystemBus()
    KWalletSecretAgent(system_bus, wallet, settings)
    # Registration watches NM's bus name and registers as soon as it is there.
    registration = Registration(system_bus, args.identifier)

    loop = GLib.MainLoop()

    def stop(*_):
        log.info("shutting down")
        registration.unregister()
        loop.quit()

    unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, stop)

    log.info("serving %s from wallet folder %r", ", ".join(settings), args.folder)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
