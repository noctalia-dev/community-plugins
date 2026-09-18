#!/usr/bin/env python3
"""NetworkManager secret agent backed by KWallet.

Registers on the system bus as a NetworkManager secret agent and answers
GetSecrets out of KWallet's legacy store (org.kde.KWallet on kwalletd6,
folder "Network Management") -- the same folder plasma-nm writes to, keyed
"{uuid};<setting-name>".

Why this exists: on a niri/Noctalia session the shell's own secret agent has
no persistent store, so every agent-owned profile (psk-flags=1) pops a
password prompt, and every VPN profile asks for its password on each connect.
Registering this agent alongside it makes those profiles connect from the
wallet instead, without needing kded6/plasma-nm alive.

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

# Secret keys we are willing to store per setting, mirroring plasma-nm. The
# "vpn" setting has no entry here on purpose: its key names come from whichever
# VPN plugin the profile uses (openvpn's password/cert-pass/http-proxy-password,
# vpnc's "Xauth password", openconnect's cookie, ...), so it is handled by
# passing through whatever the wallet or NM actually hands over.
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
    "wireguard": (
        "private-key",
    ),
}

VPN_SETTING = "vpn"                 # the setting whose secrets are nested, see below
VPN_SECRETS_KEY = "VpnSecrets"      # plasma-nm packs every VPN secret into this one map key
VPN_SECRETS_SEP = "%SEP%"           # ... as key/value tokens joined by this separator

WG_SETTING = "wireguard"            # NM-native WireGuard, not the vpn setting
WG_PEER_PREFIX = "peers."           # plasma-nm keys a peer secret
WG_PEER_SUFFIX = ".preshared-key"   # ... "peers.<public-key>.preshared-key"

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
# VpnSecrets codec
#
# Every other setting gets one wallet map key per secret. The vpn setting does
# not: NetworkManagerQt (VpnSetting::secretsToMap) flattens the whole secret map
# into a single "VpnSecrets" entry whose value is key/value tokens joined by
# "%SEP%". Verified against the live wallet and against the "%SEP%"/"VpnSecrets"
# literals in libKF6NetworkManagerQt.
# ---------------------------------------------------------------------------


def decode_vpn_secrets(stored):
    """Unpack a VpnSecrets blob into a plain key -> value mapping."""
    packed = (stored or {}).get(VPN_SECRETS_KEY)
    if not packed:
        return {}
    tokens = packed.split(VPN_SECRETS_SEP)
    # A trailing key with no value is dropped, exactly as NetworkManagerQt does.
    return {k: v for k, v in zip(tokens[0::2], tokens[1::2]) if k and v}


def encode_vpn_secrets(secrets):
    """Pack a key -> value mapping into the single-entry map plasma-nm reads."""
    tokens = []
    for key, value in secrets.items():
        tokens += [key, value]
    return {VPN_SECRETS_KEY: VPN_SECRETS_SEP.join(tokens)}


# ---------------------------------------------------------------------------
# WireGuard peers
#
# A wireguard wallet entry mixes the interface private key with one entry per
# peer, keyed "peers.<public-key>.preshared-key". A peer secret cannot go back
# to NM under that flat name -- NM answers "secret not found" -- it has to
# travel inside the setting's "peers" array, next to the public key that says
# which peer it belongs to.
# ---------------------------------------------------------------------------


def split_wireguard_secrets(stored):
    """Split a wireguard wallet entry into (interface secrets, peer -> psk)."""
    interface, peers = {}, {}
    for key, value in (stored or {}).items():
        if not key or not value:
            continue
        if key.startswith(WG_PEER_PREFIX) and key.endswith(WG_PEER_SUFFIX):
            peers[key[len(WG_PEER_PREFIX):-len(WG_PEER_SUFFIX)]] = value
        elif key in SECRET_KEYS[WG_SETTING]:
            interface[key] = value
    return interface, peers


def wireguard_peers_reply(connection, peer_secrets):
    """Build the peers array for a reply: one entry per peer NM told us about.

    NM merges these by public key, so a peer we have no secret for is listed
    with its public key alone and keeps whatever it already had.
    """
    peers = []
    for peer in connection.get(WG_SETTING, {}).get("peers", []):
        public_key = str(peer.get("public-key", ""))
        if not public_key:
            continue
        entry = {"public-key": dbus.String(public_key)}
        if public_key in peer_secrets:
            entry["preshared-key"] = dbus.String(peer_secrets[public_key])
        peers.append(dbus.Dictionary(entry, signature="sv"))
    return dbus.Array(peers, signature="a{sv}")


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

        peer_secrets = {}
        if setting_name == VPN_SETTING:
            secrets = decode_vpn_secrets(stored)
        elif setting_name == WG_SETTING:
            secrets, peer_secrets = split_wireguard_secrets(stored)
        else:
            secrets = {k: v for k, v in (stored or {}).items() if k and v}
        if not secrets and not peer_secrets:
            log.info("miss %s (%s) %s", name, uuid, setting_name)
            raise NoSecretsError("no wallet entry")

        # hints names the one secret NM is after, but VPN key names are
        # plugin-specific and a VPN plugin routinely needs a second secret
        # (openvpn: cert-pass alongside password) that the hint never mentions.
        # So hints are logged and everything found is returned, as plasma-nm does.
        if hints:
            log.debug("hints for %s (%s) %s: %s",
                      name, uuid, setting_name, ", ".join(str(h) for h in hints))

        names = sorted(secrets)
        if peer_secrets:
            names.append("%d peer preshared-key(s)" % len(peer_secrets))
        log.info("hit %s (%s) %s -> %d key(s) [%s]", name, uuid, setting_name,
                 len(secrets) + len(peer_secrets), ", ".join(names))
        if setting_name == VPN_SETTING:
            # NM's vpn setting keeps its secrets one level down, in an a{ss}
            # under "secrets" -- confirmed against libnm's own ONLY_SECRETS
            # serialisation, which emits {"vpn": {"secrets": <a{ss}>}}. Current
            # NM also folds flat top-level strings into the same place, but this
            # is the shape libnm and plasma-nm actually send.
            entries = dbus.Dictionary(
                {"secrets": dbus.Dictionary(
                    {k: dbus.String(v) for k, v in secrets.items()}, signature="ss")},
                signature="sv")
        else:
            entries = dbus.Dictionary(
                {k: dbus.String(v) for k, v in secrets.items()}, signature="sv")
            if peer_secrets:
                peers = wireguard_peers_reply(connection, peer_secrets)
                if peers:
                    entries["peers"] = peers
        return dbus.Dictionary({setting_name: entries}, signature="sa{sv}")

    @dbus.service.method(NM_SECRET_AGENT_IFACE, in_signature="os", out_signature="")
    def CancelGetSecrets(self, connection_path, setting_name):
        # Lookups are short and time-boxed, so there is nothing to cancel.
        log.debug("cancel %s %s", connection_path, setting_name)

    @dbus.service.method(NM_SECRET_AGENT_IFACE, in_signature="a{sa{sv}}o", out_signature="")
    def SaveSecrets(self, connection, connection_path):
        uuid, name = connection_ids(connection)
        for setting_name in self._settings:
            setting = connection.get(setting_name, {})
            if setting_name == VPN_SETTING:
                # The vpn setting splits into "data" and "secrets"; only the
                # latter holds passwords, and its key names belong to the VPN
                # plugin, so everything non-empty is kept rather than filtered.
                source = setting.get("secrets", {})
                wanted = list(source.keys())
            else:
                source = setting
                wanted = SECRET_KEYS.get(setting_name, ())
            secrets = {}
            for key in wanted:
                value = source.get(key)
                if value is not None and str(value):
                    secrets[str(key)] = str(value)
            if setting_name == WG_SETTING:
                # Peer preshared keys arrive inside the peers array; the wallet
                # keeps them one flat entry per peer, the way plasma-nm does.
                for peer in setting.get("peers", []):
                    public_key = str(peer.get("public-key", ""))
                    value = peer.get("preshared-key")
                    if public_key and value is not None and str(value):
                        secrets[WG_PEER_PREFIX + public_key + WG_PEER_SUFFIX] = str(value)
            if not secrets:
                continue
            try:
                self._wallet.write_map(
                    entry_key(uuid, setting_name),
                    encode_vpn_secrets(secrets) if setting_name == VPN_SETTING else secrets)
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
                stored = wallet.read_map(entry) or {}
                # Unpack the vpn blob so the real key names show, not "VpnSecrets".
                if setting == VPN_SETTING:
                    stored = decode_vpn_secrets(stored)
                keys = sorted(stored.keys())
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
    parser.add_argument("--with-vpn", action="store_true",
                        help="also answer vpn and wireguard secret requests")
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
    if args.with_vpn:
        # NM-native WireGuard rides along: it is a VPN to the user, plasma-nm
        # keys it "{uuid};wireguard", and its private key is agent-owned too.
        settings.extend((VPN_SETTING, WG_SETTING))

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
