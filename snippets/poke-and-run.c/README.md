# poke-and-run (C)

Proof-ladder rung, C variant: **poked-into-SDRAM code runs on the live panel and
beeps its TIM5 buzzer.** The 300-byte blob (compiled from `buzz_blob.c`: the same
`entry` + "ta-daa" melody as the asm sibling) is poked into the SDRAM arena at
`0x650000` on an already-running panel (no boot / power cycle), then executed
with the nana `fun` command (`fun 0x650001` - Thumb `blx`, the 1 bit set). All
linked addresses are self-consistent at
`0x650000`; `entry` needs only a valid SP and returns via its own C epilogue
(`pop {r4,r5,pc}` ≡ `bx lr`).

Companion to `../poke-and-run.asm/` — same flow and blob contract, only the blob
source and build differ (C vs hand-written assembly). Note: the .asm sibling's
scripts still use the old text `fun0` flow and the old blob-head fingerprint -
stale after the 2026-11-21 binary-only restructure (left as-is on purpose).

## Files

- `buzz_blob.c` — the blob source (canonical home: this folder): `entry` writes
  the SYS clock/reset/pin setup for TIM5, loads the melody table, and plays it
  on TIM5 CH4 (PI3 piezo); returns via `pop {r4,r5,pc}`.
- `buzz_blob_c.ld` — linker script: links at `0x650000`, `.text` first, no vector
  table, no `.bss`.
- `Makefile` — `make` (build `buzz_blob.bin`), `make run` (build + `run.sh`),
  `make verify` (`verify.sh`), `make clean`.
- `buzz_blob.bin` — the built 300-byte image (entry `0x650000`, blx target
  `0x650001`). Layout: `.text` 252 B @ 0x650000, `.rodata` (melody table) 48 B
  @ 0x6500FC, end 0x65012C. Head `4f f0 80 43 30 b5 …` (the first byte `0x4F`
  is Thumb, bit 0 set). **Gitignored** (`*.bin`) — build it first, below.
- `common.sh` — shared setup, sourced by the two drivers: `PANEL_PORT` (required;
  fail clear if unset), the `probe()` wrapper around `tools/screen_probe.py`
  (IAC framing is auto-resolved by the tool itself: on for `socket://` links,
  off otherwise), the `LIVE_HEAD` blob-head constant, and `check_live` (every
  driver starts with this blob-head liveness peek).
- `run.sh` — the whole flow: liveness → pre-poke 8 B dump →
  `poke 0x650000 @buzz_blob.bin` (300 B < the 4045 poke cap - one nana request)
  → fresh-console 300-byte readback `cmp`'d against the blob (≤2 attempts) →
  `fun 0x650001` over the shell REPL (expect `fun 0x00650001: ok`) → post
  liveness re-check. Panel I/O only via
  `tools/screen_probe.py` (no `--port`; the port comes from `PANEL_PORT`).
- `verify.sh` — independent readback of the TIM5 register block + the SYS
  clock/reset/pin registers, decoded to a fingerprint verdict: a completed
  melody leaves `{CR1:0, PSC:0x63, ARR:0x4FB, CCR4:0x27D, CCMR1/2:0x7070,
  CCER:0x3333}` (last note = G6, counter stopped); `ARR==0` = never ran,
  `ARR==0x782` (C6) = bailed on the first note. The decode section between the
  `VERIFY_DECODE_BEGIN/END` markers is self-contained (pure POSIX sh: `od` +
  shell arithmetic + `printf`, no panel I/O) and identical to the asm sibling.

## Build

```sh
make -C snippets/poke-and-run.c
```

(compiles `buzz_blob.c` with cortex-m4/thumb/hard-float, links with
`buzz_blob_c.ld`, objcopy — all artifacts, `buzz_blob.elf` / `buzz_blob.bin`,
land in this folder)

## Run / verify

Needs the stage-0 image with the 0x2A1E console blob on the panel (the scripts
abort early if the blob head is not at `0x79D448`).

```sh
export PANEL_PORT=/dev/ttyUSB0      # or socket://host:port for a ser2net link
make -C snippets/poke-and-run.c run
make -C snippets/poke-and-run.c verify
```

`run.sh` exit codes: 0 = ok, 1 = a step failed (poke not verifiable, no
`fun ... ok` reply, or panel not live after the blx — the last one may mean the
panel hung; recovery is a power cycle), 2 = environment (no `PANEL_PORT`,
missing/stale blob). `verify.sh` exits 1 if any register read comes back empty.

## Status

Retracted: the "D-cache coherency bug" analysis (2026-11-18) was wrong. The
poke-and-run `blx` failures (2026-11-17/18) were the console blob's broken
`0x` prefix parse: `fun0 0x650001` parsed as `fun0 0` -> `blx 0` -> HardFault.
The text parser was fixed (`pb_hex`), and on 2026-11-21 the console went
binary-only - the text grammar (and `pb_hex`) is gone, and this flow now uses
the nana `fun` command (the scripts' old `raw fun0 ... + 0x5A`-ack grep and the
blob-head fingerprint in `common.sh` were updated to match). Unverified on the
current blob since 2026-11-18.
