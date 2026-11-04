# stage1 crash dump: getting a full HardFault dump on the bench

Status: working (first used for the m2f/m2g pool-fall-through fault). Date: 2026-11-03.
Companion to `test-bench.md` (bench wiring) and the `fault_trap`/warm-bail comments in
`stage1/stage1.S` (register-level source of truth).

## What the firmware does on a HardFault

- Vector slot 3 = `fault_trap` (Thumb). On entry the hardware has already pushed the 8-word
  exception frame `{R0,R1,R2,R3,R12,LR,PC,xPSR}` onto the faulting stack (trap-entry SP = fault-time SP − 32).
- `fault_trap` then:
  - copies the raw frame → `FAULT_FRAME` `0x2000FF74` (8 words);
  - latches SCB `CFSR/HFSR/BFAR` (`0xE000ED24/28/34`) → `FAULT_STATUS` `0x2000FF94` — mandatory,
    the IWDG reset clears the SCB, so the latch is the only surviving copy;
  - parks the trap-entry SP → `FAULT_WORD` `0x2000FFF4`;
  - spins until the IWDG (armed on the cold pass, ~10 s) resets the chip.
- All three blocks sit outside the loader's SRAM working set, so they survive the IWDG reset and the
  ROM re-copy. On the **next warm pass** the loader prints them over UART (115200, UART2 PJ6/7)
  before bailing to stock: nine lines `F: P: L: 0: 1: X: C: H: B:` — then stock boots normally.
- The print is range-gated on `FAULT_WORD` inside SRAM0 (`0x20000000..0x20010000`), and the cold pass
  clears `FAULT_WORD` on entry, so stale SRAM after a true power-on never prints.

## Reading the dump

| Marker | Word | Meaning |
|---|---|---|
| `F:` | `FAULT_WORD` | trap-entry SP = fault-time SP − 32 (exception-frame top = `F:` + 32). Localizes which stack/frame was live |
| `P:` | frame[6] | faulting PC, exact instruction (Thumb bit in `X:`) |
| `L:` | frame[5] | fault-time LR (the caller) |
| `0:`, `1:` | frame[0..1] | R0, R1 at fault |
| `X:` | frame[7] | xPSR. **Thumb = bit 24 (0x01000000) on ARMv7-M**, not bit 0 (do not copy the `x & 1` test out of `/tmp/parse_m2g.py`) |
| `C:` | CFSR | fields: MMFSR bits 7:0, BFSR 15:8, UFSR 31:16. UFSR: `UNALIGN 0x00010000`, `NOCP 0x00040000`, `INVSTATE 0x00100000`, `INVPC 0x00200000`, `UNDEFINSTR 0x00400000`. BFSR: `IBUSERR 0x100`, `PRECISERR 0x200`, `IMPRECISERR 0x400`, `UNALIGNED 0x4000`, `BFARVALID 0x8000`. MMFSR: `IACCVIOL 0x1`, `DACCVIOL 0x2`, `MUNALIGNED 0x8`, `MIMPRECIS 0x10`, `MMPRECIS 0x20`, `MKERR 0x40` |
| `H:` | HFSR | standard bits: `VECTTBL 0x2`, `LOCKUP 0x40000000`, `DEBUG 0x80000000` |
| `B:` | BFAR | fault address — valid only when `C:` has BFSR `BFARVALID`; for imprecise faults it is garbage (m2g: `E000ED34` = the register's own address) |

**`C:` = 0 with nothing else useful** = the fault set no status bits (m2g: `H:` = `0x00010000`, a bit
that matches no standard HFSR field — this SoC's HFSR is non-standard; lean on `P:`/`L:`/`X:`).
`P:` + `L:` then name the exact instruction and its caller.

### Mapping addresses to source

- `P:`/`L:` are image VMAs (`0x8xxxxxx`). Symbolize against `stage1/stage1_loader.elf` (left by
  `python3 stage1/build.py`): `arm-none-eabi-objdump -d stage1/stage1_loader.elf`.
- Only the packed file at hand: `python3 tools/fw_unscramble.py TFWriter_AiHmiT7.bin.make /tmp/img.bin`;
  raw-image file offset = VMA − `0x7F800` (image linked at `0x80000`, code starts at file `0x800`).
- Worked example (m2g): `P:000818E8` = a literal-pool word (`0x2000FFF8`) sitting between
  `ldr r1, =entry_trampoline` and `pop {r6}` in the cold-path tail, executed as Thumb → pool fall-through.

## Getting one on the bench

1. Build: `python3 stage1/build.py` → `TFWriter_AiHmiT7.bin.make` (image left as `stage1/stage1_loader.elf`).
2. Upload (one client on the gateway UART at a time):
   `python3 tools/screen_probe.py --port socket://127.0.0.1:7000 upload TFWriter_AiHmiT7.bin.make --target sd0/TFWriter_AiHmiT7.bin.make`
3. Cold-boot capture (pattern: `/tmp/stage1_bench_m2g.py`): gateway `http://rpi2.local:9292/api` —
   `PUT /power {"state":"off"}` → start a thread reading `127.0.0.1:7000` into `/tmp/uart_<build>.log` →
   `PUT /power {"state":"on"}` → ~40 s, `GET /snapshot` every 0.6 s for camera frames.
4. Expected timeline when it faults: cold-pass banner → ≤ ~10 s silence (IWDG reset) → warm pass prints
   the nine dump lines → bails to stock → stock UI ~t+10–15 s. No fault: cold pass completes (banner +
   `T*`/`M2` markers), no dump, stock boots.
5. Parse: `re.finditer(rb"([FP L01XCHB]):([0-9A-Fa-f]{8})", data)` (pattern from `/tmp/parse_m2g.py`).

## Limits

- The dump is printed only for a HardFault whose trap-entry SP is in SRAM0 (range gate). A fault on
  another stack, or before the IWDG is armed (early cold path), never resets → no warm pass → nothing.
- The dump survives exactly one IWDG reset; a second fault or a power-off wipes the blocks.
- IWDG is armed only on the cold pass; the warm pass must bail inside the ~10 s window (it does, ~1 s).
- One client on the gateway UART: close the capture before re-uploading (and vice versa).
