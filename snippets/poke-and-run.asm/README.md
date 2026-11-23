# poke-and-run

Proof-ladder rung: **poked-into-SDRAM code runs on the live panel and beeps its
TIM5 buzzer.** The 348-byte `buzz_blob.S` blob (entry + literal pool + the
"ta-daa" melody table) is poked into the SDRAM arena at `0x650000` on an
already-running panel (no boot / power cycle), then executed with the nana `fun`
command (`fun 0x650001` - Thumb `blx`, the 1 bit set). All linked addresses
are self-consistent at `0x650000`; `entry` needs only a valid SP and returns
via `bx lr`.

Companion to `../poke-and-run.c/` — same flow and blob contract, only the blob
source and build differ (hand-written assembly vs C). Note: the C sibling's
scripts were updated first to the binary-only nana `fun` flow in commit 68fd698;
this ASM sibling was updated to match.

## Files

- `buzz_blob.S` — the blob source (canonical home: this folder).
- `buzz_blob.ld` — linker script: links at `0x650000`, `.vector_table` NOLOAD.
- `Makefile` — `make` (build `buzz_blob.bin`), `make run` (build + `run.sh`),
  `make verify` (`verify.sh`), `make clean`.
- `buzz_blob.bin` — the built 348-byte image (entry `0x650000`, blx target
  `0x650001`). Head `4a48 4ff0 …`. **Gitignored** (`.gitignore` `*.bin`) —
  build it first, below.
The shared driver logic lives once in `../common/` (one authoritative copy for
both siblings); the per-folder `run.sh` / `verify.sh` are 3-line shims that set
`HERE` to this folder (so `BLOB` resolves to *this* folder's `buzz_blob.bin`)
plus `BLOB_SIZE=348 LABEL=asm` (run.sh only) and `exec` the shared script —
exit codes pass straight through.

- `run.sh` — shim → `../common/run.sh` (the whole flow, parameterized by
  `BLOB_SIZE`/`LABEL`): blob-head liveness peek → pre-poke dump →
  `poke 0x650000 @buzz_blob.bin` (348 B < the 4045 poke cap - one nana request)
  → fresh-console 348-byte readback `cmp`'d against the blob (≤2 attempts) →
  `fun 0x650001` over the shell REPL (expect `fun 0x00650001: ok`) → post
  liveness re-check, then a `Done in X.Xs` line. Output is brew-style via
  `ui.sh`. Panel I/O only via
  `tools/screen_probe.py` (no `--port`; the port comes from `PANEL_PORT`).
- `verify.sh` — shim → `../common/verify.sh`: independent readback of the TIM5
  register block + the SYS clock/reset/pin registers, decoded to a fingerprint
  verdict: a completed melody leaves `{CR1:0, PSC:0x63, ARR:0x4FB,
  CCR4:0x27D, CCMR1/2:0x7070, CCER:0x3333}` (last note = G6, counter
  stopped); `ARR==0` = never ran, `ARR==0x782` (C6) = bailed on the first
  note. Output is brew-style via `ui.sh`.
- `../common/common.sh` — shared setup, sourced by the two drivers: `PANEL_PORT`
  (required; fail clear if unset), the `probe()` wrapper around
  `tools/screen_probe.py` (IAC framing is auto-resolved by the tool itself: on
  for `socket://` links, off otherwise), the `LIVE_HEAD` blob-head constant,
  and `check_live` (every driver starts with this blob-head liveness peek).
  `HERE`/`BLOB` respect a pre-set value (the shims pre-set `HERE` to the
  per-folder dir) and default to the sourcing script's directory.
- `../common/ui.sh` — brew-style output helpers, sourced by the two drivers:
  `step` (`==> [N/total] label`, cyan), `ok` (`✔`, green), `fail` (`✘`, red,
  stderr), `info` (plain detail dumps). Color is on only when stdout is a TTY
  and `NO_COLOR` is unset.
- `../common/run.sh` — the shared, parameterized flow (see `run.sh` above);
  `BLOB_SIZE` and `LABEL` are required (the shims set them).
- `../common/verify.sh` — the shared flow (see `verify.sh` above); the decode
  section between the `VERIFY_DECODE_BEGIN/END` markers is self-contained
  (pure POSIX sh: `od` + shell arithmetic + `printf`, no panel I/O).

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

`run.sh` exit codes: 0 = ok, 1 = a step failed (poke not verifiable, no
`fun ... ok` reply, or panel not live after the blx — the last one may mean
the panel hung;
recovery is a power cycle), 2 = environment (no `PANEL_PORT`, missing/stale
blob). `verify.sh` exits 1 if any register read comes back empty.

## Sample output

`run.sh` (brew-style steps, non-TTY / `NO_COLOR`):

```sh
$ make -C snippets/poke-and-run.asm run
==> [1/6] liveness: console blob head at 0x79D448
==> [2/6] pre-poke: 8 bytes at 0x650000
00650000  4a 48 4f f0 00 01 4f f0                          |JHO...O.|
==> [3/6] poke 348 B to 0x650000 (one nana request)
poke file: 348 bytes to 0x650000 in 1 x 4045-byte chunks
poke file: 348 bytes written in 0.05 s (6.6 KiB/s)
==> [4/6] verify readback (348 B)
✔ poke verified (348 B, byte-identical)
==> [5/6] blx the blob: fun 0x650001
✔ fun 0x00650001: ok — the blob ran and returned
==> [6/6] post liveness
✔ Done in 1.4s — panel live, 'ta-daa' should be audible (verify.sh for the register fingerprint)
```

`verify.sh` (fingerprint table, green ✔ / red ✘ on a TTY):

```sh
$ make -C snippets/poke-and-run.asm verify
==> [1/3] liveness: console blob head at 0x79D448
==> [2/3] readback: TIM5 block + SYS registers (6 peeks)
  tim5 @ 0x40007400
  enclk0 @ 0x40000080
  ...
==> [3/3] verdict
    CR1    0x0000  ✔
    PSC    0x0063  ✔
    ARR    0x04fb  ✔
    CCR4   0x027d  ✔
    CCMR1  0x7070  ✔
    CCMR2  0x7070  ✔
    CCER   0x3333  ✔
  SYS: ENCLK0=0x2 ENCLK2=0x100000 IPSWRST2=0x100000 IOMODE8=0x40 IOAFR16=0x5000
  ✔ FINGERPRINT MATCH — full ta-daa melody ran (ended on G6, counter stopped)
  (buzzer silence, if any, is a clock/pin issue, not code)
```

## Status

The scripts were updated to the binary-only nana `fun` flow (matching the C
sibling) after the 2026-11-21 console restructure - the old text `fun0`
command and the `0x5A` ack are gone. The last on-panel run (2026-11-15, old
`fun0` flow) poked and `blx`'d cleanly (panel live before/after, display
unchanged) but the **"ta-daa" was NOT audible - open hypothesis: the TIM5
clock/reset is not effective (counter never runs, waits no-op). Debug =
three-phase TIM5 + SYS pin/clock + `GPIOI_OMCR` state (before / right after /
seconds after the blx). `verify.sh` covers the seconds-after phase only; the
before and right-after phases are still manual. Unverified on the current blob
since 2026-11-18 (same as the C sibling).
