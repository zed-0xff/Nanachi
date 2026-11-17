# poke-and-run

Proof-ladder rung: **poked-into-SDRAM code runs on the live panel and beeps its
TIM5 buzzer.** The 348-byte `buzz_blob.S` blob (entry + literal pool + the
"ta-daa" melody table) is poked into the SDRAM arena at `0x650000` on an
already-running panel (no boot / power cycle), then executed with
`fun0 0x650001` (Thumb `blx`). All linked addresses are self-consistent at
`0x650000`; `entry` needs only a valid SP and returns via `bx lr`.

## Files

- `buzz_blob.S` — the blob source (canonical home: this folder).
- `buzz_blob.ld` — linker script: links at `0x650000`, `.vector_table` NOLOAD.
- `Makefile` — `make` (build `buzz_blob.bin`), `make run` (build + `run.sh`),
  `make verify` (`verify.sh`), `make clean`.
- `buzz_blob.bin` — the built 348-byte image (entry `0x650000`, blx target
  `0x650001`). Head `4a48 4ff0 …`. **Gitignored** (`.gitignore` `*.bin`) —
  build it first, below.
- `common.sh` — shared setup, sourced by the two drivers: `PANEL_PORT` (required;
  fail clear if unset), the `probe()` wrapper around `tools/screen_probe.py`
  (IAC framing is auto-resolved by the tool itself: on for `socket://` links,
  off otherwise), the `LIVE_HEAD` blob-head constant, and `check_live` (every
  driver starts with this blob-head liveness peek).
- `run.sh` — the whole flow: blob-head liveness peek → pre-poke dump →
  `poke 0x650000 @buzz_blob.bin` (2×255 B chunks) → fresh-console 348-byte
  readback `cmp`'d against the blob (≤2 attempts) → `fun0 0x650001` (expect the
  `0x5A` ack) → post liveness re-check. Panel I/O only via
  `tools/screen_probe.py` (no `--port`; the port comes from `PANEL_PORT`).
- `verify.sh` — independent readback of the TIM5 register block + the SYS
  clock/reset/pin registers, decoded to a fingerprint verdict: a completed
  melody leaves `{CR1:0, PSC:0x63, ARR:0x4FB, CCR4:0x27D, CCMR1/2:0x7070,
  CCER:0x3333}` (last note = G6, counter stopped); `ARR==0` = never ran,
  `ARR==0x782` (C6) = bailed on the first note.

## Build

```sh
make -C snippets/poke-and-run.asm
```

(assembles `buzz_blob.S`, links with `buzz_blob.ld`, objcopy — all artifacts,
`buzz.o` / `buzz_blob.elf` / `buzz_blob.bin`, land in this folder)

## Run / verify

Needs the stage-0 image with the 0x2A1E console blob on the panel (the scripts
abort early if the blob head is not at `0x79D448`).

```sh
export PANEL_PORT=/dev/ttyUSB0      # or socket://host:port for a ser2net link
make -C snippets/poke-and-run.asm run
make -C snippets/poke-and-run.asm verify
```

`run.sh` exit codes: 0 = ok, 1 = a step failed (poke not verifiable, no `0x5A`
ack, or panel not live after the blx — the last one may mean the panel hung;
recovery is a power cycle), 2 = environment (no `PANEL_PORT`, missing/stale
blob). `verify.sh` exits 1 if any register read comes back empty.

## Status (2026-11-15)

The blob poked and `blx`'d cleanly (`0x5A` ack, panel live before/after, display
unchanged) but the **"ta-daa" was NOT audible**. The `fun0` ack arrived at 0.010 s
while the melody should take ~0.67 s — open hypothesis: the TIM5 clock/reset is
not effective (counter never runs, waits no-op) or the `0x5A` is a pre-launched
ack. Debug = three-phase TIM5 + SYS pin/clock + `GPIOI_OMCR` state
(before / right after / seconds after the blx). `verify.sh` covers the
seconds-after phase only; the before and right-after phases are still manual.
