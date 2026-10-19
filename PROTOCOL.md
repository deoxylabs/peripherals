# Protocol notes

Razer BlackWidow V4 Pro 75% (`1532:02B3`, wired) and Basilisk V3 Pro (`1532:00AB`, HyperSpeed dongle), without Synapse.

Everything here was established against the real devices. Sources:
- **Keyboard firmware.** Razer's firmware updater (v1.3.0_r2) ships the keyboard's Nordic nRF52840 application unencrypted (`nordic.hex`, app at `0x26000`). That chip is the USB device; it was decompiled with radare2 + r2ghidra. A second MCU drives the OLED; its firmware is encrypted and wasn't needed, because the Nordic only forwards to it over SPI.
- **Synapse 4's device bundle,** served at `https://apps.razer.com/synapse/products/691/mw/` (691 is the PID in decimal). The OLED encoder is in `c/6737.*.js`; the upload flow is in `rzDevice25Oled.*.js`.

## Razer reports (all devices)

Feature reports on the control interface:

| device | interface | where it comes from |
|---|---|---|
| keyboard | 3 | |
| mouse | 0 | the dongle's pointer interface |

**Open everything shared.** The dongle's interfaces 3 and 4 are HID LampArrays that never reach the mouse. Interface 0 is the pointer itself, and an exclusive open freezes the cursor.

Report layout, 90 bytes, report ID 0:

```
[0] status (reply: 2 = OK)  [1] transaction 0x1F  [5] data size  [6] class  [7] id
[8..87] arguments           [88] XOR of bytes 2..87   [89] 0
```

To read a value, send the request, then get the feature report back. The device keeps a single reply buffer that other writes overwrite, so only accept a reply whose class and id match the request.

### Lighting, class 0x0F

| id | args | |
|---|---|---|
| 0x02 | `[0, 0, 0x08]`, size 0x0C | custom-frame mode |
| 0x03 | `[0, 0, row, firstCol, lastCol, r,g,b…]`, size 0x47 | one row of a frame; never acknowledged |
| 0x04 | `[0x01, 0, level]`, size 3 | brightness, 0–255 |
| 0x80 | | matrix info; the keyboard answers `05 19 03 06 12` |

The keyboard's matrix is **6 rows × 18 columns**. Columns 16 and 17 are the right-hand nav keys, and OpenRazer's neighbouring model has 16. The mouse is 1 × 13.

Devices drop the frame they were showing (sleep, a radio drop) without any signal, and frame writes are never acknowledged. So resend unchanged frames every few seconds.

### Power, class 0x07

Get id = set id + 0x80.

| set | args | |
|---|---|---|
| 0x03 | `[seconds BE16]` | sleep after this long idle "on battery" (factory 900) |
| 0x08 | `[?, enabled]` | auto sleep |
| 0x0b | `[?, enabled, seconds BE16, percent]` | dim the lighting after idle (factory 300 s to 20%) |

A full battery reads as *not charging* (0x84 = 0), so the keyboard runs its battery timers even on the cable. Every idle timer here, and the OLED's, counts keypresses only: mouse use never resets them.

### Battery, class 0x07

| id | reply |
|---|---|
| 0x80 | `args[1]` is the level, 0–255 |
| 0x84 | `args[1]` is 1 while charging |

## The OLED (keyboard only)

- The panel is 256×64 with 16 grey levels. Home-screen content is 232×64; the right-hand 24 px is the dial's icon column.
- Pixels: grey = `floor(luma / 16)`, rows run top to bottom, two pixels per byte with the **left pixel in the LOW nibble**. Getting the nibble order wrong looks almost right, and terrible.

### Settings, class 0x17 on interface 3

A getter's id is its setter's id + 0x80.

| id | args | meaning |
|---|---|---|
| 0x0d | `[type, type]` (get 0x8d) | home screen: 0 animation, 1 image, 2 banner, 3 keyboard info, 4 emote, 5 audio, 6 system info, 7 off |
| 0x02 | `[type, 18 bytes]` | per-type parameters (below) |
| 0x03 | `[brightness]` | OLED brightness, 0–100 |
| 0x04 | `[seconds]` | time from a dial/menu screen back to the home screen |
| 0x06 | `[minutes]` | dim the OLED after this long without a keypress; **0 = never** (Synapse's "off"). Stored as seconds, so the getter 0x86 divides by 60 |
| 0x16 | `[mode, item]` | the firmware's screensaver after the OLED dims: mode 1 on, 0 off (Synapse's "No screensaver"); item picks what it shows |
| 0x09 | 40 bytes | live system-info values, RAM only (below) |
| 0x0a | `[visualiser type, 32 bar heights]` | live audio bars in pixels, RAM only: 0–64, or 0–44 with media info shown |
| 0x0b | `[volume, flag]` | volume shown for the dial |
| 0x14 / 0x15 | 6 / 10 bytes | animation / image slot enable states |
| 0x8f / 0x90 | | asset GUID / checksum queries |

**0x09 is eight fixed 5-byte slots,** not a list: item N lives at offset (N−1)×5 as `[N, data…]`. The firmware reads by position.

| id | item | data |
|---|---|---|
| 1 | CPU % | 1 byte |
| 2 | CPU temperature | BE16, then unit (0 °C, 1 °F) |
| 3 | GPU % | 1 byte |
| 4 | GPU temperature | BE16, then unit |
| 5 | memory % | 1 byte |
| 6 | date | not drawn by firmware 1.3 |
| 7 | time | `[hour, minute, second, fmt]`; fmt 0 AM, 1 PM, 2 no suffix; hour as displayed |
| 8 | battery % | 1 byte |

**Parameters for 0x02** (bytes after the type byte):

| type | name | parameters |
|---|---|---|
| 0 | animation | `[index from 1]` |
| 1 | image | `[index from 1]` |
| 2 | banner | `[image on, position (0 top), scroll (0 R→L, 1 L→R, 2 up, 3 down), image index]` |
| 5 | audio | `[visualiser on, visualiser type, media info on, position]` |
| 6 | system info | 18 bytes (below) |

System info (type 6), 18 bytes:
- bytes 1–3: one per slide, `(leftItem<<4)|rightItem`; 0 means none
- byte 4: seconds per slide
- bytes 5–6: reserved, notification mask
- bytes 7–18: per slide, `leftX, leftY, rightX, rightY`

The firmware draws the items with its own digits. They advance 12 px, so "12:59 PM" is about 84 px wide.

### Uploads, interface 5 (64-byte output reports)

Packet framing:
- **Begin:** `[cmd, 0, index, 0, wH, wL, hH, hL]`
- **Data:** `[cmd+1, len ≤ 60, seqH, seqL, data…]`, with seq starting at 0.
- **Ack:** every packet is acknowledged on the same interface as `[cmd, status]`: 1 busy, 2 OK, 3 failed, 5 unsupported.
- **Never start a packet with 0x30 or 0x31.** Those switch the Nordic into a passthrough to the display MCU's bootloader.

Images carry a 0x40-byte header before the 4-bit pixels:

| bytes | content |
|---|---|
| 0–1 | width (BE) |
| 2–3 | height (BE) |
| 4–23 | GUID (ASCII, or zeros) |
| 24–59 | zeros |
| 60–63 | BE32 sum of the pixel bytes |

| cmd | target |
|---|---|
| 0x0c | banner (height 64, or 44 with the banner image on) |
| 0x0e | audio media-info strip (height 20 with the visualiser on) |
| 0x10 | system-info slide background, index 0–2, 232×64 |
| 0x12 | home image, slot 0–9, 232×64 |
| 0x04 | animation |

**Animation (0x04).**
- Begin: `[0x04, 0, slot, frames]`.
- Slots: 0 is the power-on animation, with 256×64 frames of 0x2000 bytes. 1 is the emote, and 2–7 are home animations 1–6, with 232×64 frames of 0x1d00 bytes.
- 0x200-byte header:
  - byte 0: frame count, max 150
  - bytes 2–3: frame interval in ms (BE), 33–1000
  - bytes 4–23: GUID
  - bytes 24–27: BE32 sum of the frame bytes

**Every upload is a flash write on the display MCU.** Upload when content changes, and animate anything live through the RAM paths (0x09, 0x0a).
