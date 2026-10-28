# SPI flash of the Sovol SV08 Max screen (TJC4827X243_011C, AiHMI T7)

What is where in the 16 MiB flash chip of the stock screen (Fudan FM25Q128AI3, JEDEC `A1 40 18`, 16 MiB, 4 KiB sectors).
Taken from one dump (`dump1.bin`, md5 `715f1335a2ee02334d652c0ec0428e7a`, two identical reads); every statement says
how it was found. **Confirmed** = checked by a checksum or by parsing, **read from code** = seen in the decompiled stage 0
loader / firmware, **guess** = my reading, not checked.

## Map

| Flash offset | Size | Content | Status |
|---|---|---|---|
| `0x000000` | 0x1000 | boot descriptor table (9 dwords, below), the rest zero | read from the data, meaning is a guess |
| `0x001000–0x003FFF` | 0x3000 | zero | confirmed |
| `0x004000–0x00699D` | 0x299E | **stage 0 loader**, Thumb, runs in RAM | confirmed |
| `0x00699E–0x007FFF` | | zero | confirmed |
| `0x008000–0x00FFFF` | 0x8000 | erased (`FF`) | confirmed |
| `0x010000–0x043C1B` | 0x33C1C | **main firmware, copy A** (valid) | confirmed |
| `0x043C1C–0x08FFFF` | | erased | confirmed |
| `0x090000–0x0C3C1B` | 0x33C1C | **main firmware, copy B**, same header, payload CRC **fails** (16 247 bytes differ from A) | confirmed, reason unknown |
| `0x0C3C1C–0x10FFFF` | | erased | confirmed |
| `0x110000–0x113FFF` | 4 sectors | **`dataModel` (record A, `+0x000`) and ProductId (record B, `+0x800`)**: 0x80 bytes each, 4 identical copies; the first 0x7C bytes are XORed with `15 + i`, the last dword is a checksum that includes the chip serial. A decodes to `TJC4827X243_011C`, `00 00 00 00`, `0x0431` (1073, first field of `comok`'s second item), `0x0002` (touch type), `0x012C`; B decodes to the 8 byte serial (`57 02 35 01 6C 57 72 37`) plus 28 bytes of device data | confirmed (written by the firmware, see below) |
| `0x114000`, `0x114800` | 4 bytes each | markers `0x12345678` (start) and `0x87654321` (end) around a complete dataModel write | confirmed |
| `0x118000`, `0x119000` | 107 bytes each | two copies of one plain (not XORed) block (`88 d4 61 7b 5b 31 04 72 …`, contains `E0 01 10 01` = 480 x 272 and a few signed 16 bit offsets, starts with the marker `0x88`) | guess: touch calibration (the firmware has `Touch Just` / `Touch Screen Adjust OK!`); not verified |
| `0x120000`, `0x130000` | 114 bytes (+ data up to `+0x9FF`) | A/B pair; byte `+0x11` is `80 25 00 00` = 9600 (saved baud rate) | baud confirmed, rest unknown |
| `0x140000`, `0x150000` | 0x400 (1024) bytes each | **the `repo`/`wepo`/`rept`/`wept`/`rfpt`/`wfpt` user storage area** (A/B pair, identical). Organised as 50-byte slots starting at 0, 50, 100, …, 1000; a never-written slot holds its own byte address as a 4-byte little-endian sentinel (`addr == value`), the one exception on this screen is the slot at byte 100, which holds the real value `1`. Confirmed live with `rept add,length` (streams raw bytes, exact bounds: a read that would reach byte 1024 returns nothing at all, not a partial read — this is very likely what `usize` reports) | confirmed |
| `0x160000–0x160FFF` | 0x1000 | **`.tft` header** (headers 1 and 2, tables) | confirmed |
| `0x161000–0x17FFFF` | | erased (padding inside the `.tft`) | confirmed |
| `0x180000–0x9FFFFF` | 0x880000 | `.tft` **resources**: 12 files (pictures, fonts, ...), `.tft` offset `0x20000–0x89FFFF` (`ressources_files_size` 8 912 896) | confirmed (sizes match header 1) |
| `0xA00000–0xB382BB` | 0x1382BC | `.tft` **user code, pages, objects** | confirmed (the `.tft` checksums are valid) |
| `0xB382BC–0xFFFFFF` | ~4.7 MiB | erased, free | confirmed |

The `.tft` is the contiguous range `0x160000 .. 0xB382BC` (**10 322 620 bytes**). Its end is also the last non-`FF` byte of
the dump; the four checksums (header 1, header 2, resources, file) verify only with exactly this length.

## Stage 0 loader (`0x4000`)

* Boot descriptor at `0x0` (dwords): `3, 0x10000000, 0x100, 0x02000000, 0x10004000, 0x7000, 0x20001000, 0x10010000, 0x60000`.
  The flash is mapped at `0x10000000` (XIP). Reading: the entry `0x10004000 → 0x20001000` is the loader copied to RAM,
  `0x10010000, 0x60000` is where the main image is expected (and its maximum size). *Guess*, the ROM of the chip is not
  available.
* The loader is linked at `0x20000000`; its vector table is at `0x20001000` = file offset `0x4000`.
  **File offset = address − `0x20000000` + `0x3000`** (checked by the run of ten `b .` stubs at `0x4288`).
* What it does (decompiled, `sub_20002F38`): tries the SD card first (SPI at `0x40003060`, FatFs with long names, CP437), the
  file `TFWriter_AiHmiT7.bin.make`, loaded to RAM `0x80000`; otherwise it reads the main image from the flash (XIP) to
  RAM address 0. Both go through the same container check (next section) and are started with `MSP = *0, PC = *4, VTOR = 0`.
* The flash itself has its own controller (`0x40001000`, command `0x90` reads the ids, a table of sizes by id).

## Main firmware image (`0x10000`, copy B at `0x90000`)

Container (checked by the loader, `tools/fw_unscramble.py` does the same):

| Offset | |
|---|---|
| `0x000–0x1C7` | vector table and code, XORed with K |
| `0x1C8` dword 114 | CRC of bytes `460..615` |
| `0x1CC` | `0x9F` (field unknown) |
| `0x1D0` dword 116 | length (`0x33C1C`) |
| `0x1D4` dword 117 | CRC of the image |
| `0x1D8` dword 118 | key part (0 here) |
| `0x268–0x7FF` | XORed with K |
| `0x800–length` | payload, XORed with K |

`K = dword[118] ^ dword[116]` (here `0x33C1C`, the length). CRC = STM32-style hardware CRC (poly `0x04C11DB7`, init
`0xFFFFFFFF`, 32-bit words, MSB first, no final xor); the image CRC covers the *scrambled* bytes `0..0x1C8`, `0x268..0x800`,
`0x800..length`. No signature appears in the loader, only length (`< 0xC0000`) and the two CRCs.

The unscrambled image runs at address 0 in RAM (`SP = 0x800000`, reset vector `0x349`). Its strings and tables: see
`tools/fw_tables.py` (instruction tables, undocumented functions) and the README.

How the loader picks between the two copies is not known: the code reads the same flash window for both loop passes, so
the window is probably moved by the ROM (to `0x10000` for the first attempt, `0x90000` for the second); copy B fails its CRC.

## Settings and data blocks (`0x110000–0x150000`)

Every block is written in two copies (A/B or doubled sectors), the usual way to survive a power cut. In every record the
"ramp" `d4 d3 d2 …` (a byte counter that decreases by one with the position) fills the unused part, so a record is
~28 bytes of data + a counter + 4 bytes of tail. The only decoded field is the saved baud rate (9600 in the `0x120000` /
`0x130000` pair); the firmware starts at 115200 (the startup code of the `.tft` sets it, see the notes in `tools/screen_probe.py`).

## Provisioning commands of the firmware (`sub_212A0`)
The serial command handler has three raw (non-instruction) commands:
* `HMISETPASSWORD15` + `8973` + 0x48 bytes (total 93 bytes) writes the `dataModel` (model name) and ProductId records: erases the sector at
  `17 * 64 KiB` = `0x110000`, writes 4 copies of each (A at `+0x000`, B at `+0x800` of consecutive sectors), the marker `0x12345678` at
  `0x114000`, reads everything back, and finally the marker `0x87654321` at `0x114800`. It only does this when the two serial words
  (`0x79C390`, `0x79C394`) are `0xFFFFFFFF`, i.e. for a chip that has not been provisioned; a screen with a serial ignores it.
* `rdad` / `wrad`: read / write a 13 byte structure (`stru_764EF8`, saved with the settings at `0x120000`), protected by a checksum. By the
  names of the editor (`guanggao` = advertisement, `Appfree10`) this looks like the "ad free" registration of the display (the
  hidden `registered` function); not verified.
The record checksum (`dataModel::read`) includes the chip's serial number, so a flash image copied to another screen does not pass.

## `.tft` in the flash (`0x160000`)

* The header says editor `tjc-1.66.1`, 480×272, `ui_orientation = 2` (pictures are stored turned by 180°), 91 pages,
  901 objects, 117 pictures, 4 fonts, usercode at `.tft` offset `0x8A0000` (= flash `0xA00000`).
* It is **not** the same file as `zhongchuang/…/众创klipper.tft` (Comgrow edition: editor 1.65.5, 67 pages, 88 pictures,
  orientation 0). The Sovol file contains all 67 pages of the Comgrow one plus 24 new ones (fans, network, calibrations,
  filament load / unload, chamber heater, ...); 25 old pages changed layout; 44 of the 88 pictures are pixel-identical after
  turning by 180°, ~20 are redrawn (Comgrow logo → Sovol robot, printing and filament pages).
* The screen version text lives on page 53 as plain text (`1.0.8` in this file, `V1.5.2` / `V1.0.7` in the Comgrow one); the host
  overwrites it (`curVersion` / `newVersion`). The header has only `file_version = 33` (the format) and the editor version.

## How to get the pieces out

```
dd if=dump1.bin of=firmware_a.img bs=1 skip=$((0x10000)) count=$((0x33C1C))
python3 tools/fw_unscramble.py dump1.bin app_plain.bin --offset 0x10000      # checks both CRCs, writes the plain image
python3 -c "d=open('dump1.bin','rb').read(); open('screen.tft','wb').write(d[0x160000:0x160000+10322620])"
python3 TFTTool.py -i screen.tft                                           # decodes it as any other .tft
```

For another dump the `.tft` length is the last non-`FF` byte (`max(i for i, b in enumerate(d) if b != 255) + 1 − 0x160000`);
`TFTFile.verifyChecksums()['file']` is true only for the exact length.

## How the dump was taken

* The chip is in the 8-pin SOP (pin 1 = the dimple at the top left of the package when the UART connector is at the top):
  1 CS, 2 DO, 3 WP, 4 GND, 5 DI, 6 CLK, 7 HOLD, 8 VCC. Wires were soldered to the pins (a test clip gave unreliable reads;
  the screen's own MCU also reads the flash on power-up and talks to it at the same time).
* The reads worked with the screen board **not** powered by the bench supply; the flash was most likely powered through the
  soldered VCC wire by the programmer (ESP32-S3 running ESP32-Bit-Pirate in `serprog` mode), so the screen MCU did not run
  (my reading of why it works, the supply path was not measured).
* `flashrom -p serprog:dev=<port>:921600,spispeed=500k -c "FM25Q128" -r dump.bin`, twice, `md5sum` both. 500 kHz takes
  about five minutes; 100 kHz was used for the first successful test. The chip's status register is `0x00` (nothing protected).
* The Security Registers (OTP) are not read by flashrom and are not in the dump.

## Open questions

* Fields of the settings records and the meaning of the `0x118000` block.
* Why copy B at `0x90000` fails its CRC (older firmware, an interrupted update, or damage) and which copy the loader uses.
* The boot descriptor at `0x0` and the XIP window offset, both need the chip's ROM or a logic analyzer capture of the
  boot (the capture of the MCU reading the flash at start-up is in `4.txt` / `8.txt`: `03` reads of 4 bytes from `0x6FB4` up).

---
See also: [fastblit.md](fastblit.md) (SD-boot image with the fast-blit hooks, wire protocol, firmware patch sites), [porting.md](porting.md) (boot chain, app startup/RLE layout, DOOM and OS budgets) and [test-bench.md](test-bench.md) (relay/camera/bridge bench, deploy loop, traps and dead ends).

## External reference: Ender Pearl display project

`ext/similar_projects/ender-pearl-display/` independently hit the same `.tft` checksum wall this project's
`whmi-wri` path hits (patch a picture → uploads fine → boots to "System Data ERROR!" because three 4-byte checksum
fields change with any pixel and none is a standard CRC32). They deliberately did not reverse the checksums and rebuild
in the editor instead — the same choice as here; see `docs/03-custom-firmware.md`. Their `SIMILARITY_REPORT.md` compares
this `TJC4827X243_011C` (800x480, runtime 159, 16 MB) against their `TJC3224T132_011N` (240x320, runtime 68, 8 MB):
same protocol family, opposite execution. Read `docs/04-drawing.md` for the design technique (3× wallpapers, `xpic`
panel crops, `xstr sta=0` text) that works around the display's inability to blur at runtime.
