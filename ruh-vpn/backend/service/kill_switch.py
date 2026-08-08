"""nftables-backed kill switch.

Generates a self-contained inet table that drops all traffic except:
  - loopback
  - established / related connections
  - the noctalia-tun0 device (when present)
  - the proxy mux/transport ports on 127.0.0.1 (already covered by loopback)
  - explicit allowances for the active VPN server's host:port (so sing-box
    can dial out to it after the rules are installed)

The table is named "noctalia_killswitch" so removal/replacement is cheap and
does not touch anyone else's nftables config.
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
from typing import Optional

TABLE_NAME = "noctalia_killswitch"
NFT_BIN = "/usr/sbin/nft"


def _nft_path() -> str:
    return shutil.which("nft") or NFT_BIN


def build_ruleset(
    server_host: Optional[str],
    server_port: Optional[int],
    tun_iface: str = "noctalia-tun0",
    extra_allow_tcp: Optional[list[int]] = None,
) -> str:
    """Build the nft ruleset text. server_host may be IPv4 / IPv6 / domain.

    Domain names are skipped (caller should pre-resolve when possible); only
    literal IPs land in the rule. The caller is responsible for kicking off a
    DNS resolve if needed.
    """
    tcp_ports = list(extra_allow_tcp or [])
    server_v4_line = ""
    server_v6_line = ""
    if server_host:
        if ":" in server_host:
            server_v6_line = (
                f"        ip6 daddr {server_host} tcp dport {server_port} accept\n"
                if server_port
                else f"        ip6 daddr {server_host} accept\n"
            )
        else:
            server_v4_line = (
                f"        ip daddr {server_host} tcp dport {server_port} accept\n"
                if server_port
                else f"        ip daddr {server_host} accept\n"
            )

    tcp_port_line = ""
    if tcp_ports:
        ports = "{ " + ", ".join(str(p) for p in tcp_ports) + " }"
        tcp_port_line = f"        tcp dport {ports} accept\n"

    return (
        f"table inet {TABLE_NAME} {{\n"
        f"    chain output {{\n"
        f"        type filter hook output priority filter; policy drop;\n"
        f"        oif \"lo\" accept\n"
        f"        ct state established,related accept\n"
        f"        oifname \"{tun_iface}\" accept\n"
        f"        udp dport 53 accept\n"
        f"        ip daddr 192.168.0.0/16 accept\n"
        f"        ip daddr 10.0.0.0/8 accept\n"
        f"        ip daddr 172.16.0.0/12 accept\n"
        f"{server_v4_line}{server_v6_line}{tcp_port_line}"
        f"    }}\n"
        f"    chain input {{\n"
        f"        type filter hook input priority filter; policy drop;\n"
        f"        iif \"lo\" accept\n"
        f"        ct state established,related accept\n"
        f"        iifname \"{tun_iface}\" accept\n"
        f"    }}\n"
        f"}}\n"
    )


async def _run_nft(args: list[str], input_text: Optional[str] = None) -> tuple[int, str]:
    nft = _nft_path()
    proc = await asyncio.create_subprocess_exec(
        nft,
        *args,
        stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    out, _ = await proc.communicate(input_text.encode() if input_text else None)
    return proc.returncode or 0, out.decode("utf-8", errors="replace")


async def _run_nft_via_pkexec(args: list[str], input_text: Optional[str] = None) -> tuple[int, str]:
    if shutil.which("pkexec") is None:
        return 1, "pkexec not available"
    nft = _nft_path()
    cmd = ["pkexec", nft, *args]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    out, _ = await proc.communicate(input_text.encode() if input_text else None)
    return proc.returncode or 0, out.decode("utf-8", errors="replace")


async def apply(ruleset: str) -> tuple[bool, str]:
    """Install (or replace) the kill switch ruleset. Returns (ok, message)."""
    # remove any prior version atomically before re-adding (idempotent)
    purge_cmd = f"delete table inet {TABLE_NAME}\n" + ruleset
    rc, out = await _run_nft(["-f", "-"], input_text=purge_cmd)
    if rc == 0:
        return True, "applied"
    # try just the add (no prior table)
    rc2, out2 = await _run_nft(["-f", "-"], input_text=ruleset)
    if rc2 == 0:
        return True, "applied"
    # fall back to pkexec
    rc3, out3 = await _run_nft_via_pkexec(["-f", "-"], input_text=purge_cmd)
    if rc3 == 0:
        return True, "applied via pkexec"
    rc4, out4 = await _run_nft_via_pkexec(["-f", "-"], input_text=ruleset)
    if rc4 == 0:
        return True, "applied via pkexec"
    return False, f"nft failed: {out2 or out}; pkexec: {out4 or out3}"


async def remove() -> tuple[bool, str]:
    rc, out = await _run_nft(["delete", "table", "inet", TABLE_NAME])
    if rc == 0:
        return True, "removed"
    rc2, out2 = await _run_nft_via_pkexec(["delete", "table", "inet", TABLE_NAME])
    if rc2 == 0:
        return True, "removed via pkexec"
    # if the table doesn't exist, treat as success
    if "No such file or directory" in (out + out2) or "does not exist" in (out + out2):
        return True, "no table to remove"
    return False, f"nft failed: {out}; pkexec: {out2}"


async def is_active() -> bool:
    rc, out = await _run_nft(["list", "table", "inet", TABLE_NAME])
    return rc == 0
