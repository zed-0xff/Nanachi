# Hardware test bench and debugging notes (Sovol/TJC screen, fast-blit work)

Everything needed to iterate on the SD-boot image **unattended**, plus the traps found while doing it. Companion to
`fastblit.md` (protocol/firmware) and `flash_layout.md` (flash/loader layout).

## Bench

```
Mac ──USB──> ESP32-S3 ("Bit Pirate" firmware, UART passthrough) ──UART──> screen    /dev/tty.usbmodemDCB4D90BE2383
Mac ──USB──> KMTronic 1-ch USB relay (power of the screen)                          /dev/tty.usbserial-A60085Al
Mac ──LAN──> camera pointed at the screen (MJPEG)                                   http://192.168.1.171:8081/0/stream
Docker: ks_docker (KlipperScreen + Xvfb 480x272, TCP 6099)  <-  Moonraker 192.168.52.84:7125
```

- **ESP32 bridge:** DTR must be on; it garbles the first bytes after open and after every host baud change
  (`Screen` primes with an empty command, `_settle()` after baud changes). If it seems dead, send a bare `\r\n` to its
  port: when it is *not* in UART passthrough mode it answers with its own prompt; silence = passthrough is active and
  the screen (not the bridge) is what's silent. It can drop off USB; both ports disappearing at once
  (2026-10-23, `/dev/tty.usb*` empty, `system_profiler` shows no USB devices) means the hub/cable/power dropped and
  needs re-plugging. Do **not** open the screen port from a second process while a bridge/mirror runs
  (`device reports readiness to read but returned no data (multiple access on port?)`; it also corrupts the mirror's
  stream and causes multi-second batches).
- **Relay (KMTronic):** 9600 baud, 3 raw bytes, no framing/checksum: ON `FF 01 01`, OFF `FF 01 00`. The usual 2-byte
  `A0 01 01 A2` (LCUS) protocol and DTR/RTS toggling do nothing. A power cycle = OFF, wait 3 s, ON, wait ~10 s.
  Sending ON while already ON is not a cycle. Typical use (`deploy.sh` does it):

  ```python
  r = serial.Serial('/dev/tty.usbserial-A60085Al', 9600, timeout=1)
  r.write(bytes([0xFF,1,0])); r.flush(); time.sleep(3)
  r.write(bytes([0xFF,1,1])); r.flush(); time.sleep(10)
  ```
- **Camera:** MJPEG at ~1 fps with ~2 s latency, crops the screen edges, so Nanachi/short flashes are easy to miss
  and the extreme left/right of the screen is not visible. One frame:
  `curl -s -m 3 -o f.jpg URL; python3 -c "d=open('f.jpg','rb').read();s=d.find(b'\xff\xd8');e=d.find(b'\xff\xd9',s);open('o.jpg','wb').write(d[s:e+2])"`
  then view `o.jpg` (must be inside a readable working directory). For boot sequences, hold one connection open
  and split frames on `FFD8..FFD9` in a thread while the relay cycles. `dumpbit` (see `fastblit.md`) is the readback
  that survives the crop/blur: centered white squares per bit.

## Deploy / test loop

1. `python3 ext/TFTTool/tools/fastblit_fw/build.py` -> `TFWriter_AiHmiT7_fastblit.bin.make` in the repo root.
2. `ext/TFTTool/tools/deploy.sh`: relay cycle, **framed** `twfile` of the image to `sd0/TFWriter_AiHmiT7.bin.make`
   (`screen_probe.py upload ... --delete --repeat 1`, ~35 s at 10.7 KiB/s for ~387 KB), relay cycle, `reboot` detector.
3. Confirm the new image is really what runs. `reboot` -> **no reply** = patched image (CPU reset);
   `invalid instruction` = stock. A deploy can silently go wrong: one upload ran at 14 KiB/s instead of 10.7 and the
   board behaved like an older build. Check behavior (e.g. a 2-frame upload acking `FD`) before debugging code.
4. Test through the mirror/bench and look at the camera.

The loader keeps `TFWriter_AiHmiT7.bin.make` across boots (it is **not** consumed/renamed). The loader only needs a FAT
SD card in the slot next to the flash chip. Flash is untouched; `screen_probe.py flash` of the stock `screen_flash.tft`
restores a clean flash state if ever needed (needs `--yes-flash`; verify checksums first, ~5 min).

## Serial/protocol traps (all hit for real)

- **`screen_probe.py upload --raw` hangs the stock `twfile` receiver.** After `0xFE` the screen waits for data and
  ignores every other command (`connect` included) until power-cycled — also for stock `sd0/` targets, also with zero
  data bytes sent. It never sends the final `0xFD`, and for `sd0/` it leaves only `<name>.tm` (the temp file is
  renamed to the real name on completion, which never happens). Nearly all "the firmware hangs" observations of
  2026-10-22 were this. **Always use the default framed upload** (it also commits `sd0/` files correctly).
- A bare `twfile "x",N` with no data is a legitimate "waiting for data" state, not a bug.
- `delfile` replies `instruction successful` for any name, existing or not (checked with `bkcmd=3`) — it cannot be used
  to probe whether a file exists. `findfile "sd0/*"` -> `invalid parameter quantity`, `rdfile "x"` ->
  `invalid parameter quantity`, `sets "ramv: 0,0,sd0/x"` -> always `instruction successful`: there is no known way to
  list the SD card over serial. (The user had to look at the card once: it showed `TFWriter_AiHmiT7.bin.make.tm`,
  387236 B, from a `--raw` upload, plus macOS `._` files.)
- After a *failed* transfer attempt, resync with bare `FF FF FF` only; `TWFILE_EXIT` frames sent to a receiver that is
  not in transfer made the hook answer `05` endlessly (the continuous `05` stream is how that looks).
- Killing a 921600-baud run leaves the screen at 921600; `FastLink.open`/`Link.open` search for it there and restore.
- `bkcmd=3` makes every command answer (`instruction successful`/errors); the default after a power cycle answers
  errors only. Many valid commands answer nothing — silence is not failure.
- `connect` always answers `comok comok 2,1073-0,TJC4827X243_011C,159,10201,570235016C577237,16777216-0` — it
  comes from flash (`dataModel`), so it cannot tell stock from the SD image. (`16777216` is the 16 MB SPI flash, not
  RAM.)

## Dead ends (do not repeat)

These were hypotheses chased for hours that turned out wrong; most were symptoms of the `--raw` hang above.

- "`CALL_PRESENT` (sub_1D88) deadlocks from the ASCII-command context / needs `cpsie i`": `sub_1D88` has no wait loop;
  the only hardware wait in its chain is the DMA2D TCIF poll in `sub_1e9a8`, which completes by itself. `cpsie i`
  is kept before present out of caution, but nothing was proven to depend on it. A direct read of the DMA2D registers
  (`0x40024000`) from the hook and a "DMA2D clock not enabled yet" theory were also disproved: native `fill`
  presents fine, and waiting 15 s after boot changed nothing.
- "`CALL_SEND` hangs from the ASCII-command context / bursts of `CALL_SEND` hang": the tests that showed it were run
  under `--raw` uploads. It is **untested** under framed uploads; `dumpbit` avoids needing it.
- "Hooks sit too early / interrupts masked": see above; the real bugs were `ptr_7612A8` and the missing framed
  prologue replay.
- "The loader consumes (renames) the SD file after one boot": false (the `.tm` came from the `--raw` upload).
- "SCRATCH (0x400000) is not executable" (from the abandoned `exec` experiment): unproven, its hangs were `--raw`.
- 3-4 letter command names: never matched (parser only passes 5-8 char words).
- Drawing from the `sub_5538` completion context: never visible (see `fastblit.md`), not a timing issue.

## Buzzer / "haptic"

There is no vibration motor in the firmware. A buzzer exists and works: `beep <ms>` is accepted (`instruction
successful` at `bkcmd=3`); the duration argument is ignored — every beep sounds the same (200 vs 100/500 ms all
alike, heard on the bench). `iobeep` is `invalid instruction` as typed (hidden command, syntax unknown); `beepset
<freq>,<dur>` untried. A touch-click (`beep 20` on every press) was added to `screen_fastblit.py` as `--click` (default
off): both unexplained failures of 2026-10-23 — the screen reset to the boot picture (Nanachi) mid-run, and then the
ESP32 and relay USB ports vanishing — happened only in runs with the click enabled, while the earlier all-day runs without
it were stable. Suspected power dip from the buzzer on a shared supply; **unproven**. If the click is wanted, check
supply/USB power first.

## KlipperScreen in Docker

`ks_docker/.env`: `MOONRAKER_HOST=192.168.52.84`, `MOONRAKER_PORT=7125` (`host.docker.internal` does not reach the
real printer from this Mac). `docker compose up -d --build` after editing `entrypoint.sh`.
Seen: (1) blanking after 1 h -> screensaver + `machine.device_power.off` to Moonraker (fixed: `screen_blanking: off`);
(2) panel `network` raises `ModuleNotFoundError: sdbus_block`, KlipperScreen exits, Docker restarts the container and
Xvfb with it (the mirror reconnects). Python deps for the mirror: `pillow`, `python-xlib`, `pyserial` (`numpy` optional).
