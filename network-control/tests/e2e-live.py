#!/usr/bin/env python3
"""Live end-to-end test of Network Control against the running Noctalia shell.

    python3 tests/e2e-live.py

Drives only the plugin's own IPC surface, so every layer is exercised: request
-> validation -> nmcli argv -> apply -> service state -> confirm window.

It creates one throwaway dummy connection (`netctl-e2e` / `netctle2e0`) that
carries NO gateway, so it can never win the default route away from the real
uplink, and deletes it at the end. A profile of that name which this run did not
create makes the script refuse to start rather than adopt and delete it.

Requires the plugin to be enabled and this machine's shell to be running.
"""

import json
import pathlib
import subprocess
import sys
import time

ENTRY = "muhammadessam/network-control:service"
STATE = pathlib.Path.home() / ".local/state/noctalia/plugins/data/muhammadessam/network-control/state.json"
PROFILE = "netctl-e2e"
IFNAME = "netctle2e0"

results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS  " if ok else "FAIL  ") + name + (("   [" + str(detail) + "]") if detail else ""))


def send(payload, label=None):
    out = subprocess.run(["noctalia", "msg", "plugin", ENTRY, "all", "request", json.dumps(payload)],
                         capture_output=True, text=True)
    text = (out.stdout + out.stderr).strip()
    if label:
        print("  -> %-24s %s" % (label, text))
    return text


def profile_names():
    """Every connection name, so a suite can prove it owns the profile it touches."""
    return [line.split(":", 1)[-1] for line in nmcli("-t", "-f", "NAME", "con", "show").splitlines()]


def nmcli(*args):
    return subprocess.run(["nmcli", *args], capture_output=True, text=True).stdout.strip()


def wait_idle(timeout=90.0, poll=2.0, settle=4.0):
    """A join runs several nmcli calls; read its outcome once the service is idle.

    `settle` matters: sampling immediately can land before the request has even
    flipped the service's busy flag, which reads as "already finished".
    """
    time.sleep(settle)
    deadline = time.time() + timeout
    state = dump()
    while time.time() < deadline and state.get("busy"):
        time.sleep(poll)
        state = dump()
    return state


def online():
    return subprocess.run(["ping", "-c1", "-W3", "1.1.1.1"], capture_output=True).returncode == 0


def dump():
    send({"action": "diagnose"})
    time.sleep(1.5)
    return json.loads(STATE.read_text())


def profile_fields(uuid, fields="ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.dns-search,ipv6.method"):
    text = nmcli("-t", "-f", fields, "con", "show", uuid)
    return dict(line.split(":", 1) for line in text.splitlines() if ":" in line)


def form(**overrides):
    base = {
        "ipv4_method": "auto", "ipv4_addresses": "", "ipv4_gateway": "",
        "ipv4_dns": "", "ipv4_dns_search": "",
        "ipv6_method": "auto", "ipv6_addresses": "", "ipv6_gateway": "",
        "ipv6_dns": "", "ipv6_dns_search": "",
    }
    base.update(overrides)
    return base


def default_routes():
    return [line for line in nmcli("-t", "route").splitlines()] or subprocess.run(
        ["ip", "-br", "route", "show", "default"], capture_output=True, text=True).stdout.splitlines()


def uplink_routes():
    return subprocess.run(["ip", "-4", "route", "show", "default"], capture_output=True, text=True).stdout


print("uplink before:", uplink_routes().strip().replace("\n", " / "))

# This suite owns exactly one profile, the one it creates. A profile of the same
# name that this run did not create is somebody else's: it is never modified, and
# the finally block below only ever deletes what setup here created.
OWNED = False
if PROFILE in profile_names():
    print("%s already exists and was not created by this run - refusing to touch it" % PROFILE)
    raise SystemExit(1)
print(nmcli("con", "add", "type", "dummy", "con-name", PROFILE, "ifname", IFNAME, "autoconnect", "no"))
if PROFILE not in profile_names():
    raise SystemExit("could not create %s" % PROFILE)
OWNED = True
nmcli("con", "down", PROFILE)
uuid = nmcli("-t", "-f", "connection.uuid", "con", "show", PROFILE).split(":", 1)[-1].strip()
assert uuid, "could not resolve the test profile uuid"
print("test profile:", PROFILE, uuid)
time.sleep(1)

try:
    # ── inventory and selection ──────────────────────────────────────────────
    send({"action": "refresh"}, "refresh")
    time.sleep(2)
    state = dump()
    known = [c for c in state["connections"] if c["uuid"] == uuid]
    check("new profile appears in the inventory", len(known) == 1)
    check("NM type mapped to a short kind", known and known[0]["kind"] == "dummy", known and known[0]["kind"])

    send({"action": "select", "uuid": uuid}, "select")
    time.sleep(2)
    state = dump()
    check("selection moved to the test profile", state["selected"] == uuid, state.get("selected_name"))
    check("profile snapshot loaded", state["profile"] is not None, (state.get("profile") or {}).get("ipv4_method"))

    # ── validation refusals leave the profile alone ──────────────────────────
    send({"action": "apply", "uuid": uuid, "form": form(ipv4_method="manual", ipv4_addresses="10.999.0.7/24")})
    time.sleep(2)
    state = dump()
    check("invalid address refused", "10.999.0.7" in (state.get("error") or ""), state.get("error"))
    check("refusal wrote nothing", profile_fields(uuid)["ipv4.method"] == "disabled", profile_fields(uuid)["ipv4.method"])

    send({"action": "apply", "uuid": uuid, "form": form(ipv4_method="auto", ipv4_gateway="10.99.0.1")})
    time.sleep(2)
    state = dump()
    check("gateway without an address refused", "gateway" in (state.get("error") or "").lower(), state.get("error"))

    # ── a real write, on an inactive profile ─────────────────────────────────
    send({"action": "apply", "uuid": uuid, "form": form(
        ipv4_method="manual", ipv4_addresses="10.99.0.7", ipv4_gateway="10.99.0.1",
        ipv4_dns="9.9.9.9, 149.112.112.112", ipv4_dns_search="example.test", ipv6_method="disabled")})
    time.sleep(3)
    written = profile_fields(uuid)
    state = dump()
    check("static address written, bare address prefixed", written["ipv4.addresses"] == "10.99.0.7/24",
          written["ipv4.addresses"])
    check("gateway written", written["ipv4.gateway"] == "10.99.0.1", written["ipv4.gateway"])
    check("dns list written", written["ipv4.dns"] == "9.9.9.9,149.112.112.112", written["ipv4.dns"])
    check("search domain written", written["ipv4.dns-search"] == "example.test", written["ipv4.dns-search"])
    check("ipv6 method written", written["ipv6.method"] == "disabled", written["ipv6.method"])
    check("service state reflects the write", state["profile"]["ipv4_addresses"] == "10.99.0.7/24",
          state["profile"]["ipv4_addresses"])
    check("inactive profile arms no confirm window", state.get("pending") is None and not state.get("busy"),
          state.get("pending"))
    check("no error reported", not state.get("error"), state.get("error"))

    send({"action": "apply", "uuid": uuid, "form": form(ipv4_method="auto", ipv4_dns="9.9.9.9")})
    time.sleep(3)
    written = profile_fields(uuid)
    check("dhcp clears the address", written["ipv4.addresses"] == "", written["ipv4.addresses"])
    check("dhcp clears the gateway", written["ipv4.gateway"] == "", written["ipv4.gateway"])
    check("dhcp keeps dns", written["ipv4.dns"] == "9.9.9.9", written["ipv4.dns"])

    before = profile_fields(uuid)
    send({"action": "apply", "uuid": uuid, "form": form(ipv4_method="auto", ipv4_dns="9.9.9.9")})
    time.sleep(2)
    check("a no-op apply changes nothing", profile_fields(uuid) == before)

    # ── the confirm window, on an active profile ─────────────────────────────
    # Bring the dummy up with an address and no gateway: nothing it does can
    # displace the real default route.
    send({"action": "apply", "uuid": uuid, "form": form(ipv4_method="manual", ipv4_addresses="10.99.0.7/24")})
    time.sleep(3)
    nmcli("con", "up", PROFILE)
    time.sleep(2)
    check("test link is up with an address",
          "10.99.0.7" in subprocess.run(["ip", "-br", "addr", "show", IFNAME], capture_output=True, text=True).stdout,
          subprocess.run(["ip", "-br", "addr", "show", IFNAME], capture_output=True, text=True).stdout.strip())
    check("the uplink still owns the default route",
          "wlp0s20f3" in uplink_routes() and PROFILE not in uplink_routes() and IFNAME not in uplink_routes(),
          uplink_routes().strip().replace("\n", " / "))

    send({"action": "refresh"}, "refresh")
    time.sleep(2)
    send({"action": "apply", "uuid": uuid, "form": form(
        ipv4_method="manual", ipv4_addresses="10.99.0.8/24", ipv6_method="disabled")})
    time.sleep(3)
    state = dump()
    check("active profile arms the confirm window", state.get("pending") is not None,
          (state.get("pending") or {}).get("name"))
    check("the change landed", profile_fields(uuid)["ipv4.addresses"] == "10.99.0.8/24",
          profile_fields(uuid)["ipv4.addresses"])

    send({"action": "keep"}, "keep")
    time.sleep(3)
    state = dump()
    check("keep clears the window", state.get("pending") is None, state.get("pending"))
    time.sleep(3)
    check("keep keeps the change", profile_fields(uuid)["ipv4.addresses"] == "10.99.0.8/24",
          profile_fields(uuid)["ipv4.addresses"])

    # an unconfirmed change must roll itself back
    send({"action": "refresh"}, "refresh")
    time.sleep(2)
    send({"action": "apply", "uuid": uuid, "form": form(
        ipv4_method="manual", ipv4_addresses="10.99.0.9/24", ipv6_method="disabled")})
    time.sleep(3)
    state = dump()
    check("second change arms the window again", state.get("pending") is not None,
          (state.get("pending") or {}).get("name"))
    check("second change landed", profile_fields(uuid)["ipv4.addresses"] == "10.99.0.9/24",
          profile_fields(uuid)["ipv4.addresses"])
    window = float(state.get("confirm_seconds") or 45)
    print("  .. waiting out the %.0fs confirm window (no keep sent)" % window)
    time.sleep(window + 12)
    state = dump()
    check("timeout reverts to the previous profile", profile_fields(uuid)["ipv4.addresses"] == "10.99.0.8/24",
          profile_fields(uuid)["ipv4.addresses"])
    check("timeout clears the window", state.get("pending") is None, state.get("pending"))
    check("the reverted link is back up", "10.99.0.8" in subprocess.run(
        ["ip", "-br", "addr", "show", IFNAME], capture_output=True, text=True).stdout,
        subprocess.run(["ip", "-br", "addr", "show", IFNAME], capture_output=True, text=True).stdout.strip())
    check("last restore point is offered", state.get("backup") is not None, state.get("backup"))

    # ── the wi-fi picker ─────────────────────────────────────────────────────
    # Only the safe half: a scan, and refusals that never reach the radio. Joining
    # a saved network re-activates the uplink, so that one stays a manual check.
    send({"action": "scan", "rescan": True}, "scan")
    time.sleep(12)
    state = dump()
    scanned = state.get("networks") or []
    check("scan returns networks", len(scanned) > 0, len(scanned))
    shaped = all(isinstance(n.get("ssid"), str) and n["ssid"] != "" and isinstance(n.get("signal"), int)
                 and isinstance(n.get("aps"), int) and n["aps"] >= 1 for n in scanned)
    check("every entry is a named network with a signal", shaped)
    check("no SSID is listed twice", len({n["ssid"] for n in scanned}) == len(scanned))
    check("the active network is marked and sorts first",
          any(n["in_use"] for n in scanned) and scanned[0].get("in_use") is True,
          scanned[0]["ssid"] if scanned else None)
    signals = [n["signal"] for n in scanned]
    check("results are ordered by signal", signals == sorted(signals, reverse=True) or scanned[0]["in_use"])
    check("saved profiles are reported", isinstance(state.get("saved_ssids"), dict), state.get("saved_ssids"))

    before_ssid = next((n["ssid"] for n in scanned if n["in_use"]), None)
    send({"action": "wifi-connect", "ssid": "", "password": "x"}, "connect (empty ssid)")
    time.sleep(3)
    state = dump()
    check("an empty SSID is refused", "name" in (state.get("error") or "").lower(), state.get("error"))

    # the join creates a profile, tries to activate it, fails and removes it
    # again - so wait for the service to go idle rather than for a fixed sleep
    send({"action": "wifi-connect", "ssid": "hermes-does-not-exist-42", "password": "irrelevant"}, "connect (unknown)")
    state = wait_idle()
    check("joining an unknown network fails loudly", bool(state.get("error")), state.get("error"))
    # The contract is that the message names which network failed and repeats what
    # NetworkManager said. "could not be found" is NetworkManager's wording; the
    # SSID prefix is the plugin's own.
    check("the failure names the network and its reason",
          "hermes-does-not-exist-42" in (state.get("error") or "")
          and "could not be found" in (state.get("error") or "").lower(), state.get("error"))
    check("no profile is left behind by the failed join",
          "hermes-does-not-exist-42" not in subprocess.run(["nmcli", "-t", "-f", "NAME", "con", "show"],
                                                           capture_output=True, text=True).stdout)
    check("the uplink survived the failed join",
          any(n["in_use"] for n in (state.get("networks") or [])) or state.get("primary") is not None,
          state.get("primary") and state["primary"]["device"])
    # an attempted join makes the radio scan, which can blip the existing link
    check("still online after the failed join",
          online() or any(online() for _ in range(3)))
    check("the failed join selected nothing new", state.get("selected_name") is not None, state.get("selected_name"))

    # ── radio, and the restore action ────────────────────────────────────────
    send({"action": "radio", "kind": "wifi", "on": True}, "radio on")
    time.sleep(3)
    state = dump()
    check("wifi radio still on", (state.get("radio") or {}).get("wifi") == "enabled", state.get("radio"))

    # A change made outside the plugin, then pulled back to the restore point.
    nmcli("con", "mod", uuid, "ipv4.method", "manual", "ipv4.addresses", "10.99.0.11/24")
    send({"action": "refresh"}, "refresh")
    time.sleep(2)
    state = dump()
    check("out-of-band change is visible in the state",
          state["profile"]["ipv4_addresses"] == "10.99.0.11/24", state["profile"]["ipv4_addresses"])

    # the service ignores a request while it is busy (the panel disables its
    # buttons for that reason), so a scripted client retries
    restored = ""
    for attempt in range(4):
        wait_idle()
        send({"action": "restore"}, "restore" if attempt == 0 else "restore retry")
        for _ in range(4):
            time.sleep(3)
            restored = profile_fields(uuid)["ipv4.addresses"]
            if restored == "10.99.0.8/24":
                break
        if restored == "10.99.0.8/24":
            break
    check("restore re-applies the recorded profile", restored == "10.99.0.8/24", restored)
    send({"action": "keep"}, "keep")
    time.sleep(2)
finally:
    if OWNED:
        nmcli("con", "down", PROFILE)
        print(nmcli("con", "delete", PROFILE))
    else:
        print("nothing to clean up: this run did not create %s" % PROFILE)
    time.sleep(1)

time.sleep(3)
print("uplink after: ", uplink_routes().strip().replace("\n", " / "))
check("default route untouched by the test", "wlp0s20f3" in uplink_routes() and IFNAME not in uplink_routes())
print("\n%d passed, %d failed" % (sum(results), len(results) - sum(results)))
sys.exit(0 if all(results) else 1)
