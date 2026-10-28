# Fast-blit: lossless, partial-update screen protocol for the stock Sovol/TJC screen

Goal: mirror KlipperScreen (Xvfb in Docker) onto the stock `TJC4827X243` screen (AiHmiT7, Cortex-M4 @ 200 MHz,
480x272 RGB565) **without reflashing the screen**, lossless (no JPEG), able to update only part of the screen,
fast enough for a usable UI. Delivered by an SD-boot image (`TFWriter_AiHmiT7.bin.make`) that wraps the *stock* plain
firmware (`app_10000_plain.bin`) and patches it in RAM with a few hooks. Flash is never touched.

Status (2026-10-23): works end-to-end on hardware. KlipperScreen is mirrored, touch works (tap -> panel switch
verified), Nanachi replaces the stock Sovol splash, ~8x lower latency and ~10x higher throughput than the
per-rectangle first version. See `test-bench.md` for the hardware loop and the traps found on the way.

Files (all under `ext/TFTTool/tools/` unless noted):

| file | role |
|---|---|
| `fastblit_fw/fast_blit_hook.c` | all injected C code (receiver, `blitrle`/`reboot`/`magenta`/`dumpbit` commands, `show_hmi_pic` hook) |
| `fastblit_fw/{trampoline,reboot_trampoline,boot_trampoline,hmi_trampoline}.S` | hand-written Thumb trampolines (see "Hook sites") |
| `fastblit_fw/build_patch.py`, `encoders.py` | lays out + patches the combined image (Thumb-2 BL/MOVW/MOVT encoders, validated against capstone) |
| `fastblit_fw/build.py` | one-shot build: assemble, compile, patch, `fw_pack.py sdboot` -> `TFWriter_AiHmiT7_fastblit.bin.make` in the repo root |
| `fastblit_fw/nanachi.rle` | embedded 480x272 Nanachi picture in the wire RLE format (~170 KB) |
| `deploy.sh` | relay cycle -> framed `twfile` of the image to `sd0/` -> relay cycle -> `reboot` detector |
| `screen_fastblit.py` | host: `FastLink`, `FastBridge`, `ReconnectingXSource`, latency test |
| `bench_ks.py` | tap-to-picture benchmark against the KlipperScreen Xvfb |
| `ks_docker/` | KlipperScreen in Docker (Xvfb 480x272 on TCP 6099) |

`build_patch.py` reads `/Users/zed/projects/3d/sovol/screen/app_10000_plain.bin` (absolute path, stock plain firmware,
must be 0x33C1C bytes) and the `.bin` trampolines in its own directory; run it through `build.py`.

## Wire protocol

Two steps per batch, both over the normal ASCII/`twfile` serial channel (115200 default, 921600 supported):

1. **Stage:** framed `twfile "ram/z",<len>` (the stock 4082-byte frames with CRC, `0x05` per frame, `0xFD FF FF FF` at
   the end). The hook recognizes the reserved name (the firmware's temp path becomes `ram/z.tm`) and copies the
   payload into a 64 KB SCRATCH buffer at `0x400000` instead of writing a file. The last 4 bytes of SCRATCH hold the
   received length (`LAST_LEN`), so payloads are limited to 0xFFFC bytes.
2. **Draw:** the ASCII command `blitrle` (exact text, 7 letters, see "Command names"). It draws every record in
   SCRATCH and presents each rectangle.

Payload = records back to back; each record:

```
u16 x, u16 y, u16 w, u16 h            (little endian)
then RLE tokens (u16 count, u16 rgb565) covering exactly w*h pixels, row-major, runs may wrap rows
```

- A token never spans two records (host RLE is per rectangle). The firmware splits runs at row ends itself.
- A record with `w==0`, `h==0` or `x+w>480` / `y+h>272` ends the batch (guard against garbage).
- Worst case is 4 bytes/pixel, so the host splits rectangles into row bands of at most 14000 pixels
  (`MAX_BAND_PIXELS`) and batches of at most 60000 bytes (`MAX_BATCH_BYTES`).
- The host sends small rectangles first as their own ~1200-byte batch (`FIRST_BATCH_BYTES`, ~13 ms on the wire) so the
  visible reaction to a tap appears early, then the rest.
- No barrier between "draw" and the next stage: the stock receiver answers the next `twfile` with `0xFE` only after it
  has worked off the previous command, so the next `twfile` is its own barrier.

Performance model: ~92 KB/s at 921600 (link-bound), ~11 KB/s at 115200. Small rectangles (700-900 bytes) take
12-24 ms end to end; a whole KlipperScreen panel switch (~40 KB) ~0.45 s.

## Firmware: what the image does

Image layout: stock plain firmware (0x33C1C bytes) + appended trampolines, C hook code, boot trampoline (now unused),
Nanachi RLE, reboot trampoline, hmi trampoline. `fw_pack.py sdboot` wraps it with a start stub (copy to RAM, VTOR=0,
jump). The stage-0 loader reads at most `0x60000` bytes (393216) into RAM at `0x80000`; the current image is
~0x5DA0E (383 502) bytes — **only ~9.7 KB of headroom**; the Nanachi RLE is 170 KB of it.

### Hook sites (all patched with `B.W`/`BL` into appended trampolines)

| site | patched instruction | trampoline | C function |
|---|---|---|---|
| `0x5538` `sub_5538` prologue (twfile packet handler, main-loop case 3) | `B.W` (link=False) | `trampoline.S` | `fast_blit_hook()` — receiver |
| `0x2A5A` in `sub_2898` (top-level ASCII parser, the `get_StringC(&name, strings53, 53, 3)` call) | `B.W` | `reboot_trampoline.S` | `ascii_command_hook(name)` — then the real `get_StringC` is called, so every command also falls through to the stock parser |
| `0x1B8AC` `show_hmi_pic` prologue (draws every built-in picture) | `B.W` | `hmi_trampoline.S` | `hmi_pic_hook(phdr, rle, len)` |
| `0x2B21A` early boot (`bl sub_F9DC`) | — | `boot_trampoline.S` | **disabled**: the old Nanachi draw ran before the stock splash and was painted over |

**Rule (cost a lot of time):** patching a function's own prologue, reached by fall-through, must use `B.W`
(link=False). `BL` clobbers LR with the trampoline's return address and the early-return path then returns into the
vector table. Use `BL` only when replacing a genuine call site. `hmi_trampoline.S` replays the displaced
`push.w {r0-r3,r4-r8,sb,sl,fp,lr}` itself, keeps the stack 8-byte aligned for the C call (`sub sp,#4`), reads the
7th argument (`phdr`, stack arg) at `[sp,#64]`, and on "handled" does `movs r0,#1; add sp,#16; pop.w {r4-r8,sb,sl,fp,pc}`.

### Receiver (`fast_blit_hook`)

Runs in the `sub_5538` context for `byte_77F448 == 4` (file transfer) and path `ram/z.` only; everything else returns 0
and the stock code continues untouched. It must **replay the stock framed-transfer prologue**, because it sits in
front of it:

- `if (byte_77F449 == 1)` (CRC-framed): frame id check (`word_77F446` vs `word_77F44E`; duplicate -> ack 5, out of
  order -> nak 4, both with `sub_26404(x, 0)` and `byte_77F4E9 = 0`), then strip the trailing checksum from
  `cnt_77F444` (`n = byte_77F44A >= 10 ? 4 : 2`) and verify it with `cksum` (`0x94C4`, thumb `0x94C5`).
- copy `min(cnt, filesize-off)` bytes into `SCRATCH+off` (`off = dword_77F43C`), clamped to the buffer.
- `dword_77F43C += cnt`; if still short: `sub_26404(5,1)` (sends `0x05`, bumps the frame counter, zeroes `cnt`),
  and **`byte_77F4E9 = 0`** (otherwise the main loop re-dispatches the same packet forever);
- on completion: `sub_16DB8(&dword_762254)` (close the temp-file handle — skipping it makes every later transfer fail
  with `0x06`), `LAST_LEN = filesize`, `byte_77F4E9 = 7`, `sub_3F28(253)` (send `0xFD`), `sub_4160()` (the `FF FF FF`).

Facts that were wrong at first and are now fixed:

- `ptr_7612A8` is a **pointer variable** (`int *ptr_7612A8` at `0x7612A8`); the packet data lives at
  `*(u32*)0x7612A8`. Copying from `0x7612A8` itself gave garbage in SCRATCH while `LAST_LEN` looked right.
- The emulation tests (below) placed data at `0x7612A8` directly and therefore did not catch it.

### `blitrle` and drawing

`blit_rle()` walks tokens and calls `sub_12104(x,y,w,h,color)` (the firmware's own fill primitive, address `0x12105`
with the Thumb bit) per run, split at row ends. `sub_12104` only writes the *back* framebuffer (`dword_760004`);
`sub_1D88` (`0x1D89`) is the "present": gated on `byte_77F4CC != 255 && byte_77F4EB == 1 && byte_77F4CC != 1`, swaps
`dword_760004`/`dword_762108`, calls `sub_11878` (the blitter), swaps back. `blitrle` forces `byte_77F4EB = 1`, fixes
`byte_77F4CC` (1 or 255 -> 2), executes `cpsie i`, and presents each rectangle. `sub_11878` ends in
`sub_1e9a8`, which for rows >= 4 px programs the DMA2D at `0x40024000` and polls ISR bit 1 (TCIF) — plain hardware
busy-wait, completes by itself.

Drawing from the twfile-completion context (`sub_5538`) never becomes visible, whatever is called there; drawing from
the ASCII-command context does. That is why the protocol is two steps (stage in the receiver, draw in a command).

### Command names

The parser hands the hook the command word in an 8-byte stack buffer (`sp+0x18`) and only for words of
**5-8 characters**; 3-4 letter names (`blit`, `dbg`, `chk0`, `exec`) never matched. The buffer is **not** zero-padded
beyond the word, so compare only the known characters (prefix match; `rebootx` also reboots). Our commands fall
through to the stock parser, so the host still gets `invalid instruction` for them — that reply does **not** mean the
hook missed. Current commands:

- `reboot` — writes AIRCR (`0xE000ED0C = 0x05FA0004`, SYSRESETREQ): real CPU reset, no reply. Doubles as the detector
  for "patched image is running" (stock answers `invalid instruction`).
- `blitrle` — draw the staged batch (above).
- `magenta` — fixed full-screen fill + present (regression check).
- `dumpbit` — renders SCRATCH bytes 0-5 and `LAST_LEN` (low 2 bytes) as rows of white squares (MSB left, red row
  marker, centered so the camera crop keeps them). `CALL_SEND` from the command context is not trusted (see
  test-bench "dead ends"), so this is the readback that works.

### Nanachi replaces the Sovol splash

The stock splash is picture id 0 (480x272, 16274 bytes). Every picture draw goes through `show_hmi_pic(x,y,w,h,a5,a6,phdr)`
(`0x1B8AC`); `phdr` is a 24-byte RAM copy of the picture table record (`+4 id, +8 offset, +12 w (u16), +14 h (u16),
+16 data_size`). `hmi_pic_hook` matches `w==480 && h==272 && size==16274`, draws the embedded Nanachi RLE instead via
`blit_rle(0,0,480,272,...)` and returns 1 (handled). Works on a stock, untouched flash. Confirmed by camera: after
the ~4 s black boot Nanachi appears and stays (25 s watched), Sovol never shows.

## Host side (`screen_fastblit.py`)

- `FastLink(Link)`: connect (finds a screen left at the fast baud and brings it back to 115200), `bkcmd=0`,
  `tsw 255,0`, `sendxy=1`, baud switch, **warm-up** (the first `twfile` command after a baud switch is garbled by the
  bridge: burn it on a header-only upload), `send_batch()` (up to 3 tries, `resync()` between), `resync()` = bare
  `FF FF FF` only. **Never send `TWFILE_EXIT` to a receiver that is not mid-transfer** — it sent the hook into an
  endless `05` loop. `Link.upload` already sends the EXIT frames itself when an ack fails mid-transfer.
- `FastBridge(Bridge)`: grab -> `changed_rects` (cost model patched to `0.1 + 0.004*w*h` ms: only the 8-byte header
  is saved by merging) -> bands -> batches (small first) -> send. Failure after retries sets `prev=None` (full redraw).
  No CPU throttle (`DEFAULT_CPU_BUDGET = 1.0`; the old 10% budget stretched the interval up to 2 s), loop sleep 1 ms.
  `--click` (off by default) beeps on touch press — see test-bench, suspected power dips.
- `ReconnectingXSource`: KlipperScreen exits on some errors (e.g. panel `network`: `No module named 'sdbus_block'`) and
  Docker restarts the container, which kills Xvfb; the source reconnects (up to 60 s) and forces a full redraw.
- Touch: stock `sendxy` frames (press/release, release repeats press coords) + `tch0`/`tch1` polling while a finger
  is down, injected into X via XTEST. Screen touch is physically the stock panel; `tsw 255,0` disables the stock
  widgets' own handling. A page change resets `tsw`.
- SIGTERM is turned into KeyboardInterrupt so `kill`/`pkill` still restores the screen to 115200. If a run is killed
  hard the screen stays at 921600; the next `FastLink.open` finds and restores it.
- `--debug-page` logs `dp` (current page id) after every touch release.

Run: `DISPLAY=127.0.0.1:99 python3 screen_fastblit.py --port /dev/tty.usbmodemXXXX --source x` (default 921600).
Static image: `--source Nanachi_480.png`. Latency test: `--latency-test 50`. The Docker KlipperScreen needs
`ks_docker/.env` with `MOONRAKER_HOST`; `entrypoint.sh` sets `use_dpms: False` and `screen_blanking: off` (without
the latter KlipperScreen blanks after 1 h idle, the mirror goes black and KlipperScreen even sends
`machine.device_power.off` to Moonraker).

## Measurements (`bench_ks.py`, 921600 baud vs the first 115200 per-rectangle version)

| metric | before | after |
|---|---|---|
| pipeline lag: changed frame captured -> first batch on the screen | ~0.25 s | ~0.031 s |
| panel switch (~40 KB) fully sent | ~4.5 s | ~0.45 s (link-bound) |
| tap -> first pixels (incl. KlipperScreen's own ~66 ms, 50 ms of it the test's press->release hold) | 0.32 s | 0.085 s |
| small rectangle (700-900 B) | 35-47 ms | 12-24 ms |

KlipperScreen keeps repainting for 3-4 s after panel switches (animations, graph): that is source activity, not
pipeline lag, and made naive "time until idle" metrics misleading. Photographic content compresses badly with RLE
(Nanachi: 170 KB, ~2.5 s at 921600, ~16 s at 115200); UI content is ~0.3 B/pixel.

## Open items / ideas

- Emulation tests (`test_hook.py`, `test_integration.py`, Unicorn, in the old session scratchpad, not in the repo) are
  stale: they place receive data at `0x7612A8` directly, use the old `blit` name and the single-rectangle format.
  They should model `*(u32*)0x7612A8`, the framed prologue, the 7-char names and batched records.
- Better codec (palette/literal runs, 2D) would cut bytes further but needs firmware changes and the image is within
  ~10 KB of the loader's 0x60000 cap. Project constraint: the custom boot logo must never be compressed or degraded to
  save space — if room is needed, extend the file/loader budget instead.
- Pixel-level (not 16-px block) diffing would save bytes for small text updates.
- `beep` click: the buzzer exists but ignores the duration; see test-bench for the power-dip suspicion.
- KlipperScreen panel `network` crashes the container (missing `sdbus_block`); hide the panel or add the module.
- `exec`-style "run uploaded code" was abandoned: its first tests hung because of the `--raw` twfile problem (see
  test-bench), so "SCRATCH is not executable" is **unproven** either way.

---
See also: [commands.md](commands.md) (serial command set + the Ender Pearl checksum-wall / magic-string-reset corroboration), [porting.md](porting.md) (boot chain, app startup/RLE layout, DOOM and OS budgets), [flash_layout.md](flash_layout.md) (what is where in flash) and [test-bench.md](test-bench.md) (relay/camera/bridge bench, deploy loop, traps and dead ends).

## External reference: Ender Pearl display project

`ext/similar_projects/ender-pearl-display/` is a custom firmware + UI for a Creality Ender-3 V3 SE display
(`TJC3224T132_011N`, 240x320). Same TJC/Nextion protocol family as this screen but opposite execution: an external
Raspberry Pi draws every frame onto a TJC display SoC, whereas this project runs a full bootloader on the screen's own
SoC. Not a code dependency — see `SIMILARITY_REPORT.md` for the full comparison. Worth reading for:

- **`docs/03-custom-firmware.md`** — complete `.tft` build + `whmi-wri` flash workflow, the model-match check, and
  back-to-stock via SD card. Explains the *why* behind `screen_probe.py --flash`.
- **`docs/04-drawing.md`** — the "glass look" technique (3× wallpapers, `xpic` panel crops, `xstr sta=0` text), the
  `bkcmd=3` / ≤6-in-flight flow control that avoids `0x24` overflow, and the draw-only-what-changed rule that stops
  value updates from blinking.
- **`docs/07-troubleshooting.md`** — symptom→cause→fix table; extras beyond `screen_probe.py` (dead buzzer, Wine
  `.NET` errors, systemd ordering cycles).
- **`design/MENUS.md`** — full screen-by-item spec, forward-looking reference if a menu system is built.
