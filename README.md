# Nanachi

![Nanachi](Nanachi.png)

A framework for TJC / Nextion-family touch-and-display panels (the AiHmiT7 line, e.g. the
SoVol SV08MAX `TJC4827X243` 800×480). Two independent things ship here:

1. **Stage 0 bootloader** — `stage0/`. A drop-in replacement for the panel's firmware that boots
   from an SD card, validates the image, and can hand off to stock firmware. See `stage0/README.md`.
2. **Screen tools** — `tools/`. Python utilities for the firmware container format, the TJC `.tft`
   checksum/instruction tables, and two host-side screen-mirroring approaches for KlipperScreen.

`kitchen/` is scratch space (KlipperScreen-bridge work, build artifacts); it is git-ignored and not
part of the framework.

## Layout

- `stage0/` — bootloader source (loader.c, assembly trampolines, build scripts, docs)
- `tools/` — publishable Python tools (see below)
- `kitchen/` — git-ignored scratch: KlipperScreen bridge, fast-blit firmware build, test images
- `TFWriter_*.bin.make` — reference firmware images for the SD-card loader
- `nanachi_raw.rgb565` — reference framebuffer blob

## Screen tools (`tools/`)

Flat CLI scripts. Run them from inside `tools/`, or import as a package (`tools.screen_*`).

| Tool | Purpose |
|------|---------|
| `fw_pack.py` | Build the loader's container-format image and the `TFWriter_*.bin.make` SD file |
| `fw_tables.py` | Extract instruction tables from a plain (unscrambled) firmware image |
| `fw_unscramble.py` | Unscramble a firmware image; provides the container CRC helpers |
| `hmi_extract.py` | Extract embedded resources from a TJC `.HMI` project source |
| `screen_probe.py` | Probe the serial link, flash `.tft` files, baud-rate stress test |
| `screen_bridge.py` | Older mirror approach: JPEG + `exp0`/`ref` (needs `PIL`) |
| `screen_fastblit.py` | Newer mirror approach: RLE fast-blit via the firmware hook (needs `numpy`) |

### Invocation

Scripts with no relative imports run directly:

```bash
cd tools
python3 fw_pack.py --help
python3 fw_tables.py image.bin
python3 hmi_extract.py -i project.HMI
python3 screen_probe.py --port /dev/cu.usbmodemXXXX scan
```

`screen_fastblit.py` and `screen_bridge.py` use package-relative imports, so run them as modules
from the parent directory:

```bash
python3 -m tools.screen_fastblit --port /dev/cu.usbmodemXXXX --source x
python3 -m tools.screen_bridge  --port /dev/cu.usbmodemXXXX --source pic1.jpg pic2.jpg
```

### Dependencies

- `pyserial` — serial link (`screen_probe.py`)
- `PIL` (Pillow) — `screen_bridge.py`
- `numpy` — `screen_fastblit.py`
- `TFTTool` — the sibling library at the workspace root, imported by `screen_probe.py --yes-flash`
  for `.tft` checksum verification before flashing

Install the host-side extras with:

```bash
pip install pyserial pillow numpy
```

## Firmware reference images

`TFWriter_AiHmiT7.bin.make` (and the `fastblit`/`sdtest`/`poc_fill`/`stock` variants) are the
container-format images the stage 0 loader reads from a FAT SD card. Regenerate with
`python3 tools/fw_pack.py` (see `stage0/README.md`).

## Docs

Detailed notes on the firmware, protocol and hardware:

- [`docs/flash_layout.md`](docs/flash_layout.md) — 16 MiB SPI flash layout, the container/XOR/CRC scheme, how the pieces were dumped and cut out.
- [`docs/fastblit.md`](docs/fastblit.md) — lossless partial-update screen protocol, firmware hooks, host tools, measurements.
- [`docs/commands.md`](docs/commands.md) — every serial command and system variable this firmware knows, tagged with confidence.
- [`docs/porting.md`](docs/porting.md) — porting guide (FatFs, SD on SPI, UART buffer).
- [`docs/test-bench.md`](docs/test-bench.md) — unattended hardware loop (USB relay, camera, ESP32 bridge), serial traps, dead ends.
- [`docs/widget_map.md`](docs/widget_map.md) — page-to-widget map joined from the stock `.tft` and the client source (`docs/widget_map.py`).
