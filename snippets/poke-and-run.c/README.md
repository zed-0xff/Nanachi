# poke-and-run (C)

Proof-ladder rung, C variant: **poked-into-SDRAM code runs on the live panel and
beeps its TIM5 buzzer.** The 300-byte blob (compiled from `buzz_blob.c`: the same
`entry` + "ta-daa" melody as the asm sibling) is poked into the SDRAM arena at
`0x650000` on an already-running panel (no boot / power cycle), then executed
with `fun0 0x650001` (Thumb `blx`). All linked addresses are self-consistent at
`0x650000`; `entry` needs only a valid SP and returns via its own C epilogue
(`pop {r4,r5,pc}` ≡ `bx lr`).

Companion to `../poke-and-run.asm/` — identical driver scripts and blob contract,
only the blob source and build differ (C vs hand-written assembly).

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
  fail clear if unset), `PANEL_IAC=1` → `--iac`, the `probe()` wrapper around
  `tools/screen_probe.py`, the `LIVE_HEAD` blob-head constant, and `check_live`
  (every driver starts with this blob-head liveness peek).
- `run.sh` — the whole flow: liveness → pre-poke 8 B dump →
  `poke 0x650000 @buzz_blob.bin` (2×255 B chunks) → fresh-console 300-byte
  readback `cmp`'d against the blob (≤2 attempts) → `fun0 0x650001` (expect the
  `0x5A` ack) → post liveness re-check. Panel I/O only via
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
# export PANEL_IAC=1                # only for ser2net/telnet links (IAC-escaped 0xFF)
make -C snippets/poke-and-run.c run
make -C snippets/poke-and-run.c verify
```

`run.sh` exit codes: 0 = ok, 1 = a step failed (poke not verifiable, no `0x5A`
ack, or panel not live after the blx — the last one may mean the panel hung;
recovery is a power cycle), 2 = environment (no `PANEL_PORT`, missing/stale
blob). `verify.sh` exits 1 if any register read comes back empty.

## Status (2026-11-16)

C port of the asm snippet; the blob is byte-for-byte functionally equivalent
(same register-write sequence, same 3-note "ta-daa" melody, same terminator).
Built 300 B (252 B `.text` + 48 B `.rodata` melody), no undefined refs, Thumb
first byte, `pop {r4,r5,pc}` epilogue — layout verified on the ELF.

**Not yet poked to the panel.** The open question inherited from the asm
snippet (2026-11-15) stands: the blob `blx`'d cleanly (`0x5A` ack, panel live)
but the melody was not audible — the `fun0` ack returned in 0.010 s where a
full run should take ~0.67 s, i.e. the TIM5 clock/reset gates may not be
effective. `verify.sh`'s fingerprint is the discriminator; run it on both
snippets and compare.
