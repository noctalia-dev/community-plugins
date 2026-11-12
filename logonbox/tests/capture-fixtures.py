#!/usr/bin/env python3
"""Capture LogonBox CLI output as scrubbed test fixtures.

  python3 -I logonbox/tests/capture-fixtures.py              # show only
  python3 -I logonbox/tests/capture-fixtures.py --connected  # also connect/disconnect connection 0
  python3 -I logonbox/tests/capture-fixtures.py --check-only # re-run the scrub assertion over fixtures/

Raw output goes to fixtures/private/ (git-ignored). Scrubbed output goes to fixtures/.
The scrubber learns the real e-mail, hostnames, IPs and owner from the raw `show`, maps
them to documentation values, and deletes both `Public Key` lines. It then fails if any
learned value or anything key-, address- or e-mail-shaped is left. With --connected the
script always ends with `disconnect 0`.
"""

import ipaddress
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
PRIVATE = os.path.join(FIXTURES, "private")

CLI = "logonbox-vpn-cli"
FAKE_EMAIL = "user@example.com"
FAKE_HOSTS = ["vpn.example.com", "vpn2.example.org", "vpn3.example.org", "vpn4.example.org"]
DOC_NETS = [ipaddress.ip_network(n) for n in (
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "10.99.0.0/24", "2001:db8::/32")]

BASE64_RUN = re.compile(r"[A-Za-z0-9+/=]{40,}")
V4_CAND = re.compile(r"(?<![\w.])\d{1,3}(?:\.\d{1,3}){3}(?![\w.]*\w)")
V6_CAND = re.compile(r"[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*")
DOMAIN_TOKEN = re.compile(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+\.[a-z]{2,}", re.I)

# Hostnames allowed to remain after scrubbing: the fake set. Domain-like tokens starting
# with one of the prefixes (Java package names, D-Bus names) are not hosts.
ALLOWED_HOSTS = {"example.com", "example.org", "vpn.example.com", "vpn2.example.org",
                 "vpn3.example.org", "vpn4.example.org"}
NON_HOST_PREFIXES = ("com.logonbox.", "org.freedesktop.", "java.", "javax.", "com.example.")


class ScrubError(Exception):
    pass


def run(argv, timeout):
    proc = subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
    return proc.stdout, proc.stderr, proc.returncode


def host_of(authority_host):
    host = authority_host
    if host.startswith("["):
        return host[1:].split("]")[0]
    return host.split(":")[0]


def addresses(text):
    """Every valid IPv4/IPv6 address in text, as strings (validated by ipaddress)."""
    found = []
    for match in V4_CAND.finditer(text):
        try:
            ipaddress.IPv4Address(match.group(0))
            found.append(match.group(0))
        except ValueError:
            pass
    for match in V6_CAND.finditer(text):
        token = match.group(0).strip(":") if match.group(0).count("::") == 0 else match.group(0)
        for cand in {match.group(0), token}:
            try:
                ipaddress.IPv6Address(cand)
                found.append(cand)
                break
            except ValueError:
                pass
    return found


class Scrubber:
    def __init__(self):
        self.users = []      # every Uri user part and Owner seen (decoded)
        self.hosts = []      # real hostnames, discovery order
        self.ips = {}        # real ip -> fake ip
        self.v6 = {}
        self.pools = {"address": 0, "dns": 0, "other": 0}

    def learn(self, raw_show):
        for line in raw_show.splitlines():
            key, _, value = line.strip().partition(":")
            value = value.strip()
            key = key.strip()
            if key == "Uri" and value:
                netloc = urllib.parse.urlsplit(value).netloc
                if "@" in netloc:
                    user, _, hostport = netloc.rpartition("@")
                    self._add_user(urllib.parse.unquote(user))
                else:
                    hostport = netloc
                self._add_host(host_of(hostport))
            elif key == "Endpoint" and value:
                self._add_host(host_of(value))
            elif key == "Owner" and value:
                self._add_user(value)
            kind = {"Address": "address", "DNS": "dns"}.get(key, "other")
            for addr in addresses(value if key else line):
                self._add_ip(addr, kind)

    def _add_user(self, user):
        if user and user not in self.users:
            self.users.append(user)
            if "@" in user:
                self._add_host(user.partition("@")[2])

    def _add_host(self, host):
        if not host or host in self.hosts or ":" in host or not DOMAIN_TOKEN.fullmatch(host):
            return
        self.hosts.append(host)

    def _add_ip(self, ip, kind):
        if ip in self.ips or ip in self.v6:
            return
        if ":" in ip:
            self.v6[ip] = "2001:db8::%x" % (len(self.v6) + 1)
            return
        self.pools[kind] += 1
        prefix = {"address": "10.99.0.", "dns": "198.51.100.", "other": "192.0.2."}[kind]
        self.ips[ip] = prefix + str(self.pools[kind] + 1)

    def email_domains(self):
        return {u.partition("@")[2] for u in self.users if "@" in u}

    def learned(self):
        values = []
        for user in self.users:
            values.extend([user, urllib.parse.quote(user, safe=""), user.partition("@")[0]])
        values.extend(self.hosts)
        values.extend(self.ips.keys())
        values.extend(self.v6.keys())
        return [v for v in values if v]

    def scrub(self, text):
        text = "".join(ln for ln in text.splitlines(True) if "Public Key" not in ln)
        pairs = []
        for user in self.users:
            if "@" in user:
                pairs.append((user, FAKE_EMAIL))
                pairs.append((urllib.parse.quote(user, safe=""), "user%40example.com"))
                pairs.append((user.partition("@")[0], "user"))
            else:
                pairs.append((user, "user"))
        domains = self.email_domains()
        servers = [h for h in self.hosts if h not in domains]
        for host in self.hosts:
            if host in domains:
                pairs.append((host, "example.com"))
        for index, host in enumerate(servers):
            pairs.append((host, FAKE_HOSTS[min(index, len(FAKE_HOSTS) - 1)]))
        pairs.extend(self.ips.items())
        pairs.extend(self.v6.items())
        for real, fake in sorted(pairs, key=lambda p: -len(p[0])):
            text = text.replace(real, fake)
        return text

    def assert_clean(self, name, text):
        for value in self.learned():
            if value in text:
                raise ScrubError("%s: a learned real value survived the scrub" % name)
        check_shape(name, text)


def check_shape(name, text):
    """Learning-independent checks: nothing real-looking may remain."""
    rest = text.replace("user%40example.com", "").replace(FAKE_EMAIL, "")
    rest = re.sub(r"@vpn\d?\.example\.(?:com|org)", "", rest)
    if "%40" in rest.lower():
        raise ScrubError("%s: an encoded '@' (%%40) other than the fake e-mail remains" % name)
    if "@" in rest:
        raise ScrubError("%s: stray '@' remains" % name)
    if BASE64_RUN.search(text):
        raise ScrubError("%s: base64-like run of 40+ characters remains" % name)
    if "Public Key" in text:
        raise ScrubError("%s: a Public Key line remains" % name)
    for addr in addresses(text):
        ip = ipaddress.ip_address(addr)
        if not any(ip.version == net.version and ip in net for net in DOC_NETS):
            raise ScrubError("%s: IP address outside the documentation ranges remains" % name)
    for match in DOMAIN_TOKEN.finditer(text):
        token = match.group(0).lower()
        if token in ALLOWED_HOSTS or token.startswith(NON_HOST_PREFIXES):
            continue
        raise ScrubError("%s: unexpected domain-like token remains" % name)


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


CAPTURED = [
    "show-disconnected.txt", "show-connected.txt", "connect-ok.txt", "disconnect-ok.txt",
    "disconnect-not-connected.txt", "monitor-connect.txt", "monitor-disconnect.txt",
]


def build_scrubber(raws):
    scrubber = Scrubber()
    for name in ("show-disconnected.txt", "show-connected.txt"):
        if name in raws:
            scrubber.learn(raws[name])
    return scrubber


def finish(raws):
    scrubber = build_scrubber(raws)
    if not scrubber.users and not scrubber.hosts:
        raise ScrubError("nothing learned from the raw show output")
    cleaned = {}
    for name, raw in raws.items():
        write(os.path.join(PRIVATE, name), raw)
        cleaned[name] = scrubber.scrub(raw)
        scrubber.assert_clean(name, cleaned[name])
    # Write scrubbed files only after every one passed: no partial set.
    for name, clean in cleaned.items():
        write(os.path.join(FIXTURES, name), clean)
        print("wrote fixtures/%s" % name)


def start_monitor():
    argv = ["gdbus", "monitor", "--system", "--dest", "com.logonbox.vpn"]
    if shutil.which("stdbuf"):
        argv = ["stdbuf", "-oL"] + argv
    return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def split_monitor(text):
    lines = text.splitlines(True)
    cut = len(lines)
    for index, line in enumerate(lines):
        if "Connection.Disconnecting" in line:
            cut = index
            break
    # keep the status-update lines that precede Disconnecting with the disconnect half
    while cut > 0 and "VPN.ConnectionUpdat" in lines[cut - 1]:
        cut -= 1
    return "".join(lines[:cut]), "".join(lines[cut:])


def capture(connected):
    os.makedirs(PRIVATE, exist_ok=True)
    raws = {}
    out, _, code = run([CLI, "show", ".*"], 30)
    if code != 0 or "Connection:" not in out:
        raise SystemExit("show failed (exit %s)" % code)
    if "Status: DISCONNECTED" not in out:
        raise SystemExit("connection is not disconnected; refusing to continue")
    raws["show-disconnected.txt"] = out
    if not connected:
        finish(raws)
        return
    monitor = start_monitor()
    ended = False
    try:
        time.sleep(1.0)
        out, err, _ = run([CLI, "connect", "0"], 90)
        raws["connect-ok.txt"] = out + err
        time.sleep(1.5)
        out, _, _ = run([CLI, "show", ".*"], 30)
        raws["show-connected.txt"] = out
        # The CLI prints "<uri> is not connected." on stderr (exit 0), so keep stderr too.
        out, err, _ = run([CLI, "disconnect", "0"], 60)
        raws["disconnect-ok.txt"] = out + err
        out, err, _ = run([CLI, "disconnect", "0"], 60)
        raws["disconnect-not-connected.txt"] = out + err
        ended = True
    finally:
        if not ended:
            run([CLI, "disconnect", "0"], 60)
        time.sleep(1.0)
        monitor.terminate()
        try:
            mon_out = monitor.communicate(timeout=5)[0] or ""
        except subprocess.TimeoutExpired:
            monitor.kill()
            mon_out = ""
    if not mon_out.strip():
        raise SystemExit("gdbus monitor captured nothing")
    raws["monitor-connect.txt"], raws["monitor-disconnect.txt"] = split_monitor(mon_out)
    if "Status: CONNECTED" not in raws["show-connected.txt"]:
        print("warning: show after connect did not report CONNECTED", file=sys.stderr)
    finish(raws)


def self_test():
    """Synthetic raw texts the assertion must reject (and one it must accept)."""
    bad = {
        "compressed ipv6 fe80::1": " Address: fe80::1\n",
        "loopback ::1": " DNS: ::1\n",
        "compressed ipv6 2a01:4f8::abcd:1": " DNS: 2a01:4f8::abcd:1\n",
        "compressed ipv6 fd00:1:2::5": " Address: fd00:1:2::5\n",
        "second e-mail": " Uri: https://user%40example.com@vpn.example.com/app\n bob@other.org\n",
        "second user %40": " Uri: https://bob%40other.org@vpn.example.com/app\n",
        "unlearned host": " Endpoint: evil.corp.net:51820\n",
        "real ipv4": " Address: 8.8.8.8\n",
    }
    for label, text in bad.items():
        try:
            check_shape(label, text)
        except ScrubError:
            continue
        raise ScrubError("self-test: assertion accepted %s" % label)
    good = (" Uri: https://user%40example.com@vpn.example.com:8443/app\n DNS: 198.51.100.2,2001:db8::1\n"
            "/com/logonbox/vpn: com.logonbox.vpn.VPN.ConnectionUpdated (int64 0,)\nowned by :1.22\n")
    check_shape("good sample", good)
    # Learning: two users, compressed IPv6 and a second host must all be scrubbed.
    raw = ("Basic\n Connection: 0\n Uri: https://a.b%40corp.test@srv.corp.test:8443/app\n Owner: carol\n"
           "VPN\n Address: fe80::1\n Endpoint: edge.other.test:51820\n DNS: ::1,203.0.113.9\n\n"
           "Basic\n Connection: 1\n Uri: https://zed%40mail.test@srv2.corp.test/app\n Owner: dave\n")
    scrubber = Scrubber()
    scrubber.learn(raw)
    scrubber.assert_clean("learning sample", scrubber.scrub(raw))
    print("self-test: ok")


def check_only():
    self_test()
    raws = {}
    for name in ("show-disconnected.txt", "show-connected.txt"):
        path = os.path.join(PRIVATE, name)
        if os.path.exists(path):
            raws[name] = read(path)
    scrubber = build_scrubber(raws) if raws else None
    count = 0
    for name in sorted(os.listdir(FIXTURES)):
        path = os.path.join(FIXTURES, name)
        if not os.path.isfile(path) or not name.endswith(".txt"):
            continue
        text = read(path)
        if scrubber:
            scrubber.assert_clean(name, text)
        else:
            check_shape(name, text)
        count += 1
    print("scrub: ok (%d fixtures%s)" % (count, "" if scrubber else ", no private raw to learn from"))


def main(argv):
    try:
        if "--check-only" in argv:
            check_only()
        else:
            capture("--connected" in argv)
            check_only()
    except ScrubError as err:
        print("SCRUB FAILED: %s" % err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
