#!/usr/bin/env python3
"""
Shared protocol implementation for Honor Earbuds (Bestechnic BES RFCOMM SPP).
Used by both honor_ctl.py (Noctalia service) and honor-earbuds.py (standalone CLI).
"""

import socket

CRC16_TAB = [
    0, 4129, 8258, 12387, 16516, 20645, 24774, 28903, -32504, -28375, -24246, -20117, -15988, -11859,
    -7730, -3601, 4657, 528, 12915, 8786, 21173, 17044, 29431, 25302, -27847, -31976, -19589, -23718, -11331,
    -15460, -3073, -7202, 9314, 13379, 1056, 5121, 25830, 29895, 17572, 21637, -23190, -19125, -31448,
    -27383, -6674, -2609, -14932, -10867, 13907, 9842, 5649, 1584, 30423, 26358, 22165, 18100, -18597,
    -22662, -26855, -30920, -2081, -6146, -10339, -14404, 18628, 22757, 26758, 30887, 2112, 6241, 10242,
    14371, -13876, -9747, -5746, -1617, -30392, -26263, -22262, -18133, 23285, 19156, 31415, 27286, 6769,
    2640, 14899, 10770, -9219, -13348, -1089, -5218, -25735, -29864, -17605, -21734, 27814, 31879, 19684,
    23749, 11298, 15363, 3168, 7233, -4690, -625, -12820, -8755, -21206, -17141, -29336, -25271, 32407,
    28342, 24277, 20212, 15891, 11826, 7761, 3696, -97, -4162, -8227, -12292, -16613, -20678, -24743,
    -28808, -28280, -32343, -20022, -24085, -12020, -16083, -3762, -7825, 4224, 161, 12482, 8419, 20484,
    16421, 28742, 24679, -31815, -27752, -23557, -19494, -15555, -11492, -7297, -3234, 689, 4752, 8947,
    13010, 16949, 21012, 25207, 29270, -18966, -23093, -27224, -31351, -2706, -6833, -10964, -15091, 13538,
    9411, 5280, 1153, 29798, 25671, 21540, 17413, -22565, -18438, -30823, -26696, -6305, -2178, -14563,
    -10436, 9939, 14066, 1681, 5808, 26199, 30326, 17941, 22068, -9908, -13971, -1778, -5841, -26168,
    -30231, -18038, -22101, 22596, 18533, 30726, 26663, 6336, 2273, 14466, 10403, -13443, -9380, -5313,
    -1250, -29703, -25640, -21573, -17510, 19061, 23124, 27191, 31254, 2801, 6864, 10931, 14994, -722,
    -4849, -8852, -12979, -16982, -21109, -25112, -29239, 31782, 27655, 23652, 19525, 15522, 11395, 7392,
    3265, -4321, -194, -12451, -8324, -20581, -16454, -28711, -24584, 28183, 32310, 20053, 24180, 11923,
    16050, 3793, 7920
]


def crc16(data: bytes) -> bytes:
    s = 0
    for byte in data:
        s = CRC16_TAB[((s >> 8) ^ byte) & 0xFF] ^ (s << 8)
        s = s & 0xFFFF
    return s.to_bytes(2, "big")


def build_packet(cmd: bytes, parameters=None) -> bytes:
    """Build a Bestechnic protocol packet."""
    if parameters is None:
        parameters = []
    body = bytearray(cmd)
    for p_type, p_value in parameters:
        body.append(p_type)
        body.append(len(p_value))
        body.extend(p_value)
    # 0x5A + len(2B big) + 0x00 + body + crc16(2B)
    header = bytearray(b"Z")
    header.extend((len(body) + 1).to_bytes(2, "big"))
    header.append(0x00)
    header.extend(body)
    header.extend(crc16(header))
    return bytes(header)


def parse_packets(data: bytes):
    """Parse Bestechnic protocol response packets."""
    packets = []
    i = 0
    while i < len(data):
        if data[i] != 0x5A:  # 'Z'
            i += 1
            continue
        if i + 3 >= len(data):
            break
        length = int.from_bytes(data[i + 1:i + 3], "big")
        packet_end = i + length + 5
        if packet_end > len(data):
            break
        packet_data = data[i:packet_end]
        cmd_id = packet_data[4:6]
        pos = 6
        params = {}
        while pos < length + 3:
            if pos + 1 >= len(packet_data):
                break
            p_type = packet_data[pos]
            p_len = packet_data[pos + 1]
            if pos + 2 + p_len > len(packet_data):
                break
            p_val = packet_data[pos + 2:pos + 2 + p_len]
            params[p_type] = p_val
            pos += 2 + p_len
        packets.append((cmd_id, params))
        i = packet_end
    return packets