# Serial command reference (Sovol SV08 Max screen, AiHmiT7 firmware 159)

Nextion/TJC-compatible serial command set of this screen, sent over `/dev/ttyS4` (115200 baud default) or the same
UART via a USB-serial bridge (`tools/screen_probe.py --port ...`). Three layers:

1. **Base protocol**: how commands and replies are framed.
2. **Instructions**: the documented Nextion/TJC command set (two tables in the firmware, see below), reached by name.
3. **Hidden functions**: a separate dispatch in the `get`/`sets` handler that matches a variable-name prefix against a
   second table (`ramv`, `flashup`, `cpufreq`, ...) before falling back to a real variable, reached the same way as a
   normal read/write but not in any instruction table or editor menu.

Everything is marked per-cell, from two ground truths: the AiHmiT7 firmware 159 (`app_10000_plain.bin`, decompiled as
`app_10000.c`, see `sovol/flash_layout.md`) and the editor's own hint files (`ext/HMI/USARTHMI/ch0_com.bin` /
`ch0_va.bin`, an older build's command/variable descriptions, XORed with `0x05`, in Chinese). Status legend:

| Mark | Meaning |
|---|---|
| ✅ | Tested on this screen in this project |
| 📖 | The editor's own description, not independently tested here |
| 🔍 | Inferred from the firmware code (name, operand count/kind), not tested |
| ⚠️ | Undocumented hidden function, reverse-engineered from the decompiled firmware |
| 🧩 | Confirmed by real, commented production code from a **different** TJC/Nextion device (not this screen's firmware) — the instruction set is shared across the product line, but exact behavior on this specific firmware build is not independently confirmed |

In the firmware there are two full name tables (`tools/fw_tables.py` extracts them): a **53-entry table** for commands
with a free-form string operand (names ≤ 8 bytes) and a **41-entry table** for fixed-operand-count commands (names ≤ 4
bytes). Table position is also the compiler's pre-compiled bytecode number (see `TFTTool/NextionInstructionSets.py`) — a
separate concern that need not match the serial syntax documented here.

**Dispatch (found in the firmware, IDB names in parentheses).** Four name lists sit back to back at `0x2F168`:
`strings53` (instructions with a string operand, 12-byte entries `name[8], group, argc, argtype, opcode`),
`strings41` @`0x2F3E4` (fixed-size instructions, 8-byte entries `name[4], group, argc, argtype, opcode`),
`strings59` @`0x2F530` and `strings22` @`0x2F708` (the system variables / colour constants with short and long names,
`name, id` — `id` `0xC8` marks a colour constant, the other bytes are the variable id; not instructions).
For an instruction, `group` indexes an 8-slot pointer array at `0x2F148` and `opcode` is passed to that handler as its
second argument:

| Group | Handler | Instructions (opcode) |
|---|---|---|
| 0 | `cmd_grp0_exec` 0x28EC8 (`tbb`, opcodes 0..0x34) | `cls` 00, `draw_h` 01, `init` 02, `showqq` 03, `picq` 04, `xpic` 05, `ref` 06, `fill` 08, `page` 09, `line` 0A, `draw` 0B, `draw3d` 0C, `cir` 0D, `cirs` 0E, `pic` 0F, `tsw` 10, `print` 11, `sendme` 12, `touch_j` 13, `ref_stop` 14, `ref_star` 15, `com_stop` 16, `com_star` 17, `code_c` 18, `printh` 19, `cov` 1A, `get` 1B, `i` 1C, `addt` 1D, `randset` 1E, `vis` 1F, `setbaudz` 20, `rest` 21, `lcd_dev` 22, `click` 23, `cle` 24, `prints` 25, `qrcode` 26, `ucopy` 27, `covx` 28, `play` 29, `setlayer` 2A, `cfguart` 2B, `cuts` 2D, `beep` 2E, `gets` 2F, `sets` 30, `meup` 31, `beepset` 32, `uprd` 33, `txtputr` 34 |
| 1 | `cmd_grp1_text` 0x2A628 (compare chain) | `xstr` 00, `strlen` 02, `strsize` 03, `setbrush` 04, `zstr` 05, `nstr` 06, `substr` 07, `btlen` 08, `spstr` 0A, `xnum` 0B |
| 2 | `cmd_grp2_storage` 0x29EA4 | `wepo` 00, `repo` 01, `wept` 02, `rept` 03, `wfpt` 04, `rfpt` 05, `twfile` 06, `delfile` 07, `refile` 08, `findfile` 09, `rdfile` 0A, `newfile` 0B, `newdir` 11, `deldir` 12, `finddir` 13, `redir` 14 |
| 3 | `cmd_cfgpio` 0x2A1C0 | `cfgpio` |
| 4 | `cmd_grp4_misc` 0x2A4E8 (`tbb`, 0..8) | `timerset` 00, `udelete` 01, `whmi_cle` 03, `lcd_refx` 04, `getpassw` 05, `doevents` 06, `move` 07, `getv` 08 |
| 5 | none (handled elsewhere) | `comok`, `lhmi_cle` |
| 6 | `cmd_grp6_pinyin` 0x2A1E4 | `pa_q` 00, `pa_txt` 01 |
| 7 | `cmd_grp7_crc` 0x29E18 | `crcrest` 00, `crcputs` 01, `crcputh` 02, `crcputu` 03 |

In the IDB every command body is labelled `cmd_<name>` (inline body) or `case_<name>` (inline stub that calls the
function `cmd_<name>`).

## Base protocol

* **Framing**: every command and reply ends with `FF FF FF`; nothing is escaped, so those three bytes cannot appear
  literally inside a command (a path, a string, ...) — the usual Nextion/TJC limit.
* **`connect`**: asks the screen to identify itself. Reply: `comok <touch_type>,<a>-<b>,<model>,<firmware>,<mcu_code>,
  <serial>,<flash_size>-<c>` — confirmed on this screen: `comok 2,1073-0,TJC4827X243_011C,159,10201,
  570235016C577237,16777216-0`.
* **Return codes** (when `bkcmd` allows them; one byte + `FF FF FF`, see `tools/screen_probe.py`
  `RETURN_CODES` for the full table): `0x01` instruction successful, `0x00` invalid instruction, `0x02` invalid
  component id, `0x03` invalid page id, `0x06` file operation failed, `0x1a` invalid variable name/attribute,
  `0x1c` assignment failed, `0x24` serial buffer overflow, `0xfe`/`0xfd` "ready for data"/"transfer finished" (`twfile`),
  `0x88` system started.
* **`get`/`gets` replies**: a number is `0x71` + 4-byte little-endian signed int + `FF FF FF`; a string is `0x70` +
  text + `FF FF FF`.
* **Touch**: object touch events are `0x65 <page> <component> <press=1/release=0>`; `sendxy=1` additionally emits
  `0x67`/`0x68 <state> <xh> <xl> <yh> <yl>` on press/release (confirmed — **the release frame repeats the press
  coordinates**, movement is not reported this way; poll the `tch0`/`tch1` system variables while a finger is down
  instead, see the system variable table).
* **Always-allowed commands**: a short list keeps working even while `com_stop` is in effect (found in the dispatcher
  that gates on it): `connect`, `runmod=0/1/2` (switches run mode; only 0/1/2 accepted), `com_star`/`com_stop` (only
  while `bkcmd`'s internal gate is open), `whmi-wri`/`whmi-wris`, `sleep=0`, `get `, `wup=`, `print`/`prints `/`printh `.
* **`whmi-wri size,baud,0`**: confirmed, used throughout this project to flash a `.tft`. Switches to `baud`, then
  4096-byte chunks each acknowledged with `0x05`; after the transfer the firmware validates the model, then a running
  checksum of the whole file (word-wise, XORed with the file's own header fields), writes it into place, and only
  then marks the on-screen `.tft` valid — any failure before that point leaves the screen in `Data ERROR!`/white-screen
  until a full successful rewrite (see `sovol/flash_layout.md` and the update notes in the project memory). **Change
  baud _before_ sending this command, never right after it** — the first bytes through a USB-serial bridge after a
  host-side baud change are unreliable and a truncated first chunk is silently dropped.
* **`whmi-wris size,baud,X`**: same framing, sets an internal flag that — on the very first chunk of this session —
  compares the request against the firmware's own saved record of the last (possibly interrupted) update: if it
  matches and that attempt had completed, the new transfer is accepted without re-verifying; if it matches but had not
  completed, the firmware re-reads the already-written flash region to rebuild its running checksum and then continues
  the write from that point, instead of restarting from byte 0. The exact meaning of `X` (whether it is the actual
  resume offset the firmware trusts, or just a marker it checks against its own state) is not pinned down, and this
  has **not been tried on hardware** — worth testing deliberately before relying on it, since getting the match
  criteria wrong risks writing new data at the wrong offset.

### String-argument instructions (53 entries)

| Name | Parameters | Status | Description |
|---|---|---|---|
| `click` | obj, event | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Fires a component's press/release event. |
| `comok` | — | ✅ tested (part of the base serial protocol) | Reply to `connect`; never sent by the host, see the protocol section above. |
| `btlen` | att0, att1 | 📖+🧩 editor description, operand roles confirmed by a different TJC device's production code (community nspanel project, `btlen tSend.txt,sys0`) | Tests a string variable's (`att0`) length in bytes, written into `att1`. |
| `redir` | — | 🔍 inferred from the firmware code, not tested | Likely redirects file I/O to a different directory/port; grouped with the other ram/sd0 file commands. |
| `spstr` | src.txt, dest.txt, separator, index | 🧩 confirmed syntax from a different TJC device's production code (community nspanel project, `spstr strCommand.txt,tIcon1.txt,"~",2`) | Splits `src.txt` on `separator` and writes the `index`-th token (0-based) into `dest.txt`. |
| `print` | att | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Sends a variable/constant value over the serial port, unformatted. |
| `ucopy` | dest, start, len, flag | 🧩 confirmed syntax from a different TJC device's production code (community nspanel project, `ucopy payloadLength,2,2,0` / `ucopy strCommand.txt,4,payloadLength-5,0`) | **Correction — not a file copy, as previously guessed here:** copies `len` bytes starting at offset `start` of the serial **receive buffer** (`u[]`, see `usize`) into `dest` (a `.val` or `.txt` variable). `flag`'s meaning not determined. |
| `code_c` | — | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Clears the serial command receive buffer. No parameters. |
| `draw3d` | x, y, x2, y2, style, color | 🔍 inferred from the firmware code, not tested | Likely draws a 3D/bevelled rectangle (sunken or raised), the usual Nextion-family `draw3d`. |
| `qrcode` | x, y, w, ecc, string | 🔍 inferred from the firmware code, not tested | Draws a QR code — the firmware has a full from-scratch QR encoder (format-info BCH, 8 mask patterns, see sovol/flash_layout.md). Exact argument order not confirmed on hardware. |
| `rdfile` | — | 🔍 inferred from the firmware code, not tested | Likely reads a ram/ or sd0/ file into a variable (the counterpart of `twfile`/`refile`). |
| `refile` | — | 🔍 inferred from the firmware code, not tested | Likely renames/replaces a ram/ or sd0/ file. |
| `twfile` | path, size | ✅ tested on this screen | Framed file upload into ram/ or sd0/: `twfile "path",size`, wait for `0xFE` ("ready"), send 4082-byte frames `3A A1 BB 44 7F FF FE 01 <id:u16> <len+2:u16> <data> <CRC16/MODBUS LE>`, each acked `0x05`; `0xFD` ends. **Framed only** — `screen_probe.py upload --raw` (bare bytes) makes the receiver wait past `0xFE`: no answer until power cycle, `sd0/` left as `<name>.tm`; empty `twfile` after `0xFE` blocks the same way. Framed `sd0/` commits (~10.7 KiB/s @115200). `ram/z` intercepted by fast-blit image (`fastblit.md`). |
| `sendme` | — | ✅ tested on this screen | Sends the current page id over the serial port (reply: `0x66` + page id). No parameters. |
| `draw_h` | x, y, x2, y2, color | 🔍 inferred from the firmware code, not tested | Likely draws a hollow/outline rectangle (`draw` fills), inferred from sitting next to `draw`. |
| `printh` | hex | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Sends custom hex bytes over the serial port. |
| `strlen` | att0, att1 | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Tests a string variable's length (characters). |
| `cfgpio` | id, state, obj | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Configures an extended IO pin's mode: 0 pull-up input, 1 bound to a component's event, 2 push-pull output, 3 PWM output, 4 open-drain (the `obj` parameter only applies to mode 1). |
| `showqq` | — | 🔍 inferred from the firmware code, not tested | Likely shows a small on-screen popup/status icon (paired with the hidden `qqset`); purpose not confirmed. |
| `deldir` | path | 🔍 inferred from the firmware code, not tested | Likely deletes a directory on ram/ or sd0/. |
| `newdir` | path | 🔍 inferred from the firmware code, not tested | Likely creates a directory on ram/ or sd0/. |
| `substr` | att0, att1, star, lenth | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Extracts a substring. |
| `prints` | value, length | 🧩 confirmed syntax from a different TJC device (nspanel, `prints sys0,2` / `prints tSend.txt,0` / `prints crcval,2`) | **Not a formatted print:** sends `value`'s raw bytes — `length` 0 = string at its real length (same as `cov`'s `lenth`), nonzero = that many raw bytes of a numeric value (seen only with 2; 1/4 unconfirmed). The binary counterpart of `print` — this is how a page script emits an exact byte-for-byte frame (length-prefixed payload + trailing CRC) to the host. |
| `pa_txt` | att0, att1, beg, lenth | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Looks up the string for a given pinyin. |
| `delfile` | path | ✅ tested | Deletes a file on ram/ or sd0/. Always answers `instruction successful` at `bkcmd=3` whether or not the file existed, so it can't probe existence (`findfile`/`rdfile` with a quoted path -> `invalid parameter quantity`, no listing command). Deleting a file that isn't the most recently drawn in the ram/ pool shifts the others' positions and silently breaks an in-flight draw — delete only the single file you just finished, right after its `ramv`/`ref`, with no other `ram/` write in between. |
| `newfile` | path | 🔍 inferred from the firmware code, not tested | Likely creates an empty file on ram/ or sd0/ (the counterpart of `delfile`). |
| `udelete` | n | 🧩 confirmed syntax from a different TJC device's production code (community nspanel project, `udelete bufferPos-1`) | **Correction — not a variable delete, as previously guessed here:** deletes the first `n` bytes of the serial receive buffer (`u[]`/`usize`) — used to drop garbage and resync onto the next frame after a malformed one. |
| `strsize` | — | 🔍 inferred from the firmware code, not tested |  |
| `crcputh` | hex bytes | ⚠️🧩 reverse-engineered; syntax confirmed by a different TJC device (nspanel, `crcputh 55 bb`) | Feeds literal hex bytes (`printh`'s syntax) into the running CRC accumulator shared with `crcputs`/`crcputu`/`crcputr` (firmware `sub_94C4`) — used to checksum a fixed protocol header (`55 BB`) plus the rest of the frame via `crcrest`+`crcputs`/`crcputu`. Whether it can also checksum a ram/sd0 file, and the firmware's algorithm-selector argument, are not confirmed. |
| `touch_j` | — | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Runs touch panel calibration. No parameters. |
| `finddir` | pattern | 🔍 inferred from the firmware code, not tested | Likely finds directories on ram/ or sd0/ matching a pattern (counterpart of `findfile`). |
| `txtputr` | — | 🔍 inferred from the firmware code, not tested | Likely reads text into a variable (name pattern close to `crcputr`). |
| `crcputs` | value, length | ⚠️🧩 reverse-engineered; syntax confirmed by a different TJC device (nspanel, `crcputs sys0,2` / `crcputs tSend.txt,0`) | Same `length` convention as `prints` (0 = string at real length, nonzero = that many raw bytes of a numeric value) — feeds those bytes into the running CRC accumulator (`sub_94C4`), the construction-side counterpart of `crcputu`. |
| `randset` | minval, maxval | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Sets the range of the `rand` system variable. |
| `beepset` | freq, duty | 🔍 from the firmware code (`cmd_beepset`, 0x21644), not tested | **Correction — the second argument is a duty value, not a duration:** stores the buzzer's PWM frequency (word) and duty (byte) in the beeper state (0x761EF0). `beep` then drives IO7 (`pio7`/`pwm7`) as a PWM output (`cfgpio_apply(7, 3, 0)`) with those parameters. The `iobeep` system-variable path calls it with 2760 Hz / duty 50, which are presumably the power-on defaults. |
| `cfguart` | port, baud, bits, parity, stop | 🔍 inferred from the firmware code, not tested | Likely configures a UART (port, baud, bits, parity, stop) — the serial-command counterpart of the hidden `uart2`. |
| `crcrest` | channel, init | ⚠️🧩 reverse-engineered from the decompiled firmware, params confirmed by a different TJC device's production code (community nspanel project, `crcrest 1,0xFFFF`) | Resets CRC channel `channel` with initial value `init` (seen used for CRC-16/MODBUS framing, not the hardware CRC-32), so several reads can be chained into one running CRC. |
| `crcputu` | offset, length | ⚠️🧩 reverse-engineered; different TJC device used differently than assumed (`crcputu 0,payloadLength-1`) | Same checksum engine as `crcputh`. **The `path, algorithm` operands above were an unverified guess** — that device instead feeds `length` bytes starting at `offset` of the serial **receive buffer** (`u[]`/`usize`, like `ucopy`) into the running CRC, no path/algorithm argument. Which model fits this screen isn't confirmed. |
| `lcd_dev` | 1 operand | 🔍 from the firmware code, not tested | **No-op in this firmware:** opcode 0x22's `tbb` slot is the shared "return success" stub (2 instructions, no calls), so the command is accepted and does nothing. |
| `lhmi_cle` | — | 🔍 inferred from the firmware code, not tested | Likely clears local HMI (on-screen/application) state — a guess from the name, paired with `whmi_cle`. |
| `whmi_cle` | — | 🔍 inferred from the firmware code, not tested | Likely cancels/clears a pending `whmi-wri` update session (`whmi` matches the update protocol’s own command prefix). Not tested — power-cycling is the tested way out of a stuck transfer. |
| `findfile` | pattern | 🔍 inferred from the firmware code, not tested | Likely finds files on ram/ or sd0/ matching a pattern. |
| `setbrush` | — | 🔍 inferred from the firmware code, not tested | Likely sets a fill pattern/brush used by later `draw`/`fill` calls. |
| `ref_stop` | — | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Pauses screen refresh. No parameters. |
| `com_stop` | — | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Pauses execution of serial commands (the always-allowed top-level commands still work, see below). No parameters. |
| `ref_star` | — | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Resumes screen refresh. No parameters. |
| `com_star` | — | 🧩 confirmed by a different TJC device's production fix (`ext/KlipperLCD.jcfield`, TJC4B25C12785, same AiHmiT7 firmware) — not tested here | Resumes serial-command execution. No parameters. A `com_stop`'d state (survives a boot-page script or prior session) drops every command but the always-allowed list, no error; that fork's notes (`CLAUDE.md`) saw `page main` silently ignored until `com_star` was re-sent. A stray `com_star` before the first real command costs nothing → add to `screen_bridge.py`'s `Link.open()`, which doesn't currently. |
| `setlayer` | layer, ? | 🔍 inferred from the firmware code, not tested | Likely selects a drawing layer/z-order for subsequent draw commands. **The command table says 2 operands** (`argc` = 2, handler `cmd_setlayer` 0xF1C0), not the single `layer` listed before; the second operand is not identified. |
| `doevents` | — | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Yields control to the screen-refresh loop (lets a pending redraw happen before the next command runs). No parameters. |
| `timerset` | id, interval, enabled | 🔍 inferred from the firmware code, not tested | Likely reconfigures a timer component directly by id (interval, enabled) without going through `tm#.tim`/`tm#.en`. |
| `getpassw` | — | 🔍 inferred from the firmware code, not tested | Likely returns a device password/unlock value; related to the hidden `registered` check. No operand. Not tested. |
| `lcd_refx` | — | 🔍 inferred from the firmware code, not tested | Likely forces a full redraw of the LCD framebuffer. No operand. |
| `setbaudz` | baud | 🔍 inferred from the firmware code, not tested | Likely sets the **power-on default** baud rate (`bauds`), as opposed to `baud=` which is temporary and reverts on reset — if confirmed, this is the way to make a fast rate (e.g. 921600) stick across power cycles. **Not tested**: a wrong persisted baud needs the `recover` baud sweep (`screen_probe.py recover`) or a flash restore from `dump1.bin` to undo. |

### Fixed-size instructions (41 entries)

| Name | Parameters | Status | Description |
|---|---|---|---|
| `i` | — | 🔍 inferred from the firmware code, not tested | First entry of the fixed-size instruction table; likely a placeholder/internal slot, not meant to be sent by hand. |
| `pic` | x, y, picid | ✅ tested on this screen | Draws a picture at a position. |
| `cle` | objid, ch | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Clears a waveform/curve component's data (`ch` 255 = all channels). |
| `ref` | obj | ✅ tested on this screen | Redraws a component. |
| `cir` | x, y, r, color | ✅ tested on this screen | Draws a hollow (outline) circle. |
| `vis` | obj, state | ✅ tested on this screen | Hides/shows a component (0 hide, 1 show). |
| `cls` | color | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Clears the screen to a colour. |
| `get` | att | ✅ tested on this screen | Gets a variable/constant value, formatted (the `get`/`gets` reply framing: a `0x71` + 4-byte little-endian signed int for numbers, `0x70` + text for strings, both terminated the usual way). |
| `cov` | att1, att2, lenth | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Converts a variable's type (`lenth` 0 = automatic string length, non-zero = fixed). |
| `tsw` | obj, state | ✅ tested on this screen | Enables/disables touch on a component (0 disabled, 1 enabled). Confirmed: `tsw 255,0` turns off touch for every component on the current page at once (used to silence the stock page's own buttons while drawing over them); the picture itself stays visible, only touch stops. |
| `xpic` | x, y, w, h, x0, y0, picid | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Crops a rectangular region out of a picture and draws it at a screen position (advanced blit). |
| `uprd` | — | 🔍 inferred from the firmware code, not tested | Likely reads data from a user/UART source into a variable ("u-read"); not pinned down. |
| `page` | pageid | ✅ tested on this screen | Switches to a page (by id or name) and redraws it. |
| `line` | x, y, x2, y2, color | ✅ tested on this screen | Draws a line. |
| `move` | obj, x, y | 🔍 inferred from the firmware code, not tested | Likely moves a component to new coordinates. |
| `fill` | x, y, w, h, color | ✅ tested on this screen | Fills a rectangular area with a colour. |
| `xnum` | x, y, w, h, font, color, background, align, digits, value | 🔍 inferred from the firmware code, not tested | Likely draws a formatted number directly (an `xstr`-style counterpart of a number component), paired with the hidden `xnumadd`. |
| `repo` | att, add | ✅ tested on this screen | Reads a variable from the user storage area. Confirmed: `repo var,address` (bare identifier, no quotes; address first does not work — `repo address,var` fails with `eeprom operation failed`). The area is exactly 1024 bytes (addresses 0–1023), physically at flash `0x140000`/`0x150000` (A/B pair), see `sovol/flash_layout.md`. |
| `wepo` | att, add | 🧩 confirmed by real, commented production code from a different TJC device (`ext/KlipperLCD`, Elegoo Neptune 3 Pro service) — not tested here | Writes a variable to the user storage area (the same 1024-byte area `repo` reads, at flash `0x140000`/`0x150000`). Seen repeatedly in `ext/KlipperLCD`'s own firmware (`wepo losspage,5`, `wepo printpause.t0.txt,10`, `wepo restFlag2,100`) — confirms numeric and string/attribute operands as `att`, plain numeric `add`. Risk-untested on *this* screen's own storage layout, see `sovol/flash_layout.md`. |
| `beep` | duration_ms | ✅ tested on this screen (2026-10-23) | The buzzer exists and works; `beep <ms>` answers `instruction successful` at `bkcmd=3`, but **the duration is ignored** — every beep sounds identical (200/100/500 all alike). A per-touch `beep 20` click is `--click` in `tools/screen_fastblit.py` (off by default: unexplained resets/USB drops happened only in click-enabled runs, power dip suspected, unproven). See `test-bench.md`. |
| `meup` | 2 operands | 🔍 from the firmware code, not tested | **Not a wake command as previously guessed:** `meup` and `uprd` are two table entries (opcodes 0x31 and 0x33) that dispatch to the *same* body (`cmd_uprd_meup`, 0x29DC2), which calls `widget_action_clear` (0x1664C). Real purpose not determined. |
| `pa_q` | att0, att1 | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Gets the number of characters for a given pinyin. |
| `picq` | x, y, w, h, picid | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Crops a rectangular region out of a picture and draws it (simpler form of `xpic`). |
| `nstr` | 3 operands | 🔍 from the firmware code (`cmd_nstr`, 0x2A93A), not tested | **Correction:** the command table says 3 operands (not 8). The handler formats a *number* (via the formatter at 0x1DCAA) into a 76-byte buffer and draws it with the current `setbrush` state — a number-to-text draw, not an `xstr` variant. |
| `xstr` | x, y, w, h, fontid, pointcolor, backcolor, xcenter, ycenter, sta, string | ✅ tested on this screen | Writes text: `sta` selects the background (0 crop, 1 solid colour, 2 picture, 3 none; `backcolor` is a picture id when `sta` is crop/picture); `xcenter`/`ycenter` 0/1/2 = start/middle/end alignment. |
| `zstr` | — | 🔍 inferred from the firmware code, not tested | Likely writes a string in a different character encoding ("zi" = glyph) than `xstr`/`nstr`. |
| `cirs` | x, y, r, color | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Draws a filled (solid) circle. |
| `gets` | name | ⚠️ undocumented, reverse-engineered from the decompiled firmware | Reads a (possibly hidden/pseudo) variable by name, as a formatted string — the read counterpart of `sets`. |
| `sets` | name, value | ✅ tested on this screen | Sets a variable **by name string**, where the name is matched against a table that includes the hidden pseudo-functions (`ramv`, `ramw`, `flashup`, `cpufreq`, …) before falling back to a real variable: `sets "ramv: X, Y, ram/t.jpg"` dispatches straight to the hidden `ramv` handler. This is how this project reaches hidden functionality from a normal serial connection. |
| `cuts` | — | 🔍 inferred from the firmware code, not tested | Likely removes/cuts a substring from a string variable (complement of `substr`). |
| `addt` | objid, ch, qyt | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Streams a batch of data points into a waveform/curve component (transparent-data mode). |
| `init` | obj | 🔍 inferred from the firmware code, not tested | Likely runs a component's `load`/init event code on demand. |
| `rept` | add, lenth | ✅ tested on this screen | Streams raw bytes from the user storage area straight out the serial port (no `get`/framing). `rept 0,1024` returns the whole 1024-byte area cleanly; a request whose `add+lenth` would exceed 1024 returns **nothing at all** (not a partial read) — the clean way to probe the `usize` boundary. More reliable than `repo`+`get` back-to-back in a tight loop (those desynced in testing; cause unidentified, screen stayed healthy). |
| `wept` | add, lenth | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Streams incoming serial data into the user storage area (the write counterpart of `rept`); not tested. |
| `rfpt` | var, address | 🔍 inferred | Likely reads the on-board SPI flash user area (flash-backed counterpart of `repo`). Tried with 3 operands (real count confirmed — 0/1/2/4 args all give `invalid parameter quantity`): any 3 unquoted operands (`sys0,0,4` in every order, incl. `0,0,0`) -> plain `invalid instruction`; any quoted-string operand -> `eeprom operation failed`->`invalid variable operation` — consistently, so none wants a quoted name. Argument meaning not found; screen stayed healthy. |
| `wfpt` | var, address | 🔍 inferred; **no-op per the code** | **The dispatcher's opcode-4 slot (`tbb` @0x29ED0 in `cmd_grp2_storage`) jumps straight to the common return — there is no write code behind it** (which fits the silence below). Originally guessed to be: the flash-backed counterpart of `wepo`. Tried twice (`wfpt 0,0,0`, `wfpt sys0,0,4`): both gave **no reply at all** despite `bkcmd=3` (everything else replies); screen stayed responsive and `sys0` unchanged, but the silence is unexplained — **do not retry without accepting the risk**, since a silent write-type command could be waiting for raw bytes we didn't send. |
| `rest` | — | 📖 the editor's own description (ch0_com.bin/ch0_va.bin), not independently tested on this screen | Resets (reboots) the device. No parameters. |
| `getv` | — | 🔍 inferred from the firmware code, not tested | Likely gets a value with an explicit type/format conversion (complements `get`/`gets`). |
| `draw` | x, y, x2, y2, color | ✅ tested on this screen | Draws a rectangle outline. |
| `covx` | — | 🔍 inferred from the firmware code, not tested | Likely an extended variant of `cov` (type conversion) with more options. |
| `play` | id | 🔍 inferred from the firmware code, not tested | Likely plays a WAV resource by id (the firmware decodes `RIFF`/`data` WAV chunks). |

### System variables (`get`/write-by-name)

| Name | Description |
|---|---|
| `BLACK` | Colour constant BLACK. |
| `BLUE` | Colour constant BLUE. |
| `BROWN` | Colour constant BROWN. |
| `GRAY` | Colour constant GRAY. |
| `GREEN` | Colour constant GREEN. |
| `RED` | Colour constant RED. |
| `WHITE` | Colour constant WHITE. |
| `YELLOW` | Colour constant YELLOW. |
| `appid` | Project/application id. |
| `audio0` | Audio device selector. |
| `audio1` | Audio device selector. |
| `baud` | Current baud rate (temporary; see `bauds` and the hidden `setbaudz` for the power-on default). |
| `bauds` | Default power-on baud rate. |
| `bkcmd` | Which serial command results are returned: 0 none, 1 success only, 2 failure only (power-on default), 3 both. Confirmed: `bkcmd=3` is what we use for readable replies while testing. |
| `crcval` | Holds the last value computed by the `crcput*` family. |
| `delay` | Delay in milliseconds (a script-language statement, not a variable to read). |
| `dim` | Current backlight brightness. |
| `dims` | Default power-on backlight brightness. |
| `dp` | Current page id. |
| `pio0` | GPIO pin 0. |
| `pio1` | GPIO pin 1. |
| `pio2` | GPIO pin 2. |
| `pio3` | GPIO pin 3. |
| `pio4` | GPIO pin 4. |
| `pio5` | GPIO pin 5. |
| `pio6` | GPIO pin 6. |
| `pio7` | GPIO pin 7. |
| `portbusy` | Whether a UART port (see the hidden `uart2`/`umport`) is currently busy. |
| `pwm4` | PWM duty cycle, IO4. |
| `pwm5` | PWM duty cycle, IO5. |
| `pwm6` | PWM duty cycle, IO6. |
| `pwm7` | PWM duty cycle, IO7. |
| `pwmf` | PWM output frequency. |
| `rand` | A random number (range set by `randset`). |
| `recmod` | Recording mode. |
| `rtc0` | RTC year. |
| `rtc1` | RTC month. |
| `rtc2` | RTC day. |
| `rtc3` | RTC hour. |
| `rtc4` | RTC minute. |
| `rtc5` | RTC second. |
| `rtc6` | RTC day of week. |
| `runmod` | Run mode (also settable as a top-level `runmod=0/1/2` command, see below). |
| `scache` | Screen/surface cache setting. |
| `sendxy` | Confirmed, used throughout this project. Real-time touch reporting (0 off, 1 on): emits `0x67` (normal) or `0x68` ("sleep" touch) frames `state xh xl yh yl` on press/release; **the release frame repeats the press's coordinates**, it does not report where the finger lifted off. Movement while held is not reported this way — poll the `tch0`/`tch1` system variables instead (see below). |
| `sleep` | Sleep state (write 0 to sleep, 1 to wake). |
| `spax` | Horizontal character spacing (0 at power-on). |
| `spay` | Vertical character spacing (0 at power-on). |
| `sya0` | Not decoded. |
| `sya1` | Not decoded. |
| `sys0` | Built-in general-purpose numeric variable (signed 32-bit). |
| `sys1` | Built-in general-purpose numeric variable (signed 32-bit). |
| `sys2` | Built-in general-purpose numeric variable (signed 32-bit). |
| `tch0` | Confirmed. Live X coordinate of the finger while touching (0 when nothing touches the panel); poll it between `sendxy` press and release to follow a drag (about 30 updates/second on this screen). |
| `tch1` | Confirmed. Live Y coordinate of the finger while touching, see `tch0`. |
| `tch2` | X coordinate of the start of the current touch (press point). |
| `tch3` | Y coordinate of the start of the current touch (press point). |
| `thc` | Pen colour used while touch-drawing. |
| `thdra` | Touch-drawing feature switch (0 off, 1 on). |
| `thsp` | Auto-sleep timeout with no touch activity. |
| `thup` | Touch-wake switch while asleep (0 off, 1 on). |
| `tpdir` | Touch panel orientation. |
| `usize` | **Resolved 2026-10-22, TJC wiki (`doc/tjcwiki/advanced`):** read-only, bytes currently buffered in the serial **receive ring** — confirms `ucopy`/`udelete`/`crcputu`, and **refutes** the old "1024-byte user storage" guess (that's `repo`/`wepo`/`rept`). Buffer is **1024 B on T0/T1/K0, 4096 on X-series** — ours is X-series (the 4096-byte `twfile` chunking matches). Polled from a **Timer tick** (`if(usize>1){...}`) in production code (🧩, nspanel); TJC has no "serial received" callback, so timer polling is the standard workaround. |
| `ussp` | Auto-sleep timeout with no serial activity. |
| `volume` | Audio volume. |
| `wup` | Page-refresh behaviour after waking from sleep. |

### Hidden functions (reached only via `sets "name: args"` / `gets "name"`, 36 entries)

| Name | Description |
|---|---|
| `hexcrc` | Reads/writes a flag gating the firmware-update header check (`byte_761E9C`); used internally while `whmi-wri` validates the incoming image. |
| `hexver` | Same family as `hexcrc` (`byte_761E9D`), a second update-validation flag. |
| `sfind0` | Returns a status value (`sub_19B88`); purpose not pinned down. |
| `aacom` | Takes one character argument (`'1'` vs anything else) into `sub_19A80`; purpose not pinned down. |
| `registered` | Returns the device’s registration/license status (`dataModel::sub_21214`); related to `getpassw` and the `HMISETPASSWORD15` provisioning command (see `sovol/flash_layout.md`). |
| `systime` | Returns an internal time/uptime counter (`dword_761E6C`). |
| `rprint` | Prints a variable’s value through whichever port `umport`/`printport` currently selects. |
| `uwritef` | Writes N bytes (read via the flash-gated `freadr` path) out the selected port, one encoding. |
| `uwriter` | Same as `uwritef` with a different (raw, not reformatted) encoding. |
| `freadr` | Reads object-attribute data from the SPI flash, but only from offsets at or above a movable floor (`dword_761EBC`, raised by `eepflash`) — below the floor it always returns 0, so the firmware/bootloader region cannot be read back this way once the floor is set past it. |
| `floadr` | Loads a chunk of object-attribute flash data into a buffer in one call (`sub_287AC`), the bulk counterpart of `freadr`. |
| `mwatchc` | Registers a change-callback on a variable (`sub_17510`) — continuous telemetry: the firmware calls back whenever the watched value changes. |
| `mwliner` | Registers a line-oriented reader callback (`sub_17530`), used together with `mwatchc`. |
| `crcputr` | Same checksum engine as `crcputh`/`crcputs`/`crcputu` (`sub_94C4`), result stored into a variable instead of printed. |
| `flashup` | Starts a firmware-update pass from data already resident in memory/EEPROM (sets a `0x88` marker and an address, then calls `save_yingjianavdata(2)`) — the programmatic equivalent of a `whmi-wri` session, sourced from memory instead of fresh serial bytes. |
| `linex` | Reads the next line from the current text source/cursor. |
| `hexref` | Sets a reference/flag byte (`byte_761E9E`); exact effect not pinned down. |
| `ramv` | **Confirmed, used in `tools/screen_bridge.py`.** `sets "ramv: X, Y, path"` draws `ram/`/`sd0/path` at (X, Y), **upright** (the page's external-picture object is 180°), via the `pic`/`xpic` decoder (baseline JPEG or `hmipicxi` raw-RGB565); draw time ≈ `25 ms + 5.5 µs/pixel`. **Answers nothing on the wire** — a `get` right after is the only way to know the draw finished (a file touched before that answer is silently not drawn). `ram/` won't tolerate rewriting the same filename while/soon after a draw: write once, draw, delete that exact file, no intervening write to the same name. |
| `ramw` | **Not tested on hardware.** Reads N bytes (< 4096) of `path` from offset A into a 4096-byte ring buffer (`dword_761398`, wrapping) at offset B, gated by a flag (`byte_77F4E9[290]`) that must already be set elsewhere. `dword_761398` also looks like the base of the serial receive buffer, so this may reuse that RAM as scratch — the size cap and ring-wrap fit feeding a decoder (audio/video) a window of a file rather than a general read API. |
| `picdraen` | Sets a flag (`byte_76212F`) that gates picture-drawing; exact effect (e.g. defer vs. draw immediately) not pinned down. |
| `picdraval` | Sets a related value (`byte_762130`) next to `picdraen`; not pinned down. |
| `dgusver` | Sets a version-like word (`word_761EA0`). Name points to DWIN **DGUS** toolchain origin (T5UID1 platform; see `github.com/juliandroid/DWIN_CR_10s_Pro`). DGUS **II** is the panel's native protocol line (`doc/T5L_DGUSII-...pdf` Ch.4): `5A A5` header, `0x82` write / `0x83` read variable. In the DB, `5A A5` appears exactly twice, both inert rodata fragments (no enclosing function) — write-response `5A A5 03 82 4F 4B` at `0x2f836`, and `5A A5 00 83` at `0x167b0`. The live interface is an **ASCII-keyword** protocol (`process_cmd`), not DGUS II binary — so "DGUS" = toolchain + native mode; exact version-word meaning not pinned. |
| `guiays` | Sets a flag (`byte_77F4E9[2]`); not pinned down. |
| `cpufreq` | **Not tested — potentially risky.** Changes the CPU clock live (`sub_27474`). If the UART baud generator derives from this clock, changing it could desync the serial port until the next command finally lands or the screen is power-cycled. |
| `xnumadd` | Sets a flag (`byte_77F4E9[3]`) for the `xnum` number-display family (e.g. an additive offset applied before formatting); not pinned down precisely. |
| `qqset` | Configures the `showqq` popup/status-icon feature. |
| `eepstate` | Queries/sets the EEPROM controller’s busy/ready state (`sub_277C4`). |
| `bldd` | Sets a flag (`byte_761E9F`); not pinned down (possibly backlight-dimming direction, guessed from the name). |
| `lcdrest` | Resets/reinitializes just the LCD controller (`sub_13F20`), distinct from the full-device `rest`. |
| `iobeep` | (`iobeep 300` -> `invalid instruction` on hardware, syntax unknown.) Pulses the physical buzzer pin directly for a configured duration, gated by a hardware-presence flag (`byte_761EC2`) — the IO-level counterpart of the `beep` instruction, which goes through the audio engine. |
| `tuptime` | Reads/accumulates a total-up-time counter (`dword_761EEC`). |
| `eepflash` | Raises the floor below which `freadr` always returns 0 (a write only takes effect if `value >= dword_761EDC` or `value == 0`, so you can only raise the floor, never lower it past the current content’s own floor); `eepflash=0` disables all reads through `freadr`. This is what stops a `.tft`/firmware read-back from going below the first resource record. Not sent to the screen ourselves, only analysed. |
| `uart2` | Enables a second UART (its own 4096-byte buffer and callback handlers, `sub_2D094`/`sub_2CDA0`/`sub_20AF8`) or disables it (`sub_20AD0`) if the argument is 0 — a second serial channel, separate from the one carrying this whole command protocol. Which physical pins it uses is not known from the decompiled firmware alone. |
| `umport` | Selects which port (`uart2` vs the primary UART) subsequent `uwritef`/`uwriter` target. |
| `printport` | Selects which port subsequent `print`/`rprint`-family output goes to. |
| `mlen` | Sets a byte (`byte_761EA2`) controlling some length/limit; not pinned down. |

## Independent corroboration from another project

The magic-string reset here (`DRAKJHSUYDGBNCJHGJKSHBDN`, sent before `connect` to leave "active parse" mode / `recmod`
and recover a mid-command screen) is exactly what independent Nextion upload libraries (NSPanel-Tasmota driver,
Enhanced-Nextion-Library `NexUpload::Reconnect`, powadcr) send routinely, and what the Ender Pearl project
(`ext/similar_projects/ender-pearl-display/docs/03-custom-firmware.md`) documents as the "protocol reparse" leave-command
for the same `TJC3224T132` family. Same mechanism, different display — a property of the TJC/Nextion firmware, not this
screen's alone.

The `.tft` checksum wall Ender Pearl hit (patch a picture, the file uploads fine, then boots to "System Data ERROR!" because
three 4-byte checksum fields change with any pixel and none is a standard CRC32) is the same wall this project's
`whmi-wri` path hits — see `flash_layout.md` for how the running checksum of the whole file is validated before the `.tft` is
marked valid. Ender Pearl deliberately did not reverse the checksums and rebuilds in the editor; the same choice applies
here.

Their `docs/04-drawing.md` (store each wallpaper 3× as `bg`/`glass`/`focus`, draw panels as an `xpic` crop of `glass`,
draw text with `xstr … sta=0` so the background crops from the same picture) is a design technique independent of the
protocol — useful once a live UI is being built, working around the display's inability to blur at runtime and its
tendency to wrap text wider than its box.

Their full write-up (`ext/similar_projects/ender-pearl-display/SIMILARITY_REPORT.md`) compares this screen's
`TJC4827X243_011C` (800x480, runtime 159, 16 MB flash) against Ender Pearl's `TJC3224T132_011N` (240x320, runtime 68,
8 MB flash): same protocol family, opposite execution (external Pi draws on a TJC display SoC vs. a full bootloader on
this screen's own SoC). Every model/resolution/flash/baud number in their docs is for the other model and must not be
copied.

