# Porting to the T7: running other things on the panel (DOOM, an OS)

Two estimates of what else can run on the `TJC4827X243` (AiHmiT7) besides the stock HMI.
Built on the forensics in `flash_layout.md` / `fastblit.md` and on the sources of the ports themselves
(`ext/nRF52840Doom`). Numbers are measurements, not marketing.

## Platform (the facts both estimates rest on)

| resource | value | source |
|---|---|---|
| CPU | Cortex-M4 (ARMv7E-M, Thumb-2 only), 200 MHz | wiki (main-controller frequency: 200 MHz, all X2 models), firmware is Thumb |
| MMU | none (v7-M architecture); the M4 also has no HW caches | architecture |
| RAM | **8 MB at `0x0`** (stock uses it: `SP = 0x800000`, bss to `0x76212E`, framebuffers heap-allocated) + a second bank at `0x20000000` (ROM boots the stage-0 loader there, `SP = 0x20000680`) | stock image |
| wiki's "512K runtime memory" row | the HMI app memory quota, **not** physical RAM | |
| flash | 16 MB FM25Q128AI3, XIP at `0x10000000` (controller `0x40001000`, RDID `0x90`), status register `0x00` (nothing protected) | `flash_layout.md` |
| peripherals | SPI `0x40003060` (SD card on SPI; the **loader carries its own FatFs**: "FAT32" string, long names, CP437), DMA2D `0x40024000` (display blit), UART (HMI serial, 4 KB buffer per wiki), touch controller, buzzer (PWM, the only audio), EEPROM 1 KB (wiki), **no RTC** (wiki: none), no Ethernet/WiFi, GPIO ≤ 8 (FPC variants may have no breakouts) | decompilation, wiki |
| display | 480×272 RGB565; stock: double buffer in RAM + DMA2D blit (present = swap + `sub_1E9A8`); the panel interface itself (RGB LCD controller vs SPI) is not identified in the decompilation | `fastblit.md` |

The SoC's **name is not published anywhere** (not in the wiki, not in the firmware strings): every driver
exists only as decompiled stock code (`loader.c`, `app_10000.c`).

### Boot chain (and what we control of it)

1. Mask ROM (unknown) reads the descriptor at flash `0x0`:
   `3, 0x10000000, 0x100, 0x02000000, 0x10004000, 0x7000, 0x20001000, 0x10010000, 0x60000` —
   copies the loader (flash `0x4000`, `0x7000` bytes) to RAM `0x20001000` and jumps.
2. Stage 0 (runs from `0x20000000`): tries SD first (fixed filename `TFWriter_AiHmiT7.bin.make` → RAM
   `0x80000`, at most `0x60000` bytes), otherwise the flash image at `0x10000` (A/B). Container check,
   unscramble, copy (flash path: payload → RAM `0x800`, 0x800-byte header → RAM `0`), `VTOR`, jump
   (`MSP = *vec, PC = vec+4`). SD-path images run in place at `0x80000` (`VTOR = 0x80000`).
3. **Stock limits**: container length `< 0xC0000` (768 KB; the check in `sub_200013D8`/`sub_20001448` is
   literally `v2[2] < 0xC0000u`), SD read buffer `0x60000` (384 KB), descriptor `0x60000` (a ROM hint /
   XIP-window parameter, semantics guessed).
4. **Everything is rewritable without JTAG**: the NOR is unprotected and the stock app already writes flash
   from SD (A/B update flow, provisioning `sub_212A0`) — so an SD-boot image can rewrite the descriptor
   (`0x0`), the loader (`0x4000`), and any other region. XIP is proven for *data* (`.tft` resources are read
   from the window); code XIP is capable but unused by stock (it copies to RAM); single-line SPI NOR, assume
   a few MB/s — fine for a shell/filesystem, marginal for a game (games should live in RAM).

Boot contract for a flat binary (used by DOOM and by the OS alike): linked at `0x0` (flash path) or
`0x80000` (SD path), vector table first, SP in the first dword, `tools/fw_pack.py` container. No stub needed.

App startup (inside the app image, all statically verified):
vector table @`0x0` (SP=`0x800000`, reset=`0x349`) → `reset_handler` → `clock_init` (RCC `0x40000180`,
wait lock bit 4) → thunk `0x268` → `init_table_runner` (`0x270`). The runner reads a 2-pointer table at
image `0x29C` (dwords `0x32B9C`, `0x32BBC`, ADR-relative → `0x32E38`/`0x32E58`); the actual records are
the last 32 bytes of the code+static region: rec1 `{src 0x32E58, dst 0x760000, len 0x20D0, fn 0x2A4}` =
RLE-unpack `.data`; rec2 `{src 0x33C1C, dst 0x7620D0, len 0x3B368, fn 0x300}` = bss clear (16-byte
memset chunks). Dispatch (`ldm r10!,{r0-r3}` / `subne r3,r7,r3` / `orr r3,r3,#1` / `bx r3`, with
`r7 = first_record_addr - 1`) lands on the record `fn` targets `0x2A4` / `0x300`.
The RLE body is at `0x2A4` (IDA's function start `0x29C` overlaps the 8 pointer bytes). RLE format:
header H; literal count `L = H&7` (0 → next byte) meaning **L−1** literal bytes; flag `F = H>>4`
(0 → next byte); then the literals, then either a backref (`H&8`: 1 offset byte, copy `F+2` bytes
from `dst−offset`, overlapping) or `F` zero bytes. Max runs: 6 literals inline (254 extended),
15 zeros, 17 backref bytes.
After record 1, the runner does `sub.w lr, pc, #9` → LR=`0x281` (IDA misdecodes that word as `adr.w`);
control lands at hand-assembled glue `0x281..0x299`, which falls over the 8 pointer bytes and
re-enters the RLE body at `0x2A4` — that `0x281→0x2A4` path is one-way, so the record loop is never
re-executed: record 2 (bss clear) is reached through the re-entry, not a second dispatch.
Then `startup_tail` (`0x328`): `init_boot_struct` (zero 64 B at `0x79D3D8`) → `fpu_init_stub`/`fpu_init`
(VMSR FPSCR `0x03000000`) → `main` (`0x2B0C0`).

---

## Part 1 — DOOM (the nRF52840 "next-hack" port)

### Budgets (all fit)

| item | nRF port | T7 |
|---|---|---|
| image (code + .data) | 255,527 B (`0x3E627`; hex forensics: last nonzero byte of the flat image at `0x3E626`) | < 384 KB (SD) / 768 KB (flash) — fits |
| bss | 238,479 B (staticZone 113,600 + displayData ≈ 116,200 + openings/clips 8,640; matches the zero section of the hex) | fits |
| total RAM | ≈ 494 KB + stack/heap (~30 KB) | 8 MB — 6% of it |
| CPU | 64 MHz @ 240×240 | 200 MHz @ native 480×272: 3.125× clock ÷ 2.267× pixels ≈ **0.725× the nRF's load** → 30+ fps realistic |
| WAD | XIP from external QSPI NOR (`0x12000000`, 4-byte length prefix, WAD offset 4) | XIP from the same NOR (a free region, e.g. `0x200000..`) or an SD file (loader's FatFs) |

WAD flash budget: 16 MB − app block (`0x10000`) − `.tft` (10.3 MB, deletable for a DOOM/OS build) ≈
**14.7 MB** → full DOOM2 ≈ 14.6 MB (tight), DOOM1/Ultimate ≈ 4–5 MB (comfortable).

### What to cut / replace (from the port's `main.c`)

| nRF part | T7 replacement |
|---|---|
| `qspiInit` (WAD XIP via the QSPI controller) | T7 flash controller (XIP window) or SD + FatFs |
| `initDisplaySpi` (SPIM easyDMA, 8bpp→16bpp conversion) | stock present path: back buffer in RAM → DMA2D (`sub_1E9A8`); render at native 480×272 8bpp (cost ≈ nRF 240×240) |
| `usb` / `usbCdc` / `ymodem` (WAD upload) | SD card, or `twfile` @ 921600 (~16 MB ≈ 3 min) |
| `pwm_audio` + wireless audio protocol | the buzzer, or off |
| wireless gamepad (Wii-remote-like) | panel touch (stock touch driver) — on-screen d-pad + fire buttons |
| `timerInit` (TIMER2/3 + PPI chain) | a GPTimer / SysTick (peripheral to be located) |

**Verdict: realistic.** RAM/CPU/flash are not the constraint (the port was built for 332 KB flash / 256 KB
RAM; we have 16 MB / 8 MB). The work is the porting itself: display driver, WAD I/O, input, audio cut.
Boot contract = the stock one (flat binary + container + loader jump).

---

## Part 2 — an OS (Linux / BSD / a "router-with-busybox" box)

### What can run on an MMU-less v7-M

| system | status | notes |
|---|---|---|
| **Zephyr** | first-class | v7-M is a main target: devicetree, shell, FatFs/littlefs, a POSIX layer (pthreads/termios/socket), LwIP, MTD flash API. Easiest bring-up |
| **NuttX** | first-class | the most "router-like": a real **busybox** port, POSIX, **nxffs/elfffs on SPI NOR**, FatFs, LwIP |
| **FreeRTOS + FatFs + LwIP + own shell** | fine | minimal framework, full control |
| **mainline Linux (nommu)** | works, niche | `CONFIG_MMU=n` for arm on v7-M/v7E-M. Proof: **jserv/cortexm-linux** (maintained, 2026) — mainline kernel 7.0 + BusyBox 1.37 + uClibc-ng 1.0.57, **FDPIC** ELF, a bootwrapper that supplies the vector table and jumps to the kernel — the *same contract as our loader*. Measured there: busybox ≈ 113 KB, rootfs ≈ 341 KB. Quirks: no `fork` (vfork/posix_spawn only), no address-space isolation between processes, a special toolchain (`arm-uclinuxfdpiceabi`) |
| **uClinux (classic)** | proven | the historical nommu Linux: LPC1788 (M3), STM32F2, Kinetis K70 (**M4 @ 120 MHz**, 16 MB) |
| **FreeBSD / NetBSD / OpenBSD** | none | every arm port needs an MMU (uvm); no v7-M port exists. Writing one is a research project |

### Budgets (all fit with room)

- minimal Linux (kernel + initramfs rootfs) ≈ **0.8–1.5 MB** — 10–18% of the 8 MB;
- Zephyr / NuttX+busybox: 0.3–1.5 MB;
- code: RAM copy at boot (the loader already copies; 8 MB available) or XIP from the NOR;
- storage layout (classic router one): **read-only rootfs on the NOR** (romfs/cramfs over MTD / XIP) +
  **writable data on the SD** (FatFs);
- a zstd-compressed image ≤ 384 KB fits the stock SD path without any loader patch.

### "Router" reality

- **No network controller in the SoC** (no Ethernet/WiFi; wiki: none) → the box is a **serial console**
  (UART, 921600) + NOR + SD. To make it a *real* router: an ESP8266/ESP32 module on a spare UART, LwIP
  over it.
- No RTC → time from a GPTimer (or from the ESP module).
- The DMA2D framebuffer can host a framebuffer terminal (st/hterm-like) or a small GUI on the panel.

### Drivers: known vs. to be found

| driver | status |
|---|---|
| flash controller (MTD: read/erase/write + XIP window) | behaviour known (loader: RDID `0x90` + size table; stock app: A/B update + provisioning writes); register map from the decompilation |
| SD on SPI (FatFs) | the loader carries a complete driver — extract it |
| display (DMA2D blit) | stock path known (back/front buffers + `sub_1E9A8`); **the panel interface is not identified** (RGB LCD controller vs SPI) |
| UART (console) | stock uses it (4 KB buffer) |
| touch | controller exists (calibration "Touch Just", type `0x0002` in dataModel); register map to be found |
| clocks (200 MHz PLL) | the loader sets them before the jump — the OS inherits a running system |
| buzzer PWM, GPIO, GPTimer | exist; registers to be found |
| **SoC part name / datasheet** | **not found anywhere** — the single biggest bring-up cost |

### Tiered plan (rough effort)

| tier | what | effort |
|---|---|---|
| 0 | own SD-boot C supervisor: shell over UART + FatFs (SD) + running flat/ELF binaries; 10–50 KB | **days** (SD-boot mechanism proven — `fastblit.md`) |
| 1a | **Zephyr** board bring-up (dts + the drivers above) | **1–3 weeks** |
| 1b | **NuttX** bring-up (busybox + elfffs on the NOR + SD) — the most "router-like" | **2–4 weeks** |
| 2 | **mainline Linux** via the jserv recipe (bootwrapper role → our loader; drivers; MTD + fbdev + input) | **1–3 months** |
| 3 | a BSD port | research project, not worth it |

The risk concentrates in one place: reverse-engineering register maps (no datasheet) — mitigated by the fact
that the stock code already implements every driver and is decompiled.

### Synergy with DOOM

The OS is a natural base for DOOM: WAD in NOR XIP, framebuffer driver, touch input, and the DOOM engine as
a userspace app (FDPIC ELF under Linux; a Zephyr/NuttX app otherwise). End state: the panel is a small
computer (shell + files + games) and the HMI becomes just one of its apps.

---

## Open questions

- The SoC part name (not in the wiki, not in the firmware strings) — a datasheet would de-risk all drivers.
- The descriptor's `0x100` / `0x60000` fields (XIP window parameters?) — needs the ROM or a logic-analyzer
  boot capture (captures are in `4.txt` / `8.txt`).
- The size / enable registers of the `0x20000000` RAM bank.
- The panel interface (RGB LCD controller? its registers?).
- The touch controller type (dataModel `0x0002`) and register map.
- Whether the SoC has a USB device at all (the panel's "USB" may be a USB-UART bridge chip).

---

See also: `flash_layout.md` (what is where in the flash), `fastblit.md` (SD-boot image, the display path),
`test-bench.md` (the hardware loop).
