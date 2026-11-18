# Nothing/CMF earbuds — SPP protocol facts

Clean-room notes derived by observing behavior described in [`ear-web`](https://github.com/radiance-project/ear-web)
(AGPL, read-only reference — never copied) and cross-checked against
[`earctl`](https://github.com/DaanHessen/earctl) (also AGPL-3.0, not
vendored — its `src/protocol.rs` and `src/models.rs` independently document
the same frame format, command IDs, and per-model SKU table). This file
states facts about the device's wire protocol; the daemon is implemented
from this document, not by transliterating any reference source file.

Everything below is confirmed live on hardware (2026-09-10) against a
**Nothing Ear (2)** (base B155) only. The two references above independently
agree the entire Nothing/CMF earbuds line shares this exact frame format and
command-ID space, differing only in which commands each model's firmware
implements (see "Model identification" below) — that claim is *not*
independently hardware-verified by this plugin for any base other than B155.
Reads confirmed: battery, ANC, EQ preset, firmware version, latency mode,
gestures, serial/model. Writes are untested beyond what's marked ✅ below —
verify each write command individually before shipping it. See "Still open"
below for what remains unconfirmed.

Device: Nothing Ear (2), internal base model **B155**. Model identification:
SKU 17–19 → white, SKU 27–29 → black. (Not to be confused with base B171,
the 2024 "Nothing Ear" — different device, different command gating.)

## Transport

- Bluetooth Classic SPP (RFCOMM), not BLE GATT.
- Service Class UUID `aeac4a03-dff5-498f-843a-34487cf133eb`. The RFCOMM
  channel number is NOT fixed — must be resolved per-device via SDP browse
  (`sdptool browse` / BlueZ D-Bus), not guessed.
- 9600 baud framing at the serial layer (irrelevant once BlueZ owns the RFCOMM
  socket, but matches the reference's `open({baudRate: 9600})`).
- Only one process may hold the RFCOMM channel at a time.

## Frame format

All frames: `0x55 0x60 0x01 <cmd_lo> <cmd_hi> <len> 0x00 <seq> <payload...> <crc_lo> <crc_hi>`

- Bytes 0–1: fixed magic `55 60`.
- Byte 2: fixed `01`.
- Bytes 3–4: command ID, little-endian uint16.
- Byte 5: payload length (single byte — payloads observed are all < 256
  bytes; treat as the low byte of a 16-bit LE length field for forward
  safety, byte 6 is always 0 in observed traffic).
- Byte 6: fixed `00`.
- Byte 7: sequence number, increments per request, wraps at 250 back to 1.
  Responses do not obviously echo the request's sequence byte — treat it as
  informational, not a correlation key, until confirmed otherwise.
- Bytes 8..8+len-1: payload.
- Final 2 bytes: CRC-16, little-endian, computed over the ENTIRE preceding
  frame (header + payload, bytes 0 through 8+len-1).

CRC-16 algorithm (CRC-16/ARC — init 0xFFFF, no final XOR, reflected,
polynomial 0x8005 / reflected form 0xA001):

```
crc = 0xFFFF
for each byte b in frame:
    crc ^= b
    repeat 8 times:
        if crc & 1: crc = (crc >> 1) ^ 0xA001
        else:       crc = crc >> 1
append crc as two bytes, low byte first
```

## Command ID structure (inferred, verify before relying on it)

Command IDs appear to follow a bit-15 request/response pairing:
- `0xF0xx` = write/set command (device applies, may or may not ack).
- `0xC0xx` = read/get request.
- `0x40xx` = solicited response to the matching `0xC0xx` read (bit 15
  cleared: `0xC0xx & 0x7FFF == 0x40xx`). Confirmed consistent across every
  read/response pair below.
- `0xE0xx` = unsolicited push from the device (battery/ANC/ear-fit state
  changes not requested by the host).

The parser should be a generic frame reader keyed on this structure, not a
hardcoded if/else ladder per command — and should log any command ID it
doesn't recognize rather than silently dropping it (writes to `0xF0xx` may
produce an ack whose shape isn't captured here yet).

## Framing over a real stream

A persistent RFCOMM socket will split and coalesce frames arbitrarily — do
NOT assume one `read()` = one frame. Implement an accumulating parser: scan
for `55 60`, read the length byte, wait until header + payload + 2 CRC bytes
are buffered, validate the CRC, consume exactly that many bytes, repeat on
the remainder.

## Commands relevant to B155 (Ear 2)

Hex IDs below were re-derived directly from the reference's decimal command
values (an objective numeric fact, not expressive code) and then confirmed
live against hardware where marked ✅. An earlier draft of this table had
transcription errors on firmware/latency/gesture (wrong hex) — those are now
corrected and hardware-confirmed.

| Name | Read cmd | Response cmd | Write cmd | Push | Status |
|---|---|---|---|---|---|
| Battery | 0xC007 | 0x4007 | — | 0xE001 | ✅ read confirmed |
| ANC | 0xC01E | 0x401E | 0xF00F | 0xE003 | ✅ read confirmed, write untested |
| EQ preset | 0xC01F | 0x401F | 0xF010 | — | ✅ read + write confirmed, index→name mapped |
| Firmware version | 0xC042 | 0x4042 | — | — | ✅ read confirmed ("1.0.1.102") |
| Low-latency mode | 0xC041 | 0x4041 | 0xF040 | — | ✅ read confirmed |
| Gestures | 0xC018 | 0x4018 | 0xF003 | — | ✅ read confirmed, write untested |
| In-ear detection (setting) | 0xC00E | 0x400E | 0xF004 | — | the feature's on/off setting, not live wear state |
| Personalized ANC | 0xC020 | 0x4020 | 0xF011 | — | ✅ read + write confirmed |
| Personal Sound Profile | 0xC022 | 0x4022 | 0xF015 | — | ✅ read + write confirmed (on/off only) |
| Sound profile ID | 0xC024 | 0x4024 | — | — | ✅ read confirmed |
| Ring buds | — | — | 0xF002 | — | untested, no read (fire-and-forget) |
| Ear-fit test | — | — | 0xF014 | 0xE00D | untested |
| LED case color | 0xC017 | 0x4017 | 0xF00D | — | B181 (Ear 1) only per reference — likely N/A for B155, skip |
| Custom EQ | 0xC044 | 0x4044 | 0xF041 | — | float-encoded bands, deprioritized |
| Advanced EQ toggle | 0xC04C | 0x404C | 0xF04F | — | deprioritized |
| Enhanced bass | 0xC04E | 0x404E | 0xF051 | — | reference gates this out for B155 — skip |
| Listening mode | 0xC050 | 0x4050 | 0xF01D | — | reference gates this to B172/B168 only — skip |
| Serial/model | 0xC006 | 0x4006 | — | — | ✅ read confirmed |

## Model identification (response to 0xC006)

Payload is 7 bytes of framing followed by one or more comma-separated
`key,type,value` text lines; the device's serial number is the line whose
`type` field is `"4"`. A SKU code is then derived from the serial itself
(no separate "read SKU" command exists): serials starting `SH` or `13`
embed the SKU at string offset `[4:6]`; `MA`-prefixed serials (an older
scheme) are disambiguated by a year digit pair instead. This derivation is
per both reference projects (see top of file); **only the `SH` case is
hardware-confirmed**, against this Ear (2)'s own serial.

The SKU maps to an internal base model (e.g. `17`–`19`/`27`–`29` → B155 =
Ear (2); `61`/`62`/`69`/`70`/`74`/`75` → B171 = the 2024 "Nothing Ear";
`14`–`16` → B157 = Ear (stick), which has no ANC). See `scripts/models.py`
for the full table and the plugin's capability gating (currently just
ANC presence — `scripts/models.py` docstring has the full source citation).

## ANC payload (write to 0xF00F)

3-byte payload: `[0x01, <mode>, 0x00]`.

| mode byte | meaning |
|---|---|
| 0x01 | ANC on, strength high |
| 0x02 | ANC on, strength mid |
| 0x03 | ANC on, strength low |
| 0x04 | ANC on, strength adaptive |
| 0x05 | ANC off |
| 0x07 | Transparency |
| 0x06 | unused/reserved |

Read response payload: mode byte at response offset 9 (after the 8-byte
header — i.e. first payload byte), same value space as above.

**Confirm this table against hardware first** — it's traced through the
reference's own internal double-indirection (UI concept → internal level →
wire byte) rather than observed directly.

## Battery payload (response to 0xC007 / push 0xE001)

- Offset 8: connected-device count N.
- Then N pairs of bytes: `(device_id, status)`.
  - device_id: 0x02 = left, 0x03 = right, 0x04 = case.
  - status: bit 7 = charging flag, bits 0–6 = battery percentage (mask
    status with 0x7F for percentage, 0x80 for charging).

## EQ preset payload

Write: `[preset_index, 0x00]` to 0xF010. Read response: preset index as a
single byte at the first payload offset.

Index → name, mapped 2026-10-20 on a Nothing Ear (2) by selecting each preset
in the Nothing X app and reading the index back over RFCOMM:

| Index | Nothing X preset |
|---|---|
| 0 | Balanced |
| 1 | Voice |
| 2 | More treble |
| 3 | More bass |
| 4 | (not used by the app) |
| 5 | Custom |

Write confirmed the other way too: `set-eq 3` from the PC, then the app
showed "More bass" selected after reconnecting.

## Confirmed live against hardware (2026-09-10, this device, via a standalone
Python probe script — not the ear-web reference, not something-x)

- RFCOMM channel for SPP UUID `aeac4a03-...`: **15** (resolved via a raw SDP
  ServiceSearchAttributeRequest, not guessed/hardcoded — re-resolve per
  device, don't assume 15 is universal).
- Frame format, CRC-16 algorithm, and `0xC0xx`→`0x4xx` response pairing:
  request built from this spec was accepted and answered correctly.
- Battery (`0xC007`→`0x4007`): payload decoded exactly per spec (count=2,
  left=0x02/100%, right=0x03/100%, case not connected — case was off-charger
  at test time, consistent with BT-only reporting).
- ANC read (`0xC01E`→`0x401E`): 3-byte payload, mode byte at payload offset
  1 (frame index 9) = 0x05 (off), consistent with earbuds' actual state.
  Payload offset 0 (frame index 8) = 0x01, meaning/purpose not yet known —
  possibly a type/side discriminator, needs more samples.
- EQ preset read (`0xC01F`→`0x401F`): 1-byte payload = 0x00 (preset index 0,
  likely "Balanced" — name mapping still unconfirmed).
- **Correction to the ANC payload table above**: the mode byte is at frame
  index 9 (payload offset **1**, not offset 0 as first drafted) — the 3-byte
  payload's first byte (offset 0) is some other field, not part of the mode
  encoding. Table still needs the offset-0 byte's meaning filled in.
- Firmware read (`0xC042`→`0x4042`): payload is pure ASCII, no embedded
  length byte — the string length equals the frame's own payload-length
  field. Decodes to `"1.0.1.102"`. (First implementation attempt wrongly
  assumed payload[0] was a redundant size byte and dropped the leading
  char — fixed in daemon/protocol.py after unit-testing against this exact
  captured frame.) Also confirms the earlier `0xC002` guess in this table
  was simply wrong (transcription error, now fixed above).
- Latency read (`0xC041`→`0x4041`): 1-byte payload = 0x02 (matches
  reference's `0x02`=off / `0x01`=on encoding — device currently not in
  low-latency mode).
- Gesture read (`0xC018`→`0x4018`): payload = count byte (8) + 8×
  `(device, common, type, action)` 4-byte records. All 8 decoded cleanly
  against the reference's action-code table (skip-forward on double-pinch
  both sides, skip-back on triple-pinch both sides, "Noise control" on
  pinch-and-hold both sides, "No action" on double-pinch-and-hold both
  sides) — internally consistent, structure confirmed.

## Writes: confirmed via the daemon (2026-09-10)

Through `daemon/control.py`'s `set_anc`/`set_eq` commands (real end-to-end
path: control socket → daemon → RFCOMM), against live hardware:

- ANC write (`0xF00F`, payload `[0x01, mode, 0x00]`): sent transparency,
  confirmed the earbuds' actual ANC mode changed (verified via the next
  slow-poll read, not just an ack) — the ANC payload/mode table above is
  now write-confirmed, not just read-confirmed. Reverted to off afterward.
- Write ack pattern: **every observed write produces an ack frame whose
  command ID is `write_cmd & 0x7FFF`** — same bit-clearing rule as the
  `0xC0xx`→`0x4xx` read/response pairing. Observed: `0xF00F`→`0x700F`
  (ANC write ack, 1-byte payload `0x00`), `0xF010`→`0x7010` (EQ preset
  write ack, empty payload — the value didn't actually change, which may
  explain the empty payload; needs a change-vs-no-change comparison to
  confirm). Daemon's frame dispatch now recognizes `cmd & 0xF000 == 0x7000`
  generically as a write ack rather than logging it as unrecognized.

- Latency write (`0xF040`, payload `[0x01|0x02, 0x00]`): sent enabled=true,
  confirmed the read-back flipped to `true`, ack `0x7040` with empty
  payload observed. Reverted to false afterward. Read+write both confirmed.
- In-ear read (`0xC00E`→`0x400E`) was probed but its payload does **not**
  match the reference's assumption of a single status byte at a fixed
  offset. Captured payload (19 bytes):
  `09 01 01 02 01 07 01 09 01 0a 01 0b 00 0e 01 12 01 15 01`. This reads
  more like a 9-entry `(id, value)` capability/version table than an
  in-ear boolean — the reference's `hexString[10]` (= our payload offset 2)
  happens to be `0x01` here, which is at least consistent with "in ear",
  but the surrounding structure is unexplained. **Do not trust this command
  for in-ear state without capturing it with the earbuds actually out of
  the ears to see the byte flip** — deferred, needs a controlled A/B test.

## Wear / in-case state (2026-10-20, Nothing Ear (2))

There is no live wear-state read or push. Recorded every frame for 75 s
while one bud went ear → open case → lid closed → lid open:

- Bud in ear, bud in hand, bud in an **open** case: all identical — the bud
  stays in the `0x4007` battery list with the charging bit clear.
- Lid **closed**: the bud drops out of the list (`01 02 5a`, left only).
- Lid opened again: the bud reappears. No `0xE0xx` pushes at any point.
- The case wasn't in the list during that capture, but showed up in later
  reads with both buds out and the lid open; when it reports isn't pinned
  down.
- `0xC00E` is the in-ear detection *setting* (ear-web exposes it as a
  toggle), not wear state; its payload didn't change across any of the
  above.

So "exactly one bud in the battery list" means "the other bud is in its
closed case", which is what the auto-mono feature keys on.

## Personalised ANC / Personal Sound Profile (2026-10-20, Nothing Ear (2))

Found by reading every command 0xC000–0xC0FF from the PC before and after
flipping each setting in the Nothing X app, then confirming the write from
the app's own traffic (Android HCI snoop log) and from the PC.

- Personalised ANC: read `0xC020` → payload `[enabled, 0x01]` (byte 0 is
  the setting; byte 1 unchanged in every sample). Write `0xF011 [0x00|0x01]`,
  ack `0x7011 [0x00]`. Matches ear-web.
- Personal Sound Profile on/off: read `0xC022` → `[0x00|0x01]`. Write
  `0xF015 [enabled, 0x00]`, ack `0x7015` with empty payload. Not in either
  reference. (`0xF013 [0x00]` is acked but changed nothing readable.)
- `0xC024` → 32 ASCII hex chars identifying the active hearing-test
  profile; all zeros means none saved. Choosing Softer/Recommended/Richer in
  the app changes this ID, i.e. the app computes and uploads a new filter, so
  only on/off is practical from here.

## Newer CMF models (2026-10-28, not verified on hardware by this plugin)

Taken from frames a CMF Buds 2 Plus owner captured with BudsLink
(github.com/maniacx/BudsLink, issue #14) and cross-checked against ear-web.
Only facts both projects agree on are used.

- **Pushes start `55 20`**, not `55 60`, and still carry a CRC over the
  whole frame. Byte 1's `0x20` bit flags the CRC; both forms parse the same
  way. Battery (`0xE001`) and ANC (`0xE003`) pushes carry the same payload
  as the `0x4007` / `0x401E` replies.
- **Byte 6 is the high byte of a 16-bit LE payload length.** It is 0 in all
  captured traffic.
- **Empty payload = unsupported.** Reads a model doesn't support come back
  with a zero-length payload (`0x401D`, `0x4004`, `0x4005` in the capture).
  Any parser has to allow for that. A CMF Buds 2 crashed the 0.1.x reader on
  one, most likely its reply to the personal ANC or sound profile read.
- **Model ID: `0xC01C` → `0x401C`**, 2 bytes LE (`84 b1` = B184, CMF Buds 2
  Plus). Preferred over the serial-number SKU lookup, which BudsLink found
  maps the CMF Buds 2 Plus to an Ear (1).
- **Listening-mode EQ: read `0xC050` → `0x4050` (payload[0]), write `0xF01D`
  `[preset, 0x00]`, ack `0x701D`.** Used instead of `0xC01F`/`0xF010` by
  CMF Buds 2 (B179), 2 Plus (B184) and 2a (B185). Presets: 0 Dirac (2a: 7,
  2 Plus: none), 1 Rock, 2 Electronic, 3 Pop, 4 Enhance vocals, 5 Classical,
  6 Custom. CMF Buds (B168) and Buds Pro 2 (B172/B187) are also on these
  commands, but no preset table is confirmed for them.
- **Bass boost: read `0xC04E` → `0x404E` `[enabled, level*2]`, write
  `0xF051` with the same layout, ack `0x7051`.** Five levels, on B168, B171,
  B162, B172, B179 and B184. B195/B197 use a 3-step scheme and aren't
  handled.

## Still open

1. Whether the sequence byte (header[7]) is echoed in responses/acks — not
   yet checked across concurrent requests.
2. (resolved — EQ mapping above.)
3. Whether an EQ-write ack's payload differs when the value actually
   changes.
4. (resolved — Personalised ANC above.)
5. Live wear state: none found over RFCOMM (see "Wear / in-case state").
   Would need a capture of the Nothing X app to rule out a command neither
   reference knows about. The case-battery read the app uses is also
   unknown.
6. Ring buds: deprioritized/dropped from scope (not needed by the user).
7. Ear-tip fit test (`0xF014`, payload `[0x01]`): write ack `0x7014`
   confirmed (payload `0x00`), but no `0xE00D` result push arrived within
   45s in two live trials (earbuds out-then-in, and already-seated at
   launch). Launching it alone isn't sufficient to get a result — either
   another command primes it first, it needs a companion GATT/BLE session
   the phone app also opens, or the timeout is longer than tested. Would
   need a real packet capture against the Nothing X app to resolve;
   deferred rather than guessing further against the user's hardware.
   Gesture writes also still unprobed.
8. Model identification (serial path) is hardware-confirmed only for a B155 (Ear (2))
   serial in the `SH`-prefix case. The `13`-prefix and `MA`-prefix (year
   disambiguated) branches, and every SKU-to-base mapping other than
   17–19/27–29, are taken on the two references' word alone — not verified
   against real hardware of those models.


## CMF Headphone Pro (B175)

Research checked 2026-11-07 against the current public sources below. No B175 hardware
or B175 packet capture was available; tests use synthetic packets from these layouts.

- [BudsLink model configuration](https://github.com/maniacx/BudsLink/blob/0eb4d07dcd7eafabf425d98c607e02fc9519c94b/src/lib/devices/nothingBuds/deviceConfigs/CMFHeadphonePro.js):
  B175, single battery, classic preset indexes 0/1/2/3/5, five bass levels,
  ANC off/transparency and low/mid/high/adaptive, low-latency support.
- [BudsLink protocol constants](https://github.com/maniacx/BudsLink/blob/0eb4d07dcd7eafabf425d98c607e02fc9519c94b/src/lib/devices/nothingBuds/nothingBudsConfig.js)
  and [socket implementation](https://github.com/maniacx/BudsLink/blob/0eb4d07dcd7eafabf425d98c607e02fc9519c94b/src/lib/devices/nothingBuds/nothingBudsSocket.js):
  battery device ID 0x06; the high bit indicates charging and the low seven bits give
  the percentage. Bass uses the existing 0xC04E/0xF051 commands, with level multiplied by two.
- [ear-web routing](https://github.com/radiance-project/ear-web/blob/89f69fbab8550d6b5ba8cd0c47e704a1c057ac1d/res/js/nothing_connected.js)
  independently identifies B175 as Forretress.
- [ear-web protocol](https://github.com/radiance-project/ear-web/blob/89f69fbab8550d6b5ba8cd0c47e704a1c057ac1d/res/js/bluetooth_socket.js)
  independently confirms battery ID 0x06 and ANC/latency payloads, but routes B175 EQ
  through listening-mode reads/writes (0xC050/0xF01D), contrary to BudsLink's classic
  commands (0xC01F/0xF010). Its B175 page loads eq_espeon.js, whose buttons send
  listening-mode commands. Its shared bass implementation does not include B175.
  Therefore bass support is based on BudsLink, not independent agreement.
- [ear-web B175 page](https://github.com/radiance-project/ear-web/blob/89f69fbab8550d6b5ba8cd0c47e704a1c057ac1d/res/MainControl/MainControl_forretress.html)
  uses different labels/indexes: Pop 3, Rock 1, Electronic 2, Vocals 4, Classical 5,
  Custom 6. Dirac 0 is hidden on that page and is not offered by this implementation.

Implementation: probe both EQ families with read-only commands on each headphone poll.
Only one recognized response enables that family and its own preset table; missing,
invalid or ambiguous replies hide EQ and reject preset writes. No writes are sent as a
probe. The selected family is cached per MAC for subsequent explicit preset writes.
Bass stays hidden unless a valid bass response is received. Personal ANC and sound-profile
reads are omitted for B175. A dedicated single-battery field and headphone icons are used
on the panel, bar and desktop widget, and single-battery devices cannot trigger auto mono.

Unknown firmware, simultaneous responses from both EQ families, and features such as
spatial audio, custom EQ editing, gestures, and the physical bass/treble slider remain
unverified or outside this plugin's controls. Existing diagnostics retain raw malformed
replies for follow-up if testing on real hardware reveals a mismatch.

Validation: `python3 -B -m unittest discover -s tests` covers synthetic B175 replies,
EQ family selection and refusal, name fallbacks, single-battery pushes, malformed bass,
and the outgoing ANC/latency/bass payloads. With `lua` installed, it also runs mocked
panel/bar/desktop rendering and auto-mono checks. These do not replace hardware testing.
