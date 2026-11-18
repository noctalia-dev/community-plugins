"""Minimal SDP client: resolve the RFCOMM channel for a service UUID.

Hand-rolled against the SDP protocol spec (no pybluez dependency). Confirmed
working against 2C:BE:EB:6F:25:1E: resolved channel 15 for the Nothing Ear
SPP service UUID.
"""
from __future__ import annotations

import socket
import uuid

SDP_PSM = 1
SERVICE_SEARCH_ATTRIBUTE_REQUEST = 0x06
SERVICE_SEARCH_ATTRIBUTE_RESPONSE = 0x07


class SdpError(RuntimeError):
    """The SDP server answered, but not with something usable. Carries the
    raw reply so a bug report shows what the device actually sent."""

    def __init__(self, message: str, response: bytes = b""):
        super().__init__(message)
        self.response = response


class ServiceNotFound(SdpError):
    """The device doesn't advertise the service, or no RFCOMM channel for it."""


def _build_request(service_uuid: uuid.UUID) -> bytes:
    uuid_elem = bytes([0x1C]) + service_uuid.bytes  # UUID128 data element
    search_pattern = bytes([0x35, len(uuid_elem)]) + uuid_elem
    max_attr_bytes = (0xFFFF).to_bytes(2, "big")
    attr_range = bytes([0x0A]) + (0x0000FFFF).to_bytes(4, "big")  # attr range 0x0000-0xFFFF
    attr_id_list = bytes([0x35, len(attr_range)]) + attr_range
    params = search_pattern + max_attr_bytes + attr_id_list

    pdu_id = SERVICE_SEARCH_ATTRIBUTE_REQUEST
    tid = (1).to_bytes(2, "big")
    body = params + b"\x00"  # no continuation
    plen = len(body).to_bytes(2, "big")
    return bytes([pdu_id]) + tid + plen + body


def _find_rfcomm_channel(attr_bytes: bytes) -> int | None:
    """Scan a raw SDP attribute-list blob for a ProtocolDescriptorList
    entry naming RFCOMM (UUID16 0x0003) and return its channel number.
    """
    rfcomm_uuid = bytes([0x19, 0x00, 0x03])
    idx = attr_bytes.find(rfcomm_uuid)
    if idx == -1:
        return None
    # expect: 19 00 03 08 <channel>  (uint8 data element tag 0x08)
    tail = attr_bytes[idx + len(rfcomm_uuid) :]
    if len(tail) >= 2 and tail[0] == 0x08:
        return tail[1]
    return None


def resolve_rfcomm_channel(address: str, service_uuid: str) -> int:
    """Query the device's SDP server for the RFCOMM channel serving
    `service_uuid`. Raises SdpError (ServiceNotFound if the device doesn't
    advertise it), or OSError if the SDP connection itself fails.
    """
    target = uuid.UUID(service_uuid)
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    try:
        sock.settimeout(10)
        sock.connect((address, SDP_PSM))
        sock.send(_build_request(target))
        resp = sock.recv(4096)
    finally:
        sock.close()

    if not resp or resp[0] != SERVICE_SEARCH_ATTRIBUTE_RESPONSE:
        raise SdpError(f"unexpected SDP response for {service_uuid} on {address}", resp or b"")

    channel = _find_rfcomm_channel(resp)
    if channel is None:
        raise ServiceNotFound(f"no RFCOMM channel found for {service_uuid} on {address}", resp)
    return channel
