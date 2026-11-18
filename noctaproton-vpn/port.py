#!/usr/bin/env python3
"""Ask the VPN gateway for the forwarded port, and keep it alive.

Proton assigns an inbound port on P2P servers through NAT-PMP (RFC 6886) on
the tunnel gateway, 10.2.0.1. The mapping lapses unless it is renewed, which
is why Proton's guide runs `natpmpc` in a loop; the CLI's own agent does the
same exchange but only for as long as a `protonvpn` process is alive. This
is that exchange, in the standard library, printed as JSON:

    {"port": 58197}     a mapping for UDP and TCP, good for `lifetime` seconds
    {}                  no port: not a P2P server, port forwarding off, or no tunnel

Both requests ask for external port 0 with a 60 second lifetime, the values
Proton's guide uses, so the gateway hands back the port it already assigned
to this session. Nothing is sent anywhere but the gateway inside the tunnel.
"""
import json
import socket
import struct
import sys

GATEWAY = "10.2.0.1"
PORT = 5351
LIFETIME = 60
UDP, TCP = 1, 2


def mapping(proto):
    """One NAT-PMP mapping request. Returns the external port, or None."""
    request = struct.pack("!BBHHHI", 0, proto, 0, 0, 0, LIFETIME)
    timeout = 0.25
    for _ in range(4):  # 250 ms, 500 ms, 1 s, 2 s: RFC 6886's backoff, shortened
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(timeout)
                # Connected, so the kernel only delivers replies from the
                # gateway and anything else that reaches the port is dropped.
                sock.connect((GATEWAY, PORT))
                sock.send(request)
                data = sock.recv(64)
        except (OSError, socket.timeout):
            timeout *= 2
            continue
        if len(data) < 16:
            return None
        version, opcode, result, _epoch, _internal, external, _life = struct.unpack("!BBHIHHI", data[:16])
        if version != 0 or opcode != 128 + proto or result != 0:
            return None
        return external
    return None


def main():
    udp = mapping(UDP)
    tcp = mapping(TCP)
    port = udp if udp else tcp
    print(json.dumps({"port": port} if port else {}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
