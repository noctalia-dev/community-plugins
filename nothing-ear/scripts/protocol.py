"""Nothing/CMF earbuds SPP wire protocol.

Implemented from PROTOCOL.md (https://github.com/Zyrecx/noctalia-plugins/blob/main/nothing-ear/PROTOCOL.md),
independent clean-room facts. The frame
format, CRC, and every command below are hardware-verified against a
Nothing Ear (2); the rest of the Nothing/CMF earbuds line is believed to
share this exact command set (cross-checked against independent community
reverse-engineering — see PROTOCOL.md and models.py), not verified by this
plugin on other hardware. Not transliterated from any reference source.
"""
from __future__ import annotations

from dataclasses import dataclass

MAGIC = bytes([0x55, 0x60])
HEADER_LEN = 8
CRC_LEN = 2

# command IDs, hex form of the device's numeric command values
BATTERY_READ = 0xC007
BATTERY_RESP = 0x4007
BATTERY_PUSH = 0xE001

ANC_READ = 0xC01E
ANC_RESP = 0x401E
ANC_WRITE = 0xF00F
ANC_PUSH = 0xE003

EQ_PRESET_READ = 0xC01F
EQ_PRESET_RESP = 0x401F
EQ_PRESET_WRITE = 0xF010

FIRMWARE_READ = 0xC042
FIRMWARE_RESP = 0x4042

LATENCY_READ = 0xC041
LATENCY_RESP = 0x4041
LATENCY_WRITE = 0xF040

GESTURE_READ = 0xC018
GESTURE_RESP = 0x4018

# Both mapped against the Nothing X app on an Ear (2) (see PROTOCOL.md).
PERSONAL_ANC_READ = 0xC020
PERSONAL_ANC_RESP = 0x4020
PERSONAL_ANC_WRITE = 0xF011

SOUND_PROFILE_READ = 0xC022
SOUND_PROFILE_RESP = 0x4022
SOUND_PROFILE_WRITE = 0xF015
# ID of the hearing-test profile saved by the app; all zeros when none.
SOUND_PROFILE_ID_READ = 0xC024
SOUND_PROFILE_ID_RESP = 0x4024

SERIAL_READ = 0xC006
SERIAL_RESP = 0x4006
GESTURE_WRITE = 0xF003

# ANC wire mode byte (payload offset 1 of a 3-byte [0x01, mode, 0x00] frame)
ANC_MODE_HIGH = 0x01
ANC_MODE_MID = 0x02
ANC_MODE_LOW = 0x03
ANC_MODE_ADAPTIVE = 0x04
ANC_MODE_OFF = 0x05
ANC_MODE_TRANSPARENCY = 0x07


def crc16(data: bytes) -> int:
    """CRC-16/ARC: init 0xFFFF, reflected, poly 0xA001, no final XOR."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def build_frame(cmd: int, payload: bytes = b"", seq: int = 1) -> bytes:
    if not (0 <= seq <= 0xFF):
        raise ValueError("seq must fit in one byte")
    if len(payload) > 0xFF:
        raise ValueError("payload too long for single-byte length field")
    header = bytearray(
        [
            MAGIC[0],
            MAGIC[1],
            0x01,
            cmd & 0xFF,
            (cmd >> 8) & 0xFF,
            len(payload),
            0x00,
            seq,
        ]
    )
    header += payload
    crc = crc16(bytes(header))
    header += bytes([crc & 0xFF, (crc >> 8) & 0xFF])
    return bytes(header)


@dataclass
class Frame:
    cmd: int
    seq: int
    payload: bytes


class FrameParser:
    """Accumulating parser for a real RFCOMM byte stream.

    A persistent socket splits and coalesces frames arbitrarily, so frames
    must never be assumed to align with individual recv() calls. Feed raw
    bytes in as they arrive; complete, CRC-validated frames come out.
    """

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes) -> list[Frame]:
        self._buf += data
        frames: list[Frame] = []
        while True:
            frame = self._try_extract_one()
            if frame is None:
                break
            frames.append(frame)
        return frames

    def _try_extract_one(self) -> Frame | None:
        buf = self._buf
        start = buf.find(MAGIC)
        if start == -1:
            # keep last byte in case it's a split magic-byte-0
            if buf:
                del buf[:-1]
            return None
        if start > 0:
            del buf[:start]

        if len(buf) < HEADER_LEN:
            return None

        payload_len = buf[5]
        total_len = HEADER_LEN + payload_len + CRC_LEN
        if len(buf) < total_len:
            return None

        frame_bytes = bytes(buf[:total_len])
        header_and_payload = frame_bytes[: HEADER_LEN + payload_len]
        crc_bytes = frame_bytes[HEADER_LEN + payload_len : total_len]
        expected_crc = crc16(header_and_payload)
        actual_crc = crc_bytes[0] | (crc_bytes[1] << 8)

        if actual_crc != expected_crc:
            # desync: drop the magic bytes we matched on and resync forward
            del buf[:2]
            return self._try_extract_one()

        cmd = header_and_payload[3] | (header_and_payload[4] << 8)
        seq = header_and_payload[7]
        payload = header_and_payload[HEADER_LEN:]
        del buf[:total_len]
        return Frame(cmd=cmd, seq=seq, payload=payload)


def parse_battery(payload: bytes) -> dict:
    device_names = {0x02: "left", 0x03: "right", 0x04: "case"}
    status: dict[str, dict | None] = {"left": None, "right": None, "case": None}
    count = payload[0]
    for i in range(count):
        device_id = payload[1 + i * 2]
        raw = payload[2 + i * 2]
        name = device_names.get(device_id)
        if name is None:
            continue
        status[name] = {
            "level": raw & 0x7F,
            "charging": bool(raw & 0x80),
        }
    return status


def parse_anc(payload: bytes) -> dict:
    mode_byte = payload[1]
    mode_map = {
        ANC_MODE_HIGH: {"mode": "anc", "strength": "high"},
        ANC_MODE_MID: {"mode": "anc", "strength": "mid"},
        ANC_MODE_LOW: {"mode": "anc", "strength": "low"},
        ANC_MODE_ADAPTIVE: {"mode": "anc", "strength": "adaptive"},
        ANC_MODE_OFF: {"mode": "off", "strength": None},
        ANC_MODE_TRANSPARENCY: {"mode": "transparency", "strength": None},
    }
    return mode_map.get(mode_byte, {"mode": "unknown", "strength": None, "raw": mode_byte})


def anc_write_payload(mode_byte: int) -> bytes:
    return bytes([0x01, mode_byte, 0x00])


_ANC_NAME_TO_BYTE = {
    ("anc", "high"): ANC_MODE_HIGH,
    ("anc", "mid"): ANC_MODE_MID,
    ("anc", "low"): ANC_MODE_LOW,
    ("anc", "adaptive"): ANC_MODE_ADAPTIVE,
    ("off", None): ANC_MODE_OFF,
    ("transparency", None): ANC_MODE_TRANSPARENCY,
}


def anc_mode_to_byte(mode: str, strength: str | None) -> int:
    key = (mode, strength if mode == "anc" else None)
    if key not in _ANC_NAME_TO_BYTE:
        raise ValueError(f"unknown ANC mode/strength combination: {mode!r}/{strength!r}")
    return _ANC_NAME_TO_BYTE[key]


def parse_eq_preset(payload: bytes) -> int:
    return payload[0]


def eq_preset_write_payload(preset_index: int) -> bytes:
    return bytes([preset_index, 0x00])


def parse_firmware(payload: bytes) -> str:
    # payload length (from the frame header) IS the string length already;
    # no separate size byte inside the payload.
    return payload.decode("ascii", errors="replace")


def parse_latency(payload: bytes) -> bool:
    return payload[0] == 0x01


def latency_write_payload(enabled: bool) -> bytes:
    return bytes([0x01 if enabled else 0x02, 0x00])


def parse_personal_anc(payload: bytes) -> bool:
    return payload[0] == 0x01


def personal_anc_write_payload(enabled: bool) -> bytes:
    return bytes([0x01 if enabled else 0x00])


def parse_sound_profile(payload: bytes) -> bool:
    return payload[0] == 0x01


def sound_profile_write_payload(enabled: bool) -> bytes:
    return bytes([0x01 if enabled else 0x00, 0x00])


def has_sound_profile(payload: bytes) -> bool:
    return any(payload)


def parse_serial(payload: bytes) -> str | None:
    """The device's serial number out of a small CSV-style config dump.

    Payload is 7 bytes of unrelated framing followed by one or more
    comma-separated `key,type,value` text lines; the serial number is the
    line whose type field is "4". Used for model identification (see
    models.py) — structure confirmed against this plugin's own hardware
    (Ear (2)) and cross-checked against independent community
    reverse-engineering of the wider product line (see PROTOCOL.md).
    """
    if len(payload) < 8:
        return None
    text = payload[7:].decode("utf-8", errors="replace")
    for line in text.splitlines():
        parts = line.split(",")
        if len(parts) == 3 and parts[1].strip() == "4":
            value = parts[2].strip()
            if value:
                return value
    return None


def parse_gestures(payload: bytes) -> list[dict]:
    count = payload[0]
    gestures = []
    for i in range(count):
        offset = 1 + i * 4
        gestures.append(
            {
                "device": payload[offset],
                "common": payload[offset + 1],
                "type": payload[offset + 2],
                "action": payload[offset + 3],
            }
        )
    return gestures
