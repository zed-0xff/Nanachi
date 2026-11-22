# TJC / Nextion serial-HMI instruction set (official vendor manual)

English translation of the vendor's own serial-HMI help manual
(`ext/similar_projects/TJC-firmware-reverse-engineering/tjc_help.md`, original in Chinese).
It is the **generic, product-line-wide** Nextion/TJC reference. Our screen is one specific build
of the same family (AiHmiT7 firmware 159, `TJC4827X243`); the per-command confidence status for
*our* firmware lives in [`commands.md`](commands.md), where this manual is used as a
confirming/corroborating source (marked there as 📕).

> **Reading note.** The original is the vendor's user manual, written for people wiring a
> microcontroller to the panel. It covers the full command set, the on-screen scripting language,
> the system variables, the return-code formats, and the advanced/low-level protocols (active parse
> mode, the download protocol, command CRC, and the runtime `twfile` chunking). Keep in mind the
> vendor's "X3 / X5 series only" tags refer to *their* product lines; several of those commands are
> actually present in our firmware 159 build — see `commands.md`.

## General notes

1. The device's command terminator is the three bytes `0xFF 0xFF 0xFF` (HEX data, not string data).
2. All command names and parameters are ASCII string data, not HEX, for readability and debugging.
3. All command names use lowercase letters (this refers only to the *name* being lowercase; a
   parameter that should be uppercase still is).

---

## 1. Object & system-operation instructions

### Summary table

| # | Command | Function | Parameters |
|---|---------|----------|------------|
| 1  | `page`    | Refresh a page                       | `page pageid` |
| 2  | `ref`     | Redraw a control                     | `ref obj` |
| 3  | `click`   | Fire a control's press/release event | `click obj,event` |
| 4  | `get`     | Get a variable/constant value, formatted | `get att` |
| 5  | `prints`  | Print a variable/constant over serial | `prints att,lenth` |
| 6  | `printh`  | Print a HEX over serial              | `printh hex` |
| 7  | `vis`     | Hide / show a control                | `vis obj,state` |
| 8  | `tsw`     | Control touch enable                 | `tsw obj,state` |
| 9  | `randset` | Random-number range setting          | `randset minval,maxval` |
| 10 | `add`     | Add data to a curve control          | `add objid,ch,val` |
| 11 | `cle`     | Clear data in a curve control        | `cle objid,ch` |
| 12 | `addt`    | Curve data passthrough               | `addt objid,ch,qyt` |
| 13 | `doevents`| Yield system control to screen refresh | no params |
| 14 | `sendme`  | Send the current page ID to serial   | no params |
| 15 | `covx`    | Variable type conversion             | `covx att1,att2,lenth,format` |
| 16 | `strlen`  | String-variable character-length test | `strlen att0,att1` |
| 17 | `btlen`   | String-variable byte-length test     | `btlen att0,att1` |
| 18 | `substr`  | String substring extraction          | `substr att0,att1,star,lenth` |
| 19 | `spstr`   | String split                         | `spstr src,dec,key,index` |
| 20 | `touch_j` | Touch-panel calibration              | no params |
| 21 | `ref_stop`| Pause screen refresh                 | no params |
| 22 | `ref_star`| Resume screen refresh                | no params |
| 23 | `com_stop`| Pause serial-command execution       | no params |
| 24 | `com_star`| Resume serial-command execution      | no params |
| 25 | `code_c`  | Clear the serial command buffer      | no params |
| 26 | `rest`    | Reset (reboot)                       | no params |
| 27 | `wepo`    | Write a variable to the user-storage area | `wepo att,add` |
| 28 | `repo`    | Read from the user-storage area into a variable | `repo att,add` |
| 29 | `wept`    | Passthrough data write to user storage | `wept add,lenth` |
| 30 | `rept`    | Passthrough read from user storage to serial | `rept add,lenth` |
| 31 | `cfgpio`  | Extended-IO mode configuration       | `cfgpio id,state,obj` |
| 32 | `crcrest` | Reset the CRC initial value          | `crcrest crctype,initval` |
| 33 | `crcputs` | CRC a variable/constant              | `crcputs att,length` |
| 34 | `crcputh` | CRC a group of HEX bytes             | `crcputh Hex` |
| 35 | `crcputu` | CRC a serial-buffer segment (valid when `recmod=1`) | `crcputu star,length` |
| 36 | `setlayer`| Change a control's layer order at runtime (X3/X5 only) | `setlayer obj0,obj1` |
| 37 | `move`    | Move a control (X3/X5 only)          | `move obj,starx,stary,endx,endy,first,time` |
| 38 | `play`    | Audio playback (X3/X5 only)          | `play ch,audio,loop` |
| 39 | `twfile`  | Serial passthrough file (X3/X5 only) | `twfile filepath,filesize` |
| 40 | `delfile` | Delete a file (X3/X5 only)           | `delfile filepath` |
| 41 | `refile`  | Rename a file (X3/X5 only)           | `refile srcfilepath,decfilepath` |
| 42 | `findfile`| Find a file (X3/X5 only)             | `findfile filepath,att` |
| 43 | `rdfile`  | Passthrough read file (X3/X5 only)   | `rdfile filepath,addr,size,crc` |
| 44 | `newfile` | Create a file (X3/X5 only)           | `newfile filepath,size` |
| 45 | `newdir`  | Create a folder (X3/X5 only)         | `newdir dir` |
| 46 | `deldir`  | Delete a folder (X3/X5 only)         | `deldir dir` |
| 47 | `redir`   | Rename a folder (X3/X5 only)         | `redir srcdir,decdir` |
| 48 | `finddir` | Find a folder (X3/X5 only)           | `finddir dir,att` |

### Details

**1. `page` — refresh a page.** `page pageid`, `pageid` = page ID or page name. E.g. `page 0`
(refresh page with ID 0), `page main` (refresh page named `main`). Notes: the device auto-refreshes
page 0 on power-up; you can also jump by assigning the system variable `dp` (`dp=0`); `page` is a
*jump* — any code written after it on the same line is ignored and never runs.

**2. `ref` — redraw a control.** `ref obj`, `obj` = control ID or name. E.g. `ref 1`, `ref t0`.
Use it to redraw a control that has been covered by GUI drawing or by another control.

**3. `click` — fire a control's press/release event.** `click obj,event`; `event` 0 = release,
1 = press. E.g. `click b0,1` (press `b0`), `click 2,0` (release control ID 2). These events fire
automatically on touch; use `click` to trigger them manually with no touch.

**4. `get` — get a variable/constant value, formatted.** `get att`, `att` = variable name. E.g.
`get t0.txt` (return `t0`'s `txt`), `get j0.val`, `get "123"` (constant string), `get 123`
(constant number). Notes: a string-typed value returns `0x70` + inner code + terminator; a numeric
value returns `0x71` + 4-byte hex (int) + terminator, little-endian (low byte first). `get` can be
sent over serial or written into editor code (active send; pair with `printh` to prepend a custom
tag identifying which control it belongs to). `get` is like `print` except `get` adds a start marker
(`0x70`/`0x71`) and the terminator, which `print` omits.

**5. `prints` — print a variable/constant over serial.** `prints att,lenth`; `lenth` = send length
(0 = automatic). E.g. `prints t0.txt,0` (send `t0.txt` at its real length), `prints j0.val,0`
(send the 4-byte int, little-endian), `prints "123",0` (0x31 0x32 0x33), `prints 123,0`
(0x7b 0x00 0x00 0x00), `prints 123,1` (low byte only: 0x7b). Notes: a string is returned as its
inner code, a numeric as the raw 4-byte int (little-endian); the device sends *only* the data — no
start marker, no terminator. Pair with `printh` to append a custom tag. `prints` is like `get`
except it has no start marker/terminator, but you may follow it with a `printh` statement.

**6. `printh` — print a HEX over serial.** `printh hex`, `hex` = the hex-string expression of the
bytes to send. E.g. `printh d0 a0` (send 0xd0 0xa0). Notes: only the specified bytes are sent — no
start marker, no spaces, no terminator; exactly one space must separate each byte group; upper- and
lower-case hex are both accepted; `printh` sends constants only (use `prints` for variables).

**7. `vis` — hide / show a control.** `vis obj,state`; `state` 0 or 1. E.g. `vis b0,0` (hide),
`vis b0,1` (show), `vis 1,0`, `vis 1,1`. If the first parameter is **255** it means *all* controls
on the current page: `vis 255,0` (hide all), `vis 255,1` (show all).

**8. `tsw` — control touch enable.** `tsw obj,state`; `state` 0 or 1. E.g. `tsw b0,0` (disable
`b0`'s touch), `tsw b0,1` (enable), `tsw 1,0`, `tsw 1,1`. If the first parameter is **255** it
applies to all controls on the current page.

**9. `randset` — random-number range setting.** `randset minval,maxval`. E.g. `randset 1,100`.
Notes: set the range before using `rand` (default min 0, max 2147483647); each read of `rand` then
yields a random number; once set, the range stays until power-up or reset; the range is a signed int.

**10. `add` — add data to a curve control.** `add objid,ch,val`; `objid` = curve-control ID (must be
an ID, not a name); `ch` = channel; `val` = data (0–255). E.g. `add 1,0,30`, `add 1,1,n0.val`.
Curve data is 8-bit only (0–255); up to 4 curve controls per page, 4 channels each; data can be sent
continuously and the control auto-scrolls; you may change channel foreground/background colours mid-stream.

**11. `cle` — clear data in a curve control.** `cle objid,ch`; `ch` 255 = all channels. E.g.
`cle 1,0`, `cle 1,255` (clear all channels).

**12. `addt` — curve data passthrough.** `addt objid,ch,qyt`; `qyt` = number of passthrough points.
E.g. `addt 1,0,100`. Curve data is 8-bit (0–255); a single passthrough is at most 1024 bytes. After
the passthrough command, wait for the device's response before sending: the device takes ~5 ms to
initialize (longer if the buffer still holds other commands), then sends a ready frame (`0xFE` +
terminator); you then send the raw hex data (no more strings/terminators); once the device has
received the specified amount it returns to command mode, and sends an end marker (`0xFD` +
terminator). The curve does not refresh until the specified count is complete, then it auto-refreshes.

**13. `doevents` — yield system control to screen refresh.** No params. In a long process/loop the
screen won't refresh until the process ends (memory reads/writes still work); `doevents` yields
control so the screen redraws all changed controls, then returns to the process. Prevents a
frozen-looking display. Usually paired with `while`/`for`.

**14. `sendme` — send the current page ID to serial.** No params. The device immediately sends the
current page ID. To auto-send it on every page refresh, put `sendme` in the page's init event.

**15. `covx` — variable type conversion.** `covx att1,att2,lenth,format`; `att1` = source,
`att2` = target, `lenth` = string length (0 = auto, nonzero = fixed), `format` = declare numeric
type (0 = number, 1 = currency, 2 = hex). E.g. `covx h0.val,t0.txt,0,0` (slider `h0`'s value →
decimal string into `t0.txt`), `covx t0.txt,h0.val,0,0` (string → number). `lenth` always refers to
the string length (the target's length when number→string, the source's length when string→number).
Conversion fails if source and target are the same type.

**16. `strlen` — string-variable character-length test.** `strlen att0,att1`; `att0` = the string to
test, `att1` = where to store the result. E.g. `strlen t0.txt,n0.val`. `strlen` counts *characters*
while `btlen` counts *bytes* (a CJK char is 2 bytes by `btlen`, 1 char by `strlen`). The tested
variable must be a string; the target must be numeric, else it errors.

**17. `btlen` — string-variable byte-length test.** `btlen att0,att1`. Same as `strlen` but in bytes
(see 16). E.g. `btlen t0.txt,n0.val`.

**18. `substr` — string substring extraction.** `substr att0,att1,star,lenth`; `att0` = source
string, `att1` = target string, `star` = start position in source, `lenth` = number of characters to
take. E.g. `substr t0.txt,t1.txt,0,2` (copy 2 chars from position 0 of `t0.txt` into `t1.txt`).

**19. `spstr` — string split.** `spstr src,dec,key,index`; `src`/`dec` = source/target strings,
`key` = separator string, `index` = which piece (0-based) to take after splitting `src` on `key`.
E.g. if `data0.txt` = `aaaa^bbbb^cccc^dddd`, then `spstr data0.txt,t0.txt,"^",2` → `t0.txt` = `cccc`.

**20. `touch_j` — touch-panel calibration.** No params. All devices are calibrated at the factory;
normally not needed.

**21. `ref_stop` — pause screen refresh.** No params. While paused, all statements still parse and
execute and attribute writes still happen, but controls don't redraw (any attribute change is stored
but not shown). GUI drawing commands (point/line/circle, etc.) are unaffected and still draw
immediately. Even `ref` won't force a redraw until `ref_star` is executed, when all changed controls
refresh at once.

**22. `ref_star` — resume screen refresh.** No params. Pairs with `ref_stop`.

**23. `com_stop` — pause serial-command execution.** No params. The device keeps *receiving*
commands but does not execute them; they queue in the command buffer until `com_star` arrives, at
which point everything from the paused command to the present runs. Before using pause/resume, make
sure your device's serial buffer size and max command-queue depth can hold the commands you'll buffer
(see the datasheet spec table).

**24. `com_star` — resume serial-command execution.** No params. Executes the queued commands. Same
buffer/queue caveat as `com_stop`.

**25. `code_c` — clear the serial command buffer.** No params. Immediately discards all not-yet-run
commands in the buffer.

**26. `rest` — reset.** No params. (Reboots the device.)

**27. `wepo` — write a variable to the user-storage area (EEPROM).** *(Hardware with user storage.)*
`wepo att,add`; `add` = user-storage address (from 0). E.g. `wepo t0.txt,10` (writes `t0.txt`,
occupying txt-maxl + 1 bytes), `wepo "abcd",10` (occupies 5 bytes), `wepo 125,10` (numeric, 4 bytes).
A string variable occupies its max-char count + 1; a constant string its real length + 1; any numeric
occupies 4 bytes. Plan your data-area layout so regions don't overlap and clobber each other.

**28. `repo` — read from the user-storage area (EEPROM) into a variable.** *(User-storage hardware.)*
`repo att,add`. A string variable reads its max-char count + 1; a numeric reads 4 bytes. E.g.
`repo t0.txt,10`, `repo n0.val,10`. Same overlap caveat as `wepo`.

**29. `wept` — passthrough data write to the user-storage area (EEPROM).** *(User-storage hardware.)*
`wept add,lenth`. E.g. `wept 10,30` (store 30 bytes at address 10, occupying 10–39). Same passthrough
handshake as `addt`: wait for `0xFE` + terminator, send raw hex, device returns to command mode and
sends `0xFD` + terminator.

**30. `rept` — read from the user-storage area and passthrough-send to serial.** *(User-storage
hardware.)* `rept add,lenth`. E.g. `rept 10,30` (read 30 bytes from address 10, passthrough to
serial). Whether the stored data is a string or a number, it is read and sent as hex for the given
byte count, with no terminator.

**31. `cfgpio` — extended-IO mode configuration.** *(Extended-IO hardware.)* `cfgpio id,state,obj`;
`state`: 0 = pull-up input, 1 = control-event-bound input, 2 = push-pull output, 3 = PWM output,
4 = open-drain; `obj` = the bound control's name/ID (only meaningful in mode 1). E.g. `cfgpio 0,0,0`
(io0 pull-up input; read via `pio0`), `cfgpio 1,2,0` (io1 push-pull output; drive via `pio1`),
`cfgpio 2,1,b0` (io2 event-bound: falling edge → `b0` press, rising edge → `b0` release),
`cfgpio 4,3,0` (io4 PWM; set `pwm4` duty first). K0 supports PWM only on io4–io7; X5 only io6–io7.
For event-bound input the control must be on the *current* page at configure time (other pages and
even global-memory controls can't be bound); the binding stops after a page refresh/switch, so re-bind
on every refresh (best in the page's init event).

**32. `crcrest` — reset the CRC initial value.** `crcrest crctype,initval`; `crctype` must be 1
(Modbus CRC16); `initval` usually `0xffff`. E.g. `crcrest 1,0xffff`. After reset, use `crcputs` /
`crcputh` / `crcputu` to checksum data, then read `crcval` for the result.

**33. `crcputs` — CRC a variable/constant.** `crcputs att,length`; `length` 0 = auto. E.g.
`crcputs t0.txt,0`, `crcputs "abc",0`. Read `crcval` for the result (see 32).

**34. `crcputh` — CRC a group of HEX.** `crcputh Hex`; bytes space-separated. E.g. `crcputh 03 25`.
Read `crcval` for the result.

**35. `crcputu` — CRC a serial-buffer segment (valid when `recmod=1`).** `crcputu star,length`.
E.g. `crcputu 0,22` (checksum the first 22 bytes of the serial buffer). Read `crcval` for the result.

**36. `setlayer` — change a control's layer order at runtime.** *(X3/X5 only.)*
`setlayer obj0,obj1`; `obj0` = control to move; `obj1` = place `obj0` above this control; `obj1` 0 =
send `obj0` to the very bottom, `obj1` 255 = send to the very top. E.g. `setlayer n0,b0`,
`setlayer n0,255`.

**37. `move` — move a control.** *(X3/X5 only.)* `move obj,starx,stary,endx,endy,first,time`;
`first` = priority (0–100, higher first); `time` = move duration in ms. E.g. `move t0,0,0,200,200,0,300`
(t0 moves (0,0)→(200,200) over 300 ms). Several `move` commands at different priorities can be issued
together; the system moves them in priority order, finishing one before starting the next.

**38. `play` — audio playback.** *(X3/X5 only.)* `play ch,audio,loop`; `ch` = audio channel,
`audio` = audio ID, `loop` = loop or not. E.g. `play 1,3,0` (play audio 3 on channel 1, no loop).
`play` only configures/starts playback — pause/stop via the `audio0`/`audio1` system variables. The
controlled channels are independent of any video's audio channels (no conflict). Audio playback is
global, not page-scoped: it keeps playing across page jumps; to stop on leaving a page, use
`audio0`/`audio1` in that page's leave event.

**39. `twfile` — serial passthrough file.** *(X3/X5 only.)* `twfile filepath,filesize`; `filepath`
e.g. `"ram/0.jpg"` or `"sd0/a.jpg"`. E.g. `twfile "ram/0.jpg",10345`, `twfile "sd0/a.jpg",10345`.
The in-memory file system must be sized in the project settings first (default 0 = unavailable). The
detailed chunking logic is in section 7.5 below.

**40. `delfile` — delete a file.** *(X3/X5 only.)* `delfile filepath`. E.g. `delfile "ram/0.jpg"`,
`delfile "sd0/a.jpg"`.

**41. `refile` — rename a file.** *(X3/X5 only.)* `refile srcfilepath,decfilepath`. E.g.
`refile "ram/0.jpg","ram/1.jpg"`, `refile "sd0/a.jpg","sd0/b.jpg"`.

**42. `findfile` — find a file.** *(X3/X5 only.)* `findfile filepath,att`; `att` = numeric variable to
receive the result (0 = not found, 1 = found). E.g. `findfile "ram/0.jpg",va0.val`,
`findfile "sd0/a.jpg",sys0`.

**43. `rdfile` — passthrough read file.** *(X3/X5 only.)* `rdfile filepath,addr,size,crc`; `addr` =
start address, `size` = bytes to read (**0** = return the file size as a 4-byte little-endian int),
`crc` = trailing-checksum setting (0 = none, 1 = CRC16, 10 = CRC32). E.g. `rdfile "ram/0.jpg",0,10,1`
(read 10 bytes from offset 0, append a 2-byte CRC16 → 12 bytes total), `rdfile "sd0/a.jpg",0,10,10`
(10 bytes + 4-byte CRC32 → 14 bytes). CRC16 is MODBUS CRC16; CRC32 is standard CRC32.

**44. `newfile` — create a file.** *(X3/X5 only.)* `newfile filepath,size`; `size` in bytes (max
2147483647). E.g. `newfile "ram/0.txt",4096`, `newfile "sd0/1.txt",4096`.

**45. `newdir` — create a folder.** *(X3/X5 only.)* `newdir dir`, e.g. `newdir "sd0/a/"`. The
in-memory file system does not support subdirectories; the SD card does; the path must end with `/`.

**46. `deldir` — delete a folder.** *(X3/X5 only.)* `deldir dir`, e.g. `deldir "sd0/a/"`. Same
subdirectory rules as `newdir`.

**47. `redir` — rename a folder.** *(X3/X5 only.)* `redir srcdir,decdir`, e.g. `redir "sd0/a/","sd0/b/"`.

**48. `finddir` — find a folder.** *(X3/X5 only.)* `finddir dir,att`; `att` = numeric variable for the
result (0 = not found, 1 = found). E.g. `finddir "sd0/a/",sys0`.

---

## 2. GUI drawing instructions

Use these when the editor software cannot produce a display effect you need; most applications don't
require them and can be done with editor controls alone.

| # | Command | Function | Parameters |
|---|---------|----------|------------|
| 1  | `cls`  | Clear the screen        | `cls color` |
| 2  | `pic`  | Blit a picture          | `pic x,y,picid` |
| 3  | `picq` | Crop & blit a picture   | `picq x,y,w,h,picid` |
| 4  | `xpic` | Advanced crop & blit    | `xpic x,y,w,h,x0,y0,picid` |
| 5  | `xstr` | Write text              | `xstr x,y,w,h,fontid,pointcolor,backcolor,xcenter,ycenter,sta,string` |
| 6  | `fill` | Fill a rectangle        | `fill x,y,w,h,color` |
| 7  | `line` | Draw a line             | `line x,y,x2,y2,color` |
| 8  | `draw` | Draw a (hollow) rectangle | `draw x,y,x2,y2,color` |
| 9  | `cir`  | Draw a hollow circle    | `cir x,y,r,color` |
| 10 | `cirs` | Draw a filled circle    | `cirs x,y,r,color` |

**1. `cls` — clear the screen.** `cls color`; `color` = decimal colour value or a colour code. E.g.
`cls 1024`, `cls RED`. Every colour parameter in this manual may use a colour code or a decimal value
(see the colour-code table in section 4).

**2. `pic` — blit a picture.** `pic x,y,picid`. E.g. `pic 10,20,0` (draw resource picture 0 at
(10,20)).

**3. `picq` — crop & blit a picture.** `picq x,y,w,h,picid`; `x,y` = screen destination, `w,h` =
region size, `picid` = picture ID. E.g. `picq 20,50,30,20,0`. The picture must be a *full-screen*
picture, otherwise the crop won't be what you expect (the picture's crop region and the screen's
display region overlap).

**4. `xpic` — advanced crop & blit.** `xpic x,y,w,h,x0,y0,picid`; `x,y` = screen destination, `w,h`
= region size, `x0,y0` = source position in the picture. E.g. `xpic 20,50,30,20,40,15,0` (crop a
30×20 region from picture 0 at (40,15), draw at screen (20,50)).

**5. `xstr` — write text.** `xstr x,y,w,h,fontid,pointcolor,backcolor,xcenter,ycenter,sta,string`;
`xcenter`/`ycenter` 0 = left/top, 1 = middle, 2 = right/bottom; `sta` = background fill: 0 = crop,
1 = solid colour, 2 = picture, 3 = none (when `sta` is crop/picture, `backcolor` is a picture ID).
E.g. `xstr 0,0,100,30,1,RED,BLACK,1,1,1,"中国"` (font 1, region (0,0) 100×30, text "中国", red on
black, centred both ways). Text that runs past `w` wraps; any characters left after wrapping past
`h` are dropped.

**6. `fill` — fill a rectangle.** `fill x,y,w,h,color`. E.g. `fill 0,0,100,30,RED`.

**7. `line` — draw a line.** `line x,y,x2,y2,color`. E.g. `line 0,0,100,100,RED`.

**8. `draw` — draw a rectangle.** `draw x,y,x2,y2,color`. E.g. `draw 0,0,100,100,RED`. `draw` makes a
*hollow* rectangle; for a filled one use `fill`.

**9. `cir` — draw a hollow circle.** `cir x,y,r,color` (x,y = centre, r = radius). E.g.
`cir 100,100,30,RED`.

**10. `cirs` — draw a filled circle.** `cirs x,y,r,color`. E.g. `cirs 100,100,30,RED`.

---

## 3. HMI writing syntax

### 3.1 Assignment

Assignments can be written into a control's event in the editor, or sent over serial (remember the
`FF FF FF` terminator).

*String attributes:*

```
t0.txt = "123"      // set t0.txt to "123"
t0.txt = t1.txt     // copy t1.txt into t0.txt
```

Wrong: `t0.txt = 123` (a string attribute needs a *quoted* constant); `t0.txt = h0.val` (a numeric
value can't be assigned to a string attribute).

*Numeric attributes:*

```
n0.val = 123        // set n0.val to 123
n0.val = h0.val
dim    = 80         // backlight immediately becomes 80
baud   = 115200     // baud immediately becomes 115200
n0.val = baud
```

Wrong: `n0.val = "123"` (a numeric attribute must not be quoted); `n0.val = t0.txt` (a string value
can't be assigned to a numeric attribute).

Only the `txt` attribute is a string; every other attribute is numeric. Convert between them with
`covx`.

### 3.2 Arithmetic

No operator precedence and no parentheses — everything evaluates **strictly left to right**.

*Numeric variables:* operators `+ - * / % & | ^ << >>`, plus `++`, `--`, `+=`, `*=`, etc.

```
n0.val = n0.val + n1.val + 2
n0.val++
n0.val += 2
n0.val = n1.val % 3
```

Wrong: `n0.val = t0.txt + 1`, `n0.val = 1 + "2"` (numeric must operate on numeric, assigned to a
numeric).

*String variables:*

`+` concatenates (string + string only). Wrong: `t0.txt = 1 + 2` (numeric constants),
`t0.txt = t0.txt + h0.val` (numeric variable).

`-` *deletes* characters: `t0.txt = t0.txt - 1` (drop the last char), `t0.txt -= n0.val` (drop
`n0.val` chars). For strings, `-` means "delete N characters", so it must subtract a numeric,
unlike `+` which requires string + string.

### 3.3 Cross-page control-attribute access

To operate a control on *another* page, use `[page].[control].[attribute] = value`:

```
main.t0.txt = "123"
main.t0.txt = set.t3.txt
set.t4.txt = "abc"
```

Important: whether reading or writing a cross-page control, that control's `vscope` attribute must be
set to *global* (default is private), otherwise the operation fails.

### 3.4 HMI logic statements

Logic statements can only be written into a control's event in the editor — they **cannot be sent
over serial**.

**`if`**

```
if (t0.txt == "123456") { page 1 }
if (t0.txt != "a" && t0.txt != "b") { page 1 }
if (t0.txt == "a" || t0.txt == "b") { page 1 }
// toggle b0.txt between "start" and "stop":
if (b0.txt == "start") { b0.txt = "stop" } else { b0.txt = "start" }
```

Numeric variables support `> < == != >= <=`; strings support only `== !=`. No parenthesis
precedence in the condition (e.g. `if((a||b)&&c)` is **not** supported); avoid extra spaces; and no
arithmetic inside the test (e.g. `if(n0.val+2==3)` is not supported).

**`while`**

```
while (n0.val < 100) { n0.val++ }                      // screen does NOT refresh during the loop
while (n0.val < 100) { n0.val++; doevents }           // screen refreshes each iteration
```

While a long process/loop holds control, memory reads/writes still work but the screen won't redraw;
`doevents` yields to the refresh. During a `while` loop the device does not respond to touch; serial
commands are received into the buffer but not executed until the process finishes — use carefully to
avoid an infinite loop.

**`for`**

```
for (n0.val = 0; n0.val < 100; n0.val++) { }          // screen does NOT refresh
for (n0.val = 0; n0.val < 100; n0.val++) { doevents } // screen refreshes
```

Same notes as `while`.

---

## 4. System variables

All names are lowercase.

| # | Name | Meaning | Example / notes |
|---|------|---------|-----------------|
| 1  | `dp`     | Current page ID | `dp=1` (same as `page 1`); `prints dp,0`; `n0.val=dp` |
| 2  | `dim`    | Current backlight (0–100) | `dim=50`; `dim=dim+10`; `dim=dim-10` |
| 3  | `dims`   | Power-on default backlight (0–100) | `dims=50` |
| 4  | `baud`   | Current baud rate (lost on power-down) | `baud=9600`; supported: 2400 4800 9600 19200 38400 57600 115200 230400 256000 512000 921600 |
| 5  | `bauds`  | Power-on default baud (saved, persists) | `bauds=9600` |
| 6  | `spax`   | Horizontal char spacing (power-on 0) | `spax=2`; affects only `xstr` text (control text spacing is set by the control) |
| 7  | `spay`   | Vertical char spacing (power-on 0) | `spay=2`; same as `spax` |
| 8  | `thc`    | Pen colour while touch-drawing | `thc=RED`; `thc=1024` |
| 9  | `thdra`  | Touch-drawing switch | `thdra=0` (off); `thdra=1` (on) |
| 10 | `ussp`   | Auto-sleep after no serial data (sec, 3–65535, power-on 0 = off) | `ussp=30` |
| 11 | `thsp`   | Auto-sleep after no touch (sec, 3–65535, power-on 0 = off) | `thsp=30` |
| 12 | `thup`   | Touch auto-wake in sleep (power-on 0) | `thup=0` (no wake); `thup=1` (wake); touch coords are still sent while asleep either way |
| 13 | `usup`   | Serial-data auto-wake in sleep (power-on 0) | `usup=0` (need `sleep=0`); `usup=1` (any serial data wakes immediately) |
| 14 | `wup`    | Which page to refresh after sleep-wake | `wup=255` (default: the pre-sleep page); `wup=2` (refresh page 2); assignable even while asleep |
| 15 | `sleep`  | Sleep state | `sleep=0` (exit); `sleep=1` (enter); in sleep only `get`/`print`/`printh` execute, plus `sleep=1` and `wup=X` assignments, and host-editor online; other commands don't run; an event-bound IO won't fire in sleep |
| 16 | `bkcmd`  | Serial result return (power-on default 2) | `0` none, `1` success only, `2` failure only, `3` both; affects serial-command result returns only; editor-written code always returns on error and never on success; does not affect control-data `get` returns |
| 17 | `sendxy` | Real-time touch-coordinate send | `sendxy=0` (off); `sendxy=1` (on) — on press the device sends touch coords |
| 18 | `delay`  | Delay | `delay=100` (pause 100 ms); the CPU runs no command during the delay but still buffers incoming serial |
| 19 | `rand`   | Random number | `dim=rand`; `n0.val=rand`; set the range with `randset` first (default 0..2147483647); range persists until power/reset |
| 20 | `tch0-3` | Live touch coordinates | `tch0` = current X, `tch1` = current Y, `tch2` = last-press X, `tch3` = last-press Y; read-only; 0 when not touching |
| 21 | `addr`   | Device address | `addr=256` / `addr=0x0100` (same); saved on power-down; valid range 256–2815 (0x0100–0x0aff); 0 = no address, 65535 = broadcast (broadcast is send-only, never a configured device address; factory default 0). To address a device, prepend a 2-byte little-endian address: `addr=256` → prefix `0x00 0x01` (note: config is `0x0100` but sent low-byte-first) |
| 22 | `crcval` | CRC result (read-only; reset with `crcrest` first) | `n0.val=crcval`; `prints crcval,2` |
| 23 | `rtc0-6` | RTC clock (RTC hardware) | `n0.val=rtc5`; `rtc0=2016`; `cov rtc5,t0.txt,0`; rtc0-6 = year, month, day, hour, min, sec, weekday; rtc6 (weekday) is read-only, auto-computed |
| 24 | `pio0-7` | Extended IO (ext-IO hardware) | `pio4=1`; `n0.val=pio2`; `cov pio3,t0.txt,0`; must `cfgpio` first; power-on default all IO = pull-up input (50 kΩ) |
| 25 | `pwm4-7` | Extended-IO duty cycle (ext-IO; K0 PWM on io4-7, X5 on io6-7) | `pwm6=30`; `pwm7=90`; duty 0–100, power-on 50; map io4-7; enable via `cfgpio` PWM mode; duty can be changed during output without reconfig |
| 26 | `pwmf`   | PWM output frequency (ext-IO) | `pwmf=1024`; unit Hz, range 1–65535, power-on 1000 Hz; one shared frequency for all PWM outputs |
| 27 | `eql,eqm,eqh` | Audio EQ: bass (31–125 Hz), mid (250–2000 Hz), treble (4000–16000 Hz) (audio hardware; host simulator unsupported) | range 0–15: 0–6 attenuation (smaller = more cut), 7 flat, 8–15 boost; the system operates on eq0–eq9; editing eql/eqm/eqh is equivalent to editing eq0-2/eq3-6/eq7-9, but editing eq0-9 does not change eql/eqm/eqh |
| 28 | `eq0-eq9` | Independent-frequency-point EQ (audio hardware; host simulator unsupported) | eq0@31 eq1@62 eq2@125 eq3@250 eq4@500 eq5@1000 eq6@2000 eq7@4000 eq8@8000 eq9@16000 Hz; same 0–15 rule as above |
| 29 | `volume` | System volume (0–100, audio hardware) | `volume=60`; auto-saved, persists after power-off |
| 30 | `audio0,1` | Audio channel state (audio hardware) | `0` = stop, `1` = play, `2` = pause; e.g. `audio0=2` (pause ch0), `audio0=0` (stop), `audio1=1` (resume); you can only resume a *paused* channel (a stopped channel must be started again via `play`); playback is global across pages |

### Colour-code table

All codes are uppercase.

| Code | Decimal | Colour |
|------|---------|--------|
| `RED`    | 63488 | Red |
| `BLUE`   | 31    | Blue |
| `GRAY`   | 33840 | Gray |
| `BLACK`  | 0     | Black |
| `WHITE`  | 65535 | White |
| `GREEN`  | 2016  | Green |
| `BROWN`  | 48192 | Orange |
| `YELLOW` | 65504 | Yellow |

---

## 5. Device return-data formats

Terminator is `FF FF FF` in all cases.

### 5.1 Success / failure notifications

Returned only when `bkcmd` is nonzero (default after power-up is 2 = failure only). Code written in
the editor is **not** affected by `bkcmd`: it always returns on error, never on success.

| First byte | Meaning | When |
|-----------|---------|------|
| `0x00` | Invalid instruction | an unrecognized/invalid user instruction was received |
| `0x01` | Instruction executed successfully | a user instruction completed successfully |
| `0x02` | Invalid control ID | the instruction contains an invalid control ID or name |
| `0x03` | Invalid page ID | the instruction contains an invalid page ID or name |
| `0x04` | Invalid picture ID | the instruction contains an invalid picture ID |
| `0x05` | Invalid font ID | the instruction contains an invalid font ID |
| `0x06` | File operation failed | a file operation failed |
| `0x09` | CRC check failed | a checksummed instruction failed validation |
| `0x11` | Invalid baud-rate setting | a baud config with an unsupported value (supported: 2400 4800 9600 19200 38400 57600 115200) |
| `0x12` | Curve-control ID/channel invalid | an `add` whose curve ID or channel is invalid |
| `0x1A` | Invalid variable name | a bad variable name was received (a control attribute is also a variable; an unknown attribute name returns this) |
| `0x1B` | Invalid variable operation | e.g. `t0.txt=abc` (should be `"abc"`), `j0.val="50"`/`j0.val=abc` (a numeric value must be unquoted) |
| `0x1C` | Assignment failed | an attribute assignment failed |
| `0x1D` | EEPROM operation failed | a user-storage operation failed |
| `0x1E` | Invalid parameter quantity | the instruction's argument count is wrong |
| `0x1F` | IO operation failed | an IO operation failed |
| `0x20` | Escape character used incorrectly | bad use of an escape character |
| `0x23` | Variable name too long | a variable name exceeds 29 characters |
| `0x24` | Serial buffer overflow | the serial buffer is full; queued commands run to free space, meanwhile incoming data is dropped |

### 5.2 Other data

These are **not** affected by `bkcmd`.

| First byte | Meaning | Format |
|-----------|---------|--------|
| `0x65` | Touch hot-zone event | `0x65` + pageID + controlID + touchEvent + terminator (when a user control with "send key value" checked is pressed/released; press = `0x01`, release = `0x00`). E.g. `0x65 0x00 0x02 0x01 FF FF FF` = page 0, control 2, pressed |
| `0x66` | Current page ID | `0x66` + pageID + terminator (on `sendme`). E.g. `0x66 0x02 FF FF FF` = page 2 |
| `0x67` | Touch coordinates | `0x67` + Xhi + Xlo + Yhi + Ylo + touchEvent + terminator (when `sendxy=1` on a touch; press = `0x01`, release = `0x00`). E.g. `0x67 0x00 0x7A 0x00 0x1E 0x01 FF FF FF` = (122,30) pressed |
| `0x68` | Sleep-mode touch event | `0x68` + Xhi + Xlo + Yhi + Ylo + touchEvent + terminator (a touch while the device is asleep) |
| `0x70` | String variable data | `0x70` + content ASCII + terminator (a `get` of a string). E.g. `0x70 61 62 63 FF FF FF` = "abc" |
| `0x71` | Numeric variable data | `0x71` + 4-byte little-endian + terminator (a `get` of a number). E.g. `0x71 66 00 00 00 FF FF FF` = 102 |
| `0x86` | Device auto-entered sleep | only on *automatic* sleep, not on a `sleep=1` command |
| `0x87` | Device auto-wake | only on *automatic* wake, not on a `sleep=0` command |
| `0x88` | System started | sent after power-on initialisation succeeds |
| `0x89` | SD-card upgrade start | sent when the device detects an SD card at power-on and enters the upgrade UI |
| `0xFD` | Passthrough data complete | sent when a passthrough finishes and is processed |
| `0xFE` | Data passthrough ready | sent after the device finishes initialising a passthrough — you may now send the raw data |

---

## 6. Name-group usage

The normal (recommended) way to address a control is by name:

```
t0.txt = "123"
n0.val = 15
z0.val = 185
```

When you only know a control's **ID** (not its name), use the name groups.

*Control name group* — `b[controlID].attr`:

```
b[5].txt = "123"          // current page, control ID 5
b[n0.val].txt = "123"     // current page, control ID = n0.val
```

*Page name group* — `p[pageID].b[controlID].attr`:

```
p[2].b[4].txt = "456"
p[n0.val].b[n1.val].txt = "456"
```

(You must ensure the referenced control actually has that attribute, or the assignment fails.)

*Batch via `for`* — load consecutive EEPROM values (from address 100) into numeric controls n0–n9
(IDs 5–14):

```
sys1 = 100
for (sys0 = 5; sys0 <= 14; sys0++) {
    repo b[sys0].val, sys1   // read 4 bytes from EEPROM
    sys1 += 4                // next numeric is 4 bytes on
}
```

Control IDs are assigned automatically by the editor in the order you place controls (not manually
editable). Using the "bring to front" / "send to back" toolbar actions changes a control's ID,
because layer order is tied to the ID: the smallest ID is at the bottom (so page IDs start at 0) and
the largest at the top.

---

## 7. Advanced applications & special instructions

Most projects don't need these; skip if yours doesn't.

### 7.1 Active parse mode

The screen is *passive* by power-up: it executes standard instruction-set commands. If you need a
custom protocol, set it to **active parse mode**. The relevant pieces: the `recmod` variable, the
`usize` variable, the `u[index]` buffer group, the `ucopy` command, and the exit password.

**`recmod`** — 0 = passive, 1 = active. At power-up `recmod=0`. Set it to 1 (e.g. in the power-on
default page's init event) to enter active mode: all *serial* commands are then **not executed**
(editor-written firmware code in events still runs normally) and all serial data is stored in the
serial buffer for you to read actively. After reading, delete the consumed bytes with `udelete`,
otherwise a full buffer stops further reception. Note: if you connect the host simulator while the
screen is in active mode, the screen is forced out of active mode; you must power-cycle to reconnect.

**`usize`** — read-only; the number of bytes currently buffered in the serial buffer.

**`u[index]`** — the serial-buffer byte array, indexed. You can pull single bytes:

```
n0.val = u[0]                       // 1 byte
// 2 bytes little-endian:
n0.val = u[1]; n0.val <<= 8; n0.val += u[0]
// 4 bytes little-endian:
n0.val = u[3]; n0.val <<= 8; n0.val += u[2]
n0.val <<= 8; n0.val += u[1]; n0.val <<= 8; n0.val += u[0]
```

**`ucopy`** — `ucopy att,srcstar,lenth,decstar`: copy `lenth` bytes from buffer position `srcstar`
into target variable `att` at offset `decstar` (valid in `recmod=1`). The target may be a string or a
numeric variable.

```
n0.val = 0
ucopy n0.val, 0, 4, 0     // 4-byte value into n0.val
udelete 4                 // drop the 4 consumed bytes (later bytes slide up)
```

Numeric variables are always 4 bytes, so before copying fewer than 4 bytes, zero the variable first
(e.g. `n0.val=0` before `ucopy n0.val,0,2,0`) or the untouched high bytes will corrupt the result
(use `decstar=2` to place a 2-byte value in the high 16 bits).

```
if (usize >= 10) {
    ucopy t0.txt, 0, 10, 0
    udelete 10
}
```

Important: `code_c` clears the whole buffer and may discard not-yet-read data; in active mode prefer
`udelete` over `code_c`. All of these are firmware statements written in the editor — once in active
mode, serial commands no longer run, so only firmware code can read the buffer.

**Exiting active parse mode** — normally by writing `recmod=0` in an event. Over serial, `recmod=0`
does nothing; instead send a 24-byte exit password (uppercase string) followed by the 3-byte
terminator (27 bytes total):

```
DRAKJHSUYDGBNCJHGJKSHBDN
FF FF FF
```

### 7.2 HMI download protocol

For building your own downloader or having an MCU drive the resource download. The official
open-source tool is `TFTFileDownload`.

*Step 1 — connect / search.* Send `connect` + terminator to each serial port at each baud; the
matched device answers with its connect data. Because you're looping, the first instruction at the
correct baud usually has a garbage prefix, so send **two** instructions per attempt: first a 4-byte
HEX empty command (`00 FF FF FF`), then `connect` + terminator. After each attempt wait at least
`(1000000/baud + 30)` ms (e.g. 9600 → 134 ms). Connect-data example (`TJC4024T032_011R`):

```
comok 1,101,TJC4024T032_011R,52,61488,D264B8204F0E1828,16777216
```

| Field | Meaning |
|-------|---------|
| `comok` | handshake reply |
| `1` | has touch (0 = none) |
| `101` | reserved internal data |
| `TJC4024T032_011R` | model |
| `52` | firmware version |
| `61488` | MCU internal code |
| `D264B8204F0E1828` | unique serial number |
| `16777216` | flash size (bytes) |

*Step 2 — start the download.* Send `whmi-wri filesize,baud,res0` (filesize = `.tft` bytes; baud =
the forced download baud; res0 = any reserved ASCII char). E.g. `whmi-wri 10000,115200,0`; then switch
the host to that baud if it differs. After ~250 ms the device returns a single-byte `0x05` (no
terminator, at the forced baud); you then stream the `.tft` bytes in **4096-byte chunks** (last chunk
= the remainder), each acknowledged by a single-byte `0x05`.

### 7.3 Adding a CRC to a serial command

*(Host software 0.56 and later.)* Normally no checksum is needed; enable it only if your project
requires strict integrity. No configuration is needed — you just change the command; one command may
be checksummed and the next not.

1. **Change the terminator.** Normal = `FF FF FF`; with checksum = `FE FE FE`.
2. **CRC16 algorithm** — MODBUS CRC16. The data to checksum is the whole instruction (from the
   address bytes if addressed, else from the first byte); the terminator is *not* included. Reference:

```c
static U8  InvertUint8(U8  data) {
    int i; U8  newtemp8 = 0;
    for (i = 0; i < 8;  i++)
        if (data & (1 << i)) newtemp8 |= (U8)(1 << (7 - i));
    return newtemp8;
}
static U16 InvertUint16(U16 data) {
    int i; U16 newtemp16 = 0;
    for (i = 0; i < 16; i++)
        if (data & (1 << i)) newtemp16 |= (U16)(1 << (15 - i));
    return newtemp16;
}
U16 CRC16_MODBUS(U8 *data, int lenth) {
    int i;
    U16 wCRCin = 0xFFFF, wCPoly = 0x8005, wChar = 0;
    while (lenth > 0) {
        wChar = *data++;
        wChar = InvertUint8(wChar);
        wCRCin ^= (U16)(wChar << 8);
        for (i = 0; i < 8; i++)
            wCRCin = (wCRCin & 0x8000) ? (U16)((wCRCin << 1) ^ wCPoly)
                                       : (U16)(wCRCin << 1);
        lenth--;
    }
    return InvertUint16(wCRCin);
}
```

3. **Where the CRC goes** — insert, between the instruction and the terminator, a 2-byte CRC16 (HEX,
   little-endian) plus a 1-byte constant `0x01` — i.e. 3 bytes. If the checksum fails, the screen
   returns `0x09 FF FF FF`.

### 7.4 Using CRC to checksum data in a program

*(Host software 1.60.1 and later.)*

Send two constant groups with a trailing MODBUS CRC16:

```
crcrest 1,0xffff          // reset CRC
crcputs "hex date is: ",0 // checksum the string
crcputh 03 25            // checksum the hex bytes
prints "hex date is: ",0  // send the string
printh 03 25             // send the hex bytes
prints crcval,2          // send the 2-byte CRC result
```

Send two variable groups:

```
crcrest 1,0xffff
crcputs t0.txt,0
crcputs n0.val,0
prints t0.txt,0
prints n0.val,4
prints crcval,2
```

In active parse mode, checksum the serial buffer and show pass/fail in `t0.txt`:

```
if (usize >= 24) {
    crcrest 1,0xffff
    crcputu 0,22          // checksum the first 22 buffer bytes
    sys0 = 0              // sys0 is 4 bytes; the CRC is only 2, zero the rest
    ucopy sys0,22,2,0     // copy the received 2-byte CRC into sys0
    if (sys0 == crcval) { t0.txt = "pass" } else { t0.txt = "fail" }
    udelete 24            // drop the 24 processed bytes
}
```

### 7.5 Transferring an image over serial at runtime

*(Host software 0.56 and later.)* For memory: configure the in-project memory-filesystem size first
(default 0 = none). For SD: the card must be FAT32, max 32 GB. The official tool is `SerialFileUp`.

Use the "external picture" control and set its `path` to `ram/0.jpg` or `sd0/0.jpg`. Supported image
formats: **jpg** (must be baseline DCT, else it won't display; pre-rotate to match the screen
orientation — 0° as-is, 90° rotate clockwise 90°, etc.) and **xi** (the HMI-specific format, supports
transparency, recommended; obtain via the "PictureBox conversion" tool). Only these two.

**Protocol.**

*Step 1* — `twfile filepath,filesize` (e.g. `twfile "ram/a.jpg",3282`, `twfile "sd0/a.jpg",3282`).
The screen immediately creates a file of that size at the target path. On success it returns
`0xFE` + terminator (entering passthrough mode — you can start chunking). On failure it returns
`0x06` + terminator and stays in command mode.

*Step 2* — chunked passthrough. Each packet = **header + data**.

The 12-byte header is:

```
3A A1 BB 44 7F FF FE  <checksum-type:1>  <packet-ID:2>  <data-size:2>
```

- **checksum-type**: `0x00` none, `0x01` CRC16 (MODBUS), `0x0A` standard CRC32.
- **packet-ID**: starts at 0, increments by 1 per successfully transmitted packet.
- **data-size**: your choice, 1–4096 bytes (excludes the 12-byte header, *includes* the CRC).

The data is the file bytes + the CRC (little-endian); no CRC for the no-checksum case, 2 bytes for
CRC16, 4 for CRC32. After a fully received packet, the screen returns `0x05` (single byte, no
terminator) on success, and `0x04` (single byte, no terminator) if the packet ID isn't in sequence or
the data is bad. After all packets it returns `0xFD` + terminator and auto-exits passthrough to
command mode. To retry a failed packet (>500 ms no response, or a checksum-fail), resend it **without**
incrementing its ID. To abort mid-way, send a packet with ID `65535`, no checksum, size 0 —
`3A A1 BB 44 7F FF FE 00 FF FF 00 00` — and the screen force-ends the passthrough and returns
`0xFD` + terminator. (If your file data happens to contain the abort pattern, don't worry: the
required ≥20 ms pause before it won't be met, so it is stored as data, not treated as an abort.)

---

## 8. Device ↔ serial-screen communication protocol

### 8.1 Passive parse mode

By default the complete on-wire format is a *string command* + three `FF` bytes. If the screen
receives an incomplete or wrong instruction it returns data (e.g. `1A FF FF FF`, `1C FF FF FF`); this
return can be enabled/disabled with the `bkcmd`/command-return setting (recommended: find and fix the
error cause first, then silence the return).

*Text-control example.* (1) Create a text control `t0` in the host project and download it. (2) Wire
the screen's serial to the MCU (same baud; MCU RX ↔ screen TX, MCU TX ↔ screen RX). (3) Send the
command in string mode: `t0.txt="六六六"`. (4) Send the terminator in HEX mode: `FF FF FF`. (5) `t0`
now shows "六六六".

*Numeric-control example.* Same, but send `n0.val=666` then `FF FF FF`; `n0` shows "666".

*MCU sending a variable (C example).*

```c
printf("n0.val=666");                  // command
printf("\xff\xff\xff");                // terminator
printf("n0.val=666\xff\xff\xff");      // command + terminator
printf("n0.val=%d\xff\xff\xff", MyData);   // one call
printf("t0.txt=\"%d\"\xff\xff\xff", MyTxt);
```

(HEX bytes use the `\xff` escape.)

### 8.2 Active parse mode

By default the format is a string command + three `FF`. Setting `recmod=1` puts the screen in active
parse mode (custom protocol). Notes: (1) in active mode only the **timer** control can parse data,
and its fastest parse interval is 50 ms; (2) in active mode no serial command is executed — everything
is buffered for active reading; (3) prefer the screen's default protocol; only use active mode if the
device genuinely cannot follow it.

### 8.3 Screen sending data over serial

The screen sends data using `get`, `prints`, and `printh`. Notes: (1) split send statements across
lines in the same event are actually sent as one line; (2) variables are sent only via `prints`/`get`,
HEX data only via `printh`; (3) by combining `printh` with `prints` the screen can implement any
communication protocol.

---

*End of translation. For our firmware 159's per-command confidence status, see
[`commands.md`](commands.md).*
