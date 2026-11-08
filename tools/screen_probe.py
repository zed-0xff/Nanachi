#!/usr/bin/env python3
"""Hardware probe for the Sovol / TJC (Nextion compatible) serial screen.

Answers the questions that decide whether KlipperScreen can run on the stock screen:
  scan    which baud rate answers, model / firmware / flash size (`connect` -> `comok ...`)
  touch   raw touch frames (`sendxy=1` -> 0x67/0x68 x,y,state) next to the stock 0x65 component events
  draw    do the stock firmware's drawing commands (fill / line / cir / xstr) work, and what do they answer
  upload  timed `twfile` upload of a JPEG into the screen's ram/ file system (protocol of sent_jpg_to_tjc())
  soft-reset  the screen is silent at the right baud rate (stuck mid-command): send the standard upload-library reset sequence
  recover     the screen is silent after a baud change: soft-reset, then send baud=115200 at every rate
  raw     send any command, print every reply
  peek    read panel memory as a hex dump; -w FILE saves the binary dump (needs the stage1 image's peek blob running)
  poke    write panel memory: 1-255 bytes of hex, or a whole file as @file in 255-byte chunks (needs the stage1 image's poke blob running)
  shot    screenshot of the live framebuffer 0x60EC00 (480x272 RGB565, one 261120-byte peek): PNG by default, --raw saves it as-is
  shell   one console open, then a peek/poke/raw REPL on the same link (the slow comok is paid once, not per command)
  bench   draw command throughput at 115200 and (--fast 921600) at a higher baud rate
  flash   write a .tft with `whmi-wri` (what Sovol's `uart` does), only after the .tft checksums verified

Needs pyserial. Stop the stock UI client first (it owns the port): `sudo systemctl stop <service>` / kill it.
Examples:
  screen_probe.py --port /dev/ttyS4 scan
  screen_probe.py --port /dev/ttyS4 touch --seconds 20
  screen_probe.py --port /dev/ttyS4 upload tile.jpg --repeat 5
  screen_probe.py --port /dev/ttyS4 raw 'page 1'
  screen_probe.py --port /dev/ttyS4 peek 0xE0010000 256
  screen_probe.py --port /dev/ttyS4 peek 0xE0010000 4096 -w dump.bin
  screen_probe.py --port /dev/ttyS4 poke 0x650000 @nanachi_raw.rgb565
  screen_probe.py --port /dev/ttyS4 shot screenshot.png
  screen_probe.py --port /dev/ttyS4 shot shot.rgb565 --raw
  screen_probe.py --port /dev/ttyS4 shell      (peek/poke/raw REPL on one open console)
"""
import argparse
import os
import struct
import sys
import time

try:
    from .iac import IacSerial          # imported as tools.screen_probe
except ImportError:
    from iac import IacSerial           # run as python3 tools/screen_probe.py

BAUDS = [115200, 921600, 9600, 230400, 460800, 57600, 38400, 19200, 4800, 2400]
END = b"\xff\xff\xff"
POKE_MAX = 255          # the stage1 blob's poke N cap; file pokes chunk to this
PEEK_MAX = 32768        # the stage1 blob's peek N cap: a single peek delivers at most ~33000 bytes, so dumps larger than this must be chunked
# The live display source buffer (blit_60ec): the framebuffer the panel scans continuously,
# 480x272 RGB565 = 261120 bytes (pbuf->fb, 1:1 verified with a camera image)
FB_ADDR = 0x60EC00
FB_W, FB_H, FB_BPP = 480, 272, 2
FB_TOTAL = FB_W * FB_H * FB_BPP

# Replies of the Nextion instruction set (bkcmd=3 reports success and failure)
RETURN_CODES = {
    0x00: "invalid instruction", 0x01: "instruction successful", 0x02: "invalid component id",
    0x03: "invalid page id", 0x04: "invalid picture id", 0x05: "invalid font id", 0x06: "file operation failed",
    0x09: "invalid crc", 0x11: "invalid baud rate setting", 0x12: "invalid waveform id or channel",
    0x1a: "invalid variable name or attribute", 0x1b: "invalid variable operation", 0x1c: "assignment failed",
    0x1d: "eeprom operation failed", 0x1e: "invalid parameter quantity", 0x1f: "io operation failed",
    0x20: "undefined escape characters", 0x23: "too long variable name", 0x24: "serial buffer overflow",
    0xfd: "transparent data finished", 0xfe: "transparent data ready (send the data now)",
    0x86: "device entered sleep", 0x87: "device woke up", 0x88: "system started", 0x89: "start sd card upgrade",
}


def modbus_crc(data: bytes) -> int:
    """CRC-16/MODBUS (init 0xffff, poly 0xa001), the check_crc() of the stock client."""
    crc = 0xffff
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xa001 if crc & 1 else crc >> 1
    return crc


def twfile_packets(data: bytes, chunk: int = 4096 - 12 - 2):
    """Frames of the `twfile` transparent file transfer: 12 byte header + data + CRC (low byte first)."""
    head = bytes([0x3A, 0xA1, 0xBB, 0x44, 0x7F, 0xFF, 0xFE, 0x01])
    for pid, pos in enumerate(range(0, len(data), chunk)):
        part = data[pos:pos + chunk]
        yield head + struct.pack("<HH", pid, len(part) + 2) + part + struct.pack("<H", modbus_crc(part))


TWFILE_EXIT = bytes([0x3A, 0xA1, 0xBB, 0x44, 0x7F, 0xFF, 0xFE, 0x00, 0xFF, 0xFF, 0x00, 0x00])


def parse_frame(f: bytes) -> str:
    """Readable description of one reply frame (without the FF FF FF terminator)."""
    if not f:
        return "(empty)"
    c = f[0]
    if f.startswith(b"comok"):
        return "comok " + f.decode("latin-1")
    if c == 0x65 and len(f) >= 4:
        return f"touch event: page {f[1]} component {f[2]} {'press' if f[3] else 'release'}"
    if c == 0x66 and len(f) >= 2:
        return f"current page {f[1]}"
    if c in (0x67, 0x68) and len(f) >= 6:
        x, y = struct.unpack(">HH", f[1:5])
        kind = "touch" if c == 0x67 else "touch (sleep)"
        return f"{kind} x={x} y={y} {'press' if f[5] else 'release'}"
    if c == 0x70:
        return "string: " + f[1:].decode("latin-1", "replace")
    if c == 0x71 and len(f) >= 5:
        return f"number: {struct.unpack('<i', f[1:5])[0]}"
    if c in RETURN_CODES:
        return RETURN_CODES[c]
    return "unknown " + f.hex(" ")


class Screen:
    def __init__(self, port, baud, verbose=False, iac=False, rfc2217_baud=0):
        import serial
        ser = serial.serial_for_url(port, baudrate=baud, timeout=0.05) if "://" in port \
            else serial.Serial(port, baud, timeout=0.05)
        # IacSerial is a transparent pass-through unless --iac: then it escapes 0xFF on the wire
        # (ser2net in telnet mode doubles it) and un-escapes on read, so every ser.read/write below works unchanged.
        self.ser = IacSerial(ser, iac)
        self.verbose = verbose
        self.buf = b""
        if iac:
            # In telnet mode ser2net emits a negotiation burst right after TCP
            # connect. Answer it (accept every option) so ser2net stops waiting
            # and starts forwarding: without a reply it holds our data for its
            # ~3 s negotiation timeout, which was the entire console-open
            # latency; with one the first reply lands in ~10 ms.
            t0 = time.time()
            self.ser.handshake(rfc2217_baud)
            if self.verbose:
                note = f", rfc2217 baud {rfc2217_baud}" if rfc2217_baud else ""
                print(f"  (iac handshake{note}: {time.time() - t0:.2f}s)")
        # The first command after opening a port is often garbled (a USB serial bridge may drop or add bytes while the host
        # side settles; the screen then answers 0x1A "invalid variable" to it): send an empty command and drop the answer.
        time.sleep(0.2)
        self.ser.write(END)
        self.ser.flush()
        time.sleep(0.15)
        self.ser.reset_input_buffer()

    def close(self):
        self.ser.close()

    def send(self, cmd):
        data = cmd.encode("utf-8") if isinstance(cmd, str) else cmd
        if self.verbose:
            print(f"  > {cmd!r}")
        self.ser.write(data + END)
        self.ser.flush()

    def frames(self, seconds):
        """Collects frames (split at FF FF FF) for the given time."""
        end = time.time() + seconds
        out = []
        while time.time() < end:
            self.buf += self.ser.read(256)
            while END in self.buf:
                f, self.buf = self.buf.split(END, 1)
                out.append(f)
        return out

    def ask(self, cmd, seconds=0.5):
        self.ser.reset_input_buffer()
        self.buf = b""
        self.send(cmd)
        return self.frames(seconds)

    def connect(self, cap=6.0, resend=1.5):
        """Patient ``connect`` as ONE continuous read loop.

        Sends ``connect``, then reads without stopping until the panel's ``comok``
        arrives or ``cap`` seconds elapse, resending ``connect`` every ``resend``
        seconds while waiting. The buffer is never reset between resends, so a
        ``comok`` that lands between two sends is picked up on the very next read
        instead of being discarded and re-requested -- the old fixed read-windows
        could miss a ``comok`` that arrived just after a window closed, and that
        lost window was the bulk of a slow peek. The panel opens the console on
        its own schedule (~3.5-5 s over the ACM/ser2net path, independent of our
        resend cadence), so that latency is the floor here, not our polling.
        Returns the ``comok`` frame, or every frame that arrived if none."""
        t0 = time.time()
        self.ser.reset_input_buffer()
        self.buf = b""
        out = []
        self.send("connect")
        next_send = t0 + resend
        while time.time() - t0 < cap:
            chunk = self.ser.read(256)
            if chunk:
                self.buf += chunk
                while END in self.buf:
                    f, self.buf = self.buf.split(END, 1)
                    out.append(f)
                    if f.startswith(b"comok"):
                        if self.verbose:
                            print(f"  (comok in {time.time() - t0:.2f}s)")
                        self.buf = b""
                        return [f]
            if time.time() >= next_send:
                if self.verbose:
                    print(f"  (connect resend at {time.time() - t0:.2f}s)")
                self.send("connect")
                next_send = time.time() + resend
        if self.verbose:
            print(f"  (connect: no comok after {time.time() - t0:.2f}s)")
        return out


def cmd_scan(a):
    for baud in ([a.baud] if a.baud else BAUDS):
        s = Screen(a.port, baud, a.verbose, a.iac)
        got = s.connect()
        s.close()
        print(f"{baud:>7}: " + ("; ".join(parse_frame(f) for f in got) if got else "no answer"))
        if any(f.startswith(b"comok") for f in got):
            fields = next(f for f in got if f.startswith(b"comok")).decode("latin-1").split(",")
            names = ["touch/status", "reserved", "model", "firmware", "mcu code", "serial", "flash size"]
            for n, v in zip(names, [fields[0][6:]] + fields[1:]):
                print(f"           {n}: {v}")
            return 0
    print("no baud rate answered; wrong port, UI client still running, or the screen is in a different state")
    return 1


def cmd_touch(a):
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    for c in ("bkcmd=3", "sendxy=1"):
        print(c, "->", [parse_frame(f) for f in s.ask(c)])
    print(f"touch the screen for {a.seconds} s (Ctrl-C to stop)")
    t0, n = time.time(), 0
    try:
        while time.time() - t0 < a.seconds:
            for f in s.frames(0.2):
                n += 1
                print(f"{time.time() - t0:7.2f}s  {parse_frame(f)}")
    except KeyboardInterrupt:
        pass
    s.ask("sendxy=0")
    print(f"{n} frames")


def cmd_draw(a):
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    s.ask("bkcmd=3")
    tests = [
        ("fill 0,0,480,272,BLACK", "fill whole screen"),
        ("fill 10,10,100,60,RED", "fill rectangle"),
        ("line 0,0,479,271,GREEN", "line"),
        ("cir 240,136,50,BLUE", "circle"),
        ("draw 120,80,360,200,WHITE", "rectangle outline"),
        ('xstr 130,90,220,40,0,WHITE,BLACK,0,1,1,"KlipperScreen"', "text (font 0)"),
        ("pic 0,0,0", "picture 0"),
    ]
    for cmd, what in tests:
        got = s.ask(cmd, 0.4)
        print(f"{what:20} {cmd:60} -> {[parse_frame(f) for f in got] or 'no reply'}")
        time.sleep(0.4)
    print("look at the screen: which of these showed up?")


def cmd_raw(a):
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    for cmd in a.commands:
        print(cmd, "->", [parse_frame(f) for f in s.ask(cmd, a.wait)] or "no reply")


def _peek_parse(raw: bytes, final: bool = False):
    """Splits a peek reply into (dump data, error message or None, beacon count, junk). The stage1
    blob answers a `peek` line with a 0x5A beacon, then dump frames 72 <n> <n data bytes> FF FF FF
    (n = 1..254 as-is; a full 255-byte chunk sends n = 0xFE on the wire - 0xFF is reserved for the
    4-byte error frame 72 FF FF FF; the parser decodes 0xFE back to 255), then the stock's own 00
    invalid-instruction ack. Every frame is parsed positionally by n - no pattern scan, no lookahead
    - so data holding 0x72/0x00/0xFF (long FF runs included) is unambiguous.

    Fault modes: a complete error frame sets err ("bad syntax?"); a frame whose terminator is
    missing where the length says it must be means bytes were lost or shifted in transit.
    ``final`` selects the semantics of a stream that simply ends inside a frame: False =
    "still arriving" (no err, the read loop keeps going); True = report it (truncated: the
    partial data is placed in the dump at its true offset and err says how many of the n data
    bytes arrived; shifted: the byte where the terminator should be is named in err and the
    unparseable remainder goes to ``junk`` in stream order for inspection)."""
    beacons, chunks, err, junk, i, n = 0, [], None, bytearray(), 0, len(raw)
    while i < n:
        b = raw[i]
        if b == 0x5a:
            beacons += 1
            i += 1
        elif b == 0x72:
            if i + 1 >= n:
                if final:
                    err = f"truncated frame at {i}: 72 without a length byte"
                    junk += raw[i:]
                break
            ln = raw[i + 1]
            if ln == 0xFF:
                # the error sentinel: a data chunk never sends 0xFF, so a 72 FF can only be this frame.
                # A frame is COMPLETE only when its 3-byte terminator has arrived (i+4 <= n). While the
                # terminator is still in flight (i+4 > n) this is NOT a real error yet - keep reading.
                if i + 4 > n:
                    if final:
                        err = f"corrupt error frame at {i}: {raw[i:i + 4].hex(' ')}"
                        junk += raw[i:]
                    break
                if raw[i + 1:i + 4] == END:
                    err = "error frame (bad syntax?)"
                else:
                    err = f"corrupt error frame at {i}: {raw[i:i + 4].hex(' ')}"
                junk += raw[i:]
                break
            # 0xFE on the wire means a full 255-byte chunk (the blob remaps 255 -> 0xFE so
            # 0xFF stays the exclusive error sentinel); every other value is the byte count
            nlen = 255 if ln == 0xFE else ln
            j = i + 2 + nlen
            if j + 3 <= n and raw[j:j + 3] == END:
                chunks.append(raw[i + 2:j])
                i = j + 3
            elif j >= n:
                # the stream ends before the terminator: a byte was lost in transit (final),
                # or the panel is still sending (keep reading)
                avail = raw[i + 2:j]
                if avail:
                    chunks.append(avail)      # sequential data: place it; the caller sees len(dump) < expected
                if final:
                    err = f"truncated frame at {i}: got {len(avail)} of {nlen} data bytes (lost in transit?)"
                break
            else:
                # the terminator is not where the length says. Two cases: (a) the 255-byte
                # frame's terminator is still in flight (the read boundary split it) - then
                # more bytes are coming and this is NOT an error yet; (b) a byte was truly
                # lost/shifted. We can only tell after the stream goes quiet, so: if we are
                # still reading (final=False) just stop this parse and keep the loop going;
                # only declare it corrupt once final=True confirms no more data is arriving.
                if final:
                    err = (f"corrupt frame at {i}: expected terminator after {nlen} data bytes, "
                           f"got 0x{raw[j]:02x} (shifted stream)")
                    junk += raw[i:]
                break
        elif raw[i:i + 3] == END:
            i += 3
        else:
            junk += bytes([b])          # the stock's 00 ack and anything else
            i += 1
    return b"".join(chunks), err, beacons, bytes(junk)


def _hexdump(base: int, data: bytes):
    for off in range(0, len(data), 16):
        row = data[off:off + 16]
        hexpart = " ".join(f"{b:02x}" for b in row).ljust(47)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print(f"{base + off:08x}  {hexpart}  |{asc}|")


def _quiet_drain(s, seconds):
    """Discard inbound bytes until a short quiet period or the cap, to clear a
    throwaway line's reply before the next command starts."""
    last = time.time()
    end = time.time() + seconds
    while time.time() < end:
        if s.ser.read(256):
            last = time.time()
        elif time.time() - last > 0.2:
            break


def _open_console(s):
    """Open the console on a fresh link. The panel parses probe lines only while the
    console is open (the printer app otherwise owns the port): True if a comok came back.

    After comok the stock parser only reaches the 0x2A1E (get_String8) hook that the
    peek/poke blob rides on from the SECOND line onward, so the very first line is
    consumed as a 0x1A without hitting the blob. We send one throwaway priming line
    and drain it; every real command after that reliably reaches the blob."""
    got = s.connect()
    if not any(f.startswith(b"comok") for f in got):
        return False
    s.ser.reset_input_buffer()
    s.buf = b""
    s.send("get dp")          # the priming line (read-only; its 0x1A/number reply is discarded)
    _quiet_drain(s, 0.5)
    s.ser.reset_input_buffer()
    s.buf = b""
    return True


def _peek_read(s, expected, wait):
    """Read one peek reply, stopping deterministically as soon as ``expected`` dump
    bytes are collected (the blob's dump is exactly ``expected`` bytes), a complete
    error frame arrives, or the stream is detected as shifted/corrupt mid-frame; a
    0.6 s quiet period and the ``wait`` backstop cover the cases where the panel
    sends less than expected or the link never goes quiet. A stream that merely
    ends inside a frame keeps reading (final=False) and is reported on the final
    parse (final=True): truncated (bytes lost) or corrupt (terminator shifted).
    Returns ``(dump, err, beacons, junk, raw)``."""
    raw, last = b"", time.time()
    s.ser.timeout = 0.01          # tight poll: a short reply is noticed within ~10 ms, not the 50 ms default
    end = time.time() + wait
    while time.time() < end:
        c = s.ser.read(256)
        if c:
            raw += c
            last = time.time()
            dump, err, _, _ = _peek_parse(raw)
            if err or len(dump) >= expected:
                break
        elif raw and time.time() - last > 0.6:
            break
    dump, err, beacons, junk = _peek_parse(raw, final=True)
    return dump, err, beacons, junk, raw


def _peek_run(s, addr, length, wait, verbose=False, hexdump=True):
    """Run one peek against an already-open console and print the result (the hex
    dump is skipped when ``hexdump`` is off - e.g. a binary save to a file wants only
    the summary)."""
    cmd = f"peek 0x{addr:x},{length}"
    s.ser.reset_input_buffer()          # clear any trailing bytes from a previous command's deterministic stop
    s.send(cmd)
    dump, err, beacons, junk, raw = _peek_read(s, length, wait)
    tail = bytes(b for b in junk if b != 0x00)      # the 00 invalid-instruction ack is expected after a peek
    if beacons:
        print(f"  (0x5A beacon x{beacons}: the peek blob ran)")
    if err:
        print(f"peek {cmd}: {err}")
    if dump:
        if hexdump:
            _hexdump(addr, dump)
        print(f"  {len(dump)} bytes from 0x{addr:08x}"
              + (f" (+{len(tail)} B partial tail)" if tail else "")
              + (f" (shorter than the {length} requested - truncated?)" if len(dump) < length else ""))
    if not dump and not err:
        # A reply with no Z beacon means the stock parser answered (0x1A invalid-variable) -
        # the blob is not installed on this boot. A Z beacon with no data means the blob ran
        # but the window/syntax was bad. 0 bytes means the line was dropped (console not open).
        if raw and 0x5a not in raw:
            print(f"peek {cmd}: no Z beacon - the peek blob is not installed on this boot (stock answered)")
        elif raw:
            print(f"peek {cmd}: Z beacon but no dump (bad window or syntax?)")
        else:
            print(f"peek {cmd}: nothing received (the console dropped the line)")
        print(f"  (raw: {len(raw)} bytes: {raw[:64].hex(' ')})" if raw else "  (raw: nothing received)")
        if not raw:
            # the line was never answered: probe with a known 3-char line that the 0x2A1E path
            # handles in stock and in the blob; a Z beacon in the reply means the blob is installed
            s.send("get dp")
            p, last = b"", time.time()
            pend = time.time() + 1.5
            while time.time() < pend:
                c = s.ser.read(256)
                if c:
                    p += c
                    last = time.time()
                elif p and time.time() - last > 0.3:
                    break
            if p:
                print(f"  (probe 'get dp': {len(p)} bytes, {'blob (Z beacon)' if 0x5a in p else 'no Z (stock)'}, head {p[:24].hex(' ')})")
            else:
                print("  (probe 'get dp': silence — the console dropped the line)")
    if tail:
        if dump and hexdump:
            # the unparseable stream after the fault point (a shifted/corrupt frame),
            # in order; unplaced (the alignment is broken from the fault byte on), so
            # the offset shown is a lower bound, not a map
            print(f"  --- partial tail: {len(tail)} B (stream order; unplaced) ---")
            _hexdump(addr + len(dump), tail)
        else:
            print(f"  (unparsed tail: {tail.hex(' ')})")
    return dump, err, tail


def cmd_peek(a):
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    if not _open_console(s):
        print("peek: no comok (the console did not open; another client holds the panel, or it is mid-boot)")
        s.close()
        return
    dump, err, tail = _peek_run(s, a.addr, a.length, a.wait, a.verbose, hexdump=a.write is None)
    if a.write:
        if dump or tail:
            try:
                with open(a.write, "wb") as f:
                    f.write(dump + tail)
                print(f"  wrote {len(dump) + len(tail)} bytes to {a.write}"
                      + (f" ({len(tail)} B unplaced partial tail appended)" if tail else ""))
            except OSError as e:
                print(f"  cannot write {a.write}: {e}")
        else:
            print(f"peek: no data to write to {a.write} ({err or 'no dump'})")
    s.close()


def _rgb565(fb: bytes, width: int) -> "Image.Image":
    """RGB565 little-endian framebuffer -> a Pillow RGB image.

    One pixel per 2 bytes: R = v>>11 (5 b), G = (v>>5)&0x3F (6 b), B = v&0x1F (5 b),
    each padded to its top 8-bit value (identical to the pre-NumPy hand loop).
    """
    import numpy as np
    from PIL import Image
    v = np.frombuffer(fb[:len(fb) // 2 * 2], dtype=np.uint16).astype(np.uint32)
    rgb = np.empty((len(v), 3), dtype=np.uint8)
    rgb[:, 0] = (v >> 11) << 3
    rgb[:, 1] = ((v >> 5) & 0x3F) << 2
    rgb[:, 2] = (v & 0x1F) << 3
    return Image.fromarray(rgb.reshape(len(v) // width, width, 3))


def cmd_shot(a):
    out = a.file if a.raw else (a.file if a.file.endswith(".png") else a.file + ".png")
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    if not _open_console(s):
        print("shot: no comok (the console did not open; another client holds the panel, or it is mid-boot)")
        s.close()
        return
    s.ser.timeout = 0.01
    t0 = time.time()
    # The peek blob caps a single dump at ~33000 bytes, so the 261120-byte framebuffer
    # must be read in PEEK_MAX-byte chunks. Each chunk is its own peek line (a fresh
    # priming line is NOT needed - the console is already open and the parser is primed
    # by _open_console's throwaway line; the blob answers every subsequent peek line).
    fb = b""
    for off in range(0, FB_TOTAL, PEEK_MAX):
        n = min(PEEK_MAX, FB_TOTAL - off)
        s.ser.reset_input_buffer()
        s.buf = b""
        s.send(f"peek 0x{FB_ADDR + off:x},{n}")
        part, err, _, _, _ = _peek_read(s, n, a.wait)
        fb += part
        if err or len(part) < n:
            break      # a short/failed chunk: stop; the remainder is missing
    s.close()
    dt = time.time() - t0
    if not fb:
        print("shot: no framebuffer data (" + (f"{err}" if err else "the peek blob is not installed on this boot?"))
        return
    if err:
        print(f"shot: {err} (truncated at {len(fb)} bytes)")
    if len(fb) < FB_TOTAL:
        print(f"shot: only {len(fb)}/{FB_TOTAL} bytes of the framebuffer (truncated)")
        out = out + ".partial"
    try:
        with open(out, "wb") as f:
            if a.raw:
                f.write(fb)
            else:
                # a truncated dump ends mid-row: cut at the last complete row before encoding
                n = len(fb) // FB_BPP * FB_BPP
                _rgb565(fb[:n], FB_W).save(f, "PNG")
    except OSError as e:
        print(f"  cannot write {out}: {e}")
        return
    kind = "raw RGB565" if a.raw else "PNG"
    print(f"  wrote {len(fb)} bytes to {out} ({kind}) in {dt:.2f} s")


def _poke_reply(s, wait):
    """Read one poke reply, stopping as soon as the answer is complete: the Z beacon
    (success - the write is not echoed) or the 72 FF FF FF error frame (the 0xFF length
    is the error sentinel; poke frames never use it for data), both arrive whole; the
    0.6 s quiet period and the ``wait`` backstop cover the no-answer case (the line
    never reached the blob). Returns ``(dump, err, beacons, junk)``."""
    raw, last = b"", time.time()
    s.ser.timeout = 0.01               # tight poll: the Z-beacon / error reply is noticed within ~10 ms
    end = time.time() + wait
    while time.time() < end:
        c = s.ser.read(256)
        if c:
            raw += c
            last = time.time()
            _, err, beacons, _ = _peek_parse(raw)
            if err or beacons:
                break
        elif raw and time.time() - last > 0.6:
            break
    return _peek_parse(raw, final=True)


def _poke_run(s, addr, value, wait, verify, verbose=False):
    """Run one poke against an already-open console and print the result. ``value`` is
    the bytes to write. The blob answers a success with NO frame (the Z beacon only) -
    the write happened; an error (bad syntax / N > 255 / outside the writable windows)
    is one 72 FF FF FF frame. _peek_parse splits both: a success is beacons with zero
    chunks."""
    cmd = f"poke 0x{addr:x},{len(value)},{value.hex().upper()}"
    s.ser.reset_input_buffer()          # clear any trailing bytes from a previous command
    s.send(cmd)
    dump, err, beacons, junk = _poke_reply(s, wait)
    if beacons:
        print(f"  (0x5A beacon x{beacons}: the poke blob ran)")
    if err:
        print(f"poke {cmd}: {err}")
    elif beacons and not dump:
        print(f"poke {cmd}: ok ({len(value)} bytes to 0x{addr:08x}; no reply frame - the write is not echoed)")
        if verify:
            s.ser.reset_input_buffer()       # the poke read may have stopped on the quiet period with a partial ack left
            vd, _, _, _, _ = _peek_read(s, len(value), wait)
            if vd == value:
                print(f"  verify: peek matches the written data")
            else:
                print(f"  verify: peek differs (wrote {value.hex(' ')}, read {vd.hex(' ') if vd else 'NO DATA'}"
                      f"{' - the window is read-only (store dropped)' if not vd else ''})")
    elif not dump:
        print(f"poke {cmd}: no beacon (is the stage1 image with the poke blob running?)")
    else:
        print(f"poke {cmd}: unexpected frame: {dump.hex(' ')}")
    junk = bytes(b for b in junk if b != 0x00)      # the 00 invalid-instruction ack is expected after a poke
    if junk:
        print(f"  (unparsed tail: {junk.hex(' ')})")


def _parse_poke_data(data):
    """Validate a hex string (optional 0x prefix, 1-255 bytes) to bytes, or return None."""
    if data[:2].lower() == "0x":
        data = data[2:]
    if not data or len(data) % 2 or len(data) > 2 * 255:
        return None
    if not all(c in "0123456789abcdefABCDEF" for c in data):
        return None
    return bytes.fromhex(data)


def _poke_send(s, addr, value, wait):
    """Send one poke line and wait for its answer. Returns 'ok' (Z beacon - the write
    happened, it is not echoed), 'err' (72 FF FF FF error frame), or None (no beacon -
    the line never reached the blob)."""
    s.ser.reset_input_buffer()
    s.send(f"poke 0x{addr:x},{len(value)},{value.hex().upper()}")
    _, err, beacons, _ = _poke_reply(s, wait)
    if err:
        return "err"
    if beacons:
        return "ok"
    return None


def _poke_chunk(s, addr, value, wait, retries=3, verbose=False):
    """Confirm one file-poke chunk. A drop (no beacon) or a desync error frame is
    retried; if the chunk never confirms, the console is re-opened once (re-primes the
    parser) and it is tried again. A confirmed write is idempotent, so re-sending a
    chunk whose first attempt landed off-wire only re-writes the same bytes."""
    for phase in (retries, 1):
        for attempt in range(1, phase + 1):
            outcome = _poke_send(s, addr, value, wait)
            if outcome == "ok":
                return True
            if verbose:
                print(f"\n  (0x{addr:08x}: {'error frame' if outcome == 'err' else 'no beacon'}, try {attempt}/{phase})")
        if phase != 1:
            print(f"\n  (chunk at 0x{addr:08x} unconfirmed after {retries} tries; re-opening the console to re-prime the parser)")
            if not _open_console(s):
                return False
    return False


def _poke_file(s, addr, data, wait, verbose=False):
    """Write a whole file in POKE_MAX-byte chunks (the blob's poke N cap), one
    confirmed poke per chunk; a progress bar on stdout, and a stop (not a rollback)
    on the first chunk that never confirms."""
    nchunks = (len(data) + POKE_MAX - 1) // POKE_MAX
    print(f"poke file: {len(data)} bytes to 0x{addr:08x} in {nchunks} x {POKE_MAX}-byte chunks")
    t0 = time.time()
    for i in range(nchunks):
        off = i * POKE_MAX
        if not _poke_chunk(s, addr + off, data[off:off + POKE_MAX], wait, verbose=verbose):
            print(f"  failed at 0x{addr + off:08x} (chunk {i + 1}/{nchunks}); {off} of {len(data)} bytes written")
            print("  (verify with a peek on a fresh console - a same-console peek right after pokes returns no data)")
            return
        print(f"\r  {100 * (i + 1) // nchunks:3d}%  {min(off + POKE_MAX, len(data))}/{len(data)} bytes", end="", flush=True)
    dt = time.time() - t0
    print(f"\npoke file: {len(data)} bytes written in {dt:.2f} s ({len(data) / dt / 1024:.1f} KiB/s)")


def cmd_poke(a):
    data = None
    if a.data.startswith("@"):
        path = a.data[1:]
        try:
            data = open(path, "rb").read()
        except OSError as e:
            print(f"poke: cannot read {path}: {e}")
            return
        if not data:
            print(f"poke: {path} is empty; nothing to write")
            return
    else:
        value = _parse_poke_data(a.data)
        if value is None:
            print("poke: data must be 1-255 bytes of hex (2 digits per byte, no spaces; an optional 0x prefix is fine); refusing")
            return
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    if not _open_console(s):
        print("poke: no comok (the console did not open; another client holds the panel, or it is mid-boot)")
        s.close()
        return
    if data is not None:
        if a.verify:
            print("  note: --verify is hex-only; confirm a file write with a peek on a fresh console")
        _poke_file(s, a.addr, data, a.wait, a.verbose)
    else:
        _poke_run(s, a.addr, value, a.wait, a.verify, a.verbose)
    s.close()


def cmd_shell(a):
    """One console open, then a peek/poke/raw REPL on the same link.

    The ~3.5-5 s ``comok`` (the panel opening the console on its own schedule)
    is paid once, at open; every command after that costs only the wire time of
    its reply (tens to a hundred ms at this link), not another console open.
    Commands: ``peek ADDR [LEN]`` (LEN default 256), ``poke ADDR HEX``,
    ``raw CMD...``, ``quit``."""
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    if not _open_console(s):
        print("shell: no comok (the console did not open; another client holds the panel, or it is mid-boot)")
        return 1
    print("console open. peek ADDR [LEN] | poke ADDR HEX | raw CMD... | quit")
    while True:
        try:
            line = input("nanachi> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        word, _, arg = line.partition(" ")
        word, arg = word.lower(), arg.strip()
        if word in ("quit", "exit"):
            break
        t0 = time.time()
        try:
            if word == "peek":
                toks = arg.split()
                addr = int(toks[0], 0) if toks else 0
                length = int(toks[1], 0) if len(toks) > 1 else 256
                _peek_run(s, addr, length, a.wait, a.verbose)
            elif word == "poke":
                toks = arg.split()
                if len(toks) < 2:
                    print("usage: poke ADDR HEX")
                else:
                    addr = int(toks[0], 0)
                    value = _parse_poke_data(toks[1])
                    if value is None:
                        print("poke: data must be 1-255 bytes of hex (2 digits per byte)")
                    else:
                        _poke_run(s, addr, value, a.wait, False, a.verbose)
            elif word == "raw":
                s.ser.reset_input_buffer()
                s.buf = b""
                s.send(arg)
                rawb, last = b"", time.time()
                rend = time.time() + a.wait
                while time.time() < rend:
                    c = s.ser.read(256)
                    if c:
                        rawb += c
                        last = time.time()
                    elif rawb and time.time() - last > 0.3:
                        break
                frames = []
                while END in rawb:
                    f, rawb = rawb.split(END, 1)
                    frames.append(f)
                print([parse_frame(f) for f in frames] or "no reply")
            else:
                print(f"unknown '{word}' (peek ADDR [LEN] | poke ADDR HEX | raw CMD | quit)")
        except ValueError:
            print("bad number (addr / len)")
        if a.verbose:
            print(f"  ({time.time() - t0:.3f}s)")
    s.close()
    print("closed")
    return 0


def read_acks(ser, timeout, seen=None):
    """Waits for the answer of the file transfer: 0x05 ok, 0xfd (FD FF FF FF, transfer finished) ok, 0x04 failed; None on timeout. Every other
    byte that arrives is appended to seen (a bytearray) so that a failure can show what the screen said."""
    end = time.time() + timeout
    while time.time() < end:
        b = ser.read(1)
        if b and b[0] in (0x05, 0x04):
            return b[0]
        if b and b[0] == 0xfd:          # "transparent data finished"; the stock client accepts it like 0x05
            rest = ser.read(3)
            return 0xfd if rest == b"\xff\xff\xff" else None
        if b and seen is not None:
            seen += b
    return None


def cmd_upload(a):
    if not _baud_guard(a):
        return 2
    data = open(a.file, "rb").read()
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    for cmd in ([f"bkcmd={a.bkcmd}"] if a.bkcmd is not None else []) + (["tsw 255,0"] if a.no_touch else []):
        print(cmd, "->", [parse_frame(f) for f in s.ask(cmd)])
    if a.delete:
        print("delfile ->", [parse_frame(f) for f in s.ask(f'delfile "{a.target}"', 0.5)])
    slow_baud = s.ser.baudrate
    if a.fast:          # `baud` is temporary: the screen is back at 115200 after a power cycle
        if not _switch_baud(s, a.fast, slow_baud):
            return 1
        print(f"screen is at {a.fast} baud")
    rates = []
    for i in range(a.repeat):
        s.ser.reset_input_buffer()
        t0 = time.time()
        s.send(f'twfile "{a.target}",{len(data)}')
        reply = bytearray()
        end = time.time() + (1.0 if a.wait_fe else 0.1)
        while time.time() < end:
            reply += s.ser.read(64)
            if a.wait_fe and 0xfe in reply:
                break
        print(f"  reply to twfile: {reply.hex(' ') or 'nothing'}" + (" (0xFE = ready for data)" if 0xfe in reply else ""))
        ok = True
        if a.raw:       # no framing: the file bytes as they are, the screen answers FD FF FF FF when it has all of them
            for pos in range(0, len(data), 1024):
                s.ser.write(data[pos:pos + 1024])
                s.ser.flush()
            seen = bytearray()
            ack = read_acks(s.ser, 3.0, seen)
            if ack != 0xfd:
                print(f"  no FD after the raw data (answer {ack}); other bytes seen: {seen.hex(' ') or 'none'}")
                ok = False
            packets = []
        else:
            packets = twfile_packets(data)
        for pkt in packets:
            s.ser.write(pkt)
            s.ser.flush()
            seen = bytearray()
            ack = read_acks(s.ser, 3.0, seen)
            if ack not in (0x05, 0xfd):
                print(f"  packet failed ({'timeout' if ack is None else 'screen answered 0x04'}); other bytes seen: "
                      f"{seen.hex(' ') or 'none'}")
                for _ in range(3):
                    s.ser.write(TWFILE_EXIT)
                ok = False
                break
        dt = time.time() - t0
        if ok:
            rates.append(len(data) / dt)
            print(f"upload {i + 1}: {len(data)} bytes in {dt:.2f} s = {len(data) / dt / 1024:.1f} KiB/s")
        s.frames(0.3)
    if a.no_touch:
        s.ask("tsw 255,1")
    if rates and a.page is not None:
        print(f"page {a.page} ->", [parse_frame(f) for f in s.ask(f"page {a.page}")])
    if a.fast:
        _restore_baud(s, slow_baud)
    if rates:
        print(f"average {sum(rates) / len(rates) / 1024:.1f} KiB/s")


def _settle(s):
    """After the host side changed its baud rate the first bytes through a USB serial bridge are unreliable: wait, send an
    empty command and throw away whatever comes back."""
    time.sleep(0.3)
    s.ser.write(END)
    s.ser.flush()
    time.sleep(0.15)
    s.ser.reset_input_buffer()
    s.buf = b""


def _connect(s, tries=3):
    for _ in range(tries):
        if any(f.startswith(b"comok") for f in s.ask("connect", 0.6)):
            return True
    return False


def _soft_reset(s):
    """Puts the screen's command parser back to idle without a baud change or power cycle: the sequence every major
    Nextion/TJC upload library sends before `connect`/`whmi-wri` (Enhanced-Nextion-Library's NexUpload::Reconnect, the
    NSPanel Tasmota driver, powadcr - all independently, see ext/*). The magic string resets the serial port object of
    the firmware to its idle mode (`sub_2CDA0`/case in the decompiled firmware); harmless, it is what every one of
    those libraries sends routinely. Fixes a screen stuck mid-command at the *right* baud rate, which a baud sweep
    (`recover`) does not - use this first, `recover` if this doesn't answer."""
    s.ser.reset_input_buffer()
    s.ser.write(b"DRAKJHSUYDGBNCJHGJKSHBDN" + END)
    s.ser.flush()
    time.sleep(0.5)
    s.ser.reset_input_buffer()
    s.buf = b""
    s.ser.write(b"connect" + END)
    s.ser.flush()
    time.sleep(0.05)
    s.ser.write(END + b"connect" + END)   # a leading FF FF flushes a partially-received frame, as the libraries do
    s.ser.flush()
    time.sleep(0.2)
    return _connect(s, tries=1)


def _switch_baud(s, new, old):
    """Tells the screen to change its baud rate (the `baud` command is not saved: a power cycle brings back 115200) and
    follows with the host. If the screen doesn't answer at the new rate, the screen is told to go back to the old rate
    while the host still speaks the new one. Returns True if the screen answers at the new rate."""
    s.ser.write(END + f"baud={new}".encode() + END)
    s.ser.flush()
    time.sleep(0.2)
    s.ser.baudrate = new
    _settle(s)
    if _connect(s):
        return True
    print(f"no answer at {new} baud; telling the screen to go back to {old}")
    for _ in range(3):
        s.ser.write(END + f"baud={old}".encode() + END)
        s.ser.flush()
        time.sleep(0.2)
    s.ser.baudrate = old
    _settle(s)
    if _connect(s):
        print(f"back at {old} baud")
    else:
        print(f"the screen does not answer at {old} either: run `recover` or power cycle the screen")
    return False


def _restore_baud(s, old):
    for _ in range(2):
        s.ser.write(END + f"baud={old}".encode() + END)
        s.ser.flush()
        time.sleep(0.2)
    s.ser.baudrate = old
    _settle(s)
    ok = _connect(s)
    print(f"back at {old} baud: {'ok' if ok else 'NO ANSWER, run `recover` or power cycle the screen'}")


def cmd_soft_reset(a):
    """Standalone `_soft_reset`: fixes a screen stuck mid-command without touching the baud rate."""
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    ok = _soft_reset(s)
    s.close()
    print("screen answers" if ok else "no answer; try `recover` (wrong baud rate) or power cycle the screen")
    return 0 if ok else 1


def cmd_recover(a):
    """The screen may be stuck mid-command (fixed by `_soft_reset`, tried first here) or sit at another baud rate than
    the host after a failed `baud` change (send `baud=115200` at every rate and look for the screen at 115200)."""
    target = a.baud or 115200
    s = Screen(a.port, target, a.verbose, a.iac)
    if _soft_reset(s):
        s.close()
        print(f"screen answers at {target} baud after a soft reset")
        return 0
    s.close()
    for rate in BAUDS:
        s = Screen(a.port, rate, a.verbose, a.iac)
        for _ in range(2):
            s.ser.write(END + f"baud={target}".encode() + END)
            s.ser.flush()
            time.sleep(0.1)
        s.ser.baudrate = target
        got = s.ask("connect", 0.5)
        s.close()
        print(f"sent baud={target} at {rate}: " + ("screen answers" if any(f.startswith(b"comok") for f in got) else "no answer"))
        if any(f.startswith(b"comok") for f in got):
            return 0
    print("no answer at any rate; power cycle the screen")
    return 1


def _timed_fills(s, count):
    """Sends count `fill` commands (small rectangles) and waits for the answer of a final `sendme`; returns seconds."""
    import random
    s.ser.reset_input_buffer()
    t0 = time.time()
    for i in range(count):
        s.ser.write(f"fill {random.randrange(0, 440)},{random.randrange(0, 240)},{random.randrange(8, 40)},"
                    f"{random.randrange(8, 30)},{random.randrange(0, 65536)}".encode() + END)
    s.ser.write(b"sendme" + END)
    s.ser.flush()
    buf = b""
    while time.time() - t0 < 60:
        buf += s.ser.read(256)
        if b"\x66" in buf and buf.endswith(END):
            break
    return time.time() - t0


def _baud_guard(a):
    """--fast changes the baud rate of the screen at run time; if that goes wrong the screen is silent until it is power
    cycled, so it has to be asked for twice."""
    if a.fast and not a.yes_baud:
        print("--fast changes the baud rate of the screen (not saved; a power cycle brings back 115200). If the screen does\n"
              "not answer at the new rate it can stay silent until it is power cycled. Add --yes-baud if you accept that.")
        return False
    return True


def cmd_bench(a):
    """Draw command throughput at the current baud rate and, with --fast, at a higher one (the `baud` command is temporary:
    the screen is back at 115200 after a power cycle; the probe tries to switch back itself)."""
    if not _baud_guard(a):
        return 2
    s = Screen(a.port, a.baud or 115200, a.verbose, a.iac, rfc2217_baud=a.baud or 0)
    s.ask("bkcmd=0")
    dt = _timed_fills(s, a.count)
    print(f"{s.ser.baudrate} baud: {a.count} fill commands in {dt:.2f} s = {a.count / dt:.0f} commands/s")
    if a.fast:
        old = s.ser.baudrate
        if not _switch_baud(s, a.fast, old):
            return 1
        print(f"{a.fast} baud: connect ok")
        dt = _timed_fills(s, a.count)
        print(f"{a.fast} baud: {a.count} fill commands in {dt:.2f} s = {a.count / dt:.0f} commands/s")
        _restore_baud(s, old)


# try to find TFTTool upto two levels up from this script, and import it to verify the checksums of the file to flash
def _find_tfttool():
    here = os.path.dirname(os.path.abspath(__file__))
    for i in range(3):
        candidate = os.path.abspath(os.path.join(here, *[".."] * i, "TFTTool"))
        if os.path.isdir(candidate):
            sys.path.insert(0, candidate)
            try:
                import TFTTool
                return TFTTool
            except ImportError:
                sys.path.pop(0)
    return None

def cmd_flash(a):
    TFTTool = _find_tfttool()
    if TFTTool is None:
        print("TFTTool not found in the parent directories; cannot verify checksums of the file to flash")
        return 1
    data = open(a.file, "rb").read()
    tft = TFTTool.TFTFile(data)
    bad = {k: v for k, v in tft.verifyChecksums().items() if not v[2]}
    if bad:
        print("refusing to flash, checksum mismatch:", bad)
        return 1
    print(f"{a.file}: model {tft.model}, checksums ok, {len(data)} bytes")
    if not a.yes_flash:
        print("dry run; add --yes-flash to really write it")
        return 0
    chunk = 4096
    s = Screen(a.port, a.start_baud, a.verbose, a.iac)
    # Open the console and put the parser back to idle before anything else: a baud
    # change (or whmi-wri) that lands on a parser mid-command can leave the console
    # stuck until a power cycle. The patient connect() waits out the panel's own
    # console-open schedule (~3.5-5 s over the ACM/ser2net path) and resends, unlike
    # the old 0.6 s-window _connect.
    # A cold boot can take longer than one 6 s connect cap; retry a few times
    # (connect is always-allowed and idempotent).
    comok = False
    for _ in range(5):
        if any(f.startswith(b"comok") for f in s.connect()):
            comok = True
            break
    if not comok:
        print(f"no comok at {a.start_baud}; the console is not open - power cycle and retry")
        return 1
    _soft_reset(s)
    if a.start_baud != a.flash_baud:
        # Change the rate BEFORE the upload command (docs/commands.md): bytes sent right
        # after a host-side rate change are unreliable, a truncated first chunk is
        # silently dropped. After the switch the console may re-init and reopens on
        # its own schedule, so wait for the comok patiently instead of assuming; on
        # failure the fix is a power cycle (no automatic revert - it re-inits again
        # and can wedge the parser).
        s.send(f"baud={a.flash_baud}")
        time.sleep(0.2)
        s.ser.baudrate = a.flash_baud
        _settle(s)
        if not any(f.startswith(b"comok") for f in s.connect()):
            print(f"no comok at {a.flash_baud} after the rate change: power cycle the screen and retry")
            return 1
    s.ser.write(END)
    s.ser.write(f"whmi-wri {len(data)},{a.flash_baud},0".encode() + END)
    s.ser.flush()
    if read_acks(s.ser, 3.0) != 0x05:
        print("screen did not accept the upload command")
        return 1
    for pos in range(0, len(data), chunk):
        for p in range(pos, min(pos + chunk, len(data)), 2048):
            s.ser.write(data[p:min(p + 2048, pos + chunk, len(data))])
        s.ser.flush()
        if read_acks(s.ser, 5.0) != 0x05:
            print(f"no ack after {pos + chunk} bytes")
            return 1
        pct = min(pos + chunk, len(data)) * 100 // len(data)
        print(f"\r[{'#' * (30 * pct // 100):<30}] {pct:3d}%", end="", flush=True)
    print("\ndone; give the screen a few seconds to apply the update")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", required=True, help="serial device, e.g. /dev/ttyS4 (or a pyserial url)")
    p.add_argument("--baud", type=int,
                   help="baud rate (default 115200; scan tries all when omitted). With --iac (ser2net/telnet) an "
                        "explicitly set value is also sent to ser2net at connect as an RFC 2217 SET-BAUDRATE subneg "
                        "(option 44; omitted = no subneg). On this USB CDC-ACM link that is nominal (no throughput "
                        "change) and a rate different from the panel's current one (115200) makes it re-init the "
                        "console (no comok); the real device-side lever is the panel's own `baud=` command.")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--iac", action="store_true",
                   help="the ser2net/telnet link escapes 0xFF (IAC): double it on send, un-double on receive (default off = raw)")

    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan").set_defaults(fn=cmd_scan)
    t = sub.add_parser("touch")
    t.add_argument("--seconds", type=float, default=15)
    t.set_defaults(fn=cmd_touch)
    sub.add_parser("draw").set_defaults(fn=cmd_draw)
    sub.add_parser("soft-reset", help="DRAKJHSUYDGBNCJHGJKSHBDN: the official 'exit active-parse mode' magic string (doc/tjcwiki), puts a screen stuck mid-command back to idle, same baud rate").set_defaults(fn=cmd_soft_reset)
    sub.add_parser("recover", help="soft-reset, then find a screen that sits at another baud rate and bring it back to 115200").set_defaults(fn=cmd_recover)
    r = sub.add_parser("raw")
    r.add_argument("commands", nargs="+")
    r.add_argument("--wait", type=float, default=0.5)
    r.set_defaults(fn=cmd_raw)

    k = sub.add_parser("peek", help="read panel memory as a hex dump; -w FILE saves the binary dump (needs the stage1 image's peek blob running)")
    k.add_argument("addr", type=lambda s: int(s, 0), help="start address (0x hex or decimal)")
    k.add_argument("length", type=lambda s: int(s, 0), help="bytes to dump (must be < 0x4000 and inside one readable window)")
    k.add_argument("-w", "--write", metavar="FILE", help="write the binary dump to FILE (raw bytes, no hex formatting)")
    k.add_argument("--wait", type=float, default=3.0, help="max seconds to wait for the dump (a 0.6 s quiet period ends it early)")
    k.set_defaults(fn=cmd_peek)

    pk = sub.add_parser("poke", help="write panel memory (needs the stage1 image's poke blob running): 1-255 bytes of hex, or a whole file as @file in 255-byte chunks; a success answers no frame, --verify re-reads with peek (hex only)")
    pk.add_argument("addr", type=lambda s: int(s, 0), help="start address (0x hex or decimal), inside one readable window (no alignment needed)")
    pk.add_argument("data", help="the bytes to write as hex, 1-255 bytes (2 digits per byte; an optional 0x prefix is fine), or @<filename> to write the whole file (255-byte chunks, each confirmed by the Z beacon)")
    pk.add_argument("--verify", action="store_true", help="after a successful poke, peek the range back and compare (hex mode only)")
    pk.add_argument("--wait", type=float, default=3.0, help="max seconds to wait for the readback (a 0.6 s quiet period ends it early)")
    pk.set_defaults(fn=cmd_poke)

    sh = sub.add_parser("shot", help="screenshot of the live framebuffer 0x60EC00 (480x272 RGB565, one 261120-byte peek): PNG by default, --raw saves it as-is (needs the stage1 image's peek blob running)")
    sh.add_argument("file", help="output path; without --raw a .png extension is added when missing (raw: as-is, 261120 bytes)")
    sh.add_argument("--raw", action="store_true", help="save the framebuffer as-is (raw RGB565, 261120 bytes) instead of a PNG")
    sh.add_argument("--wait", type=float, default=10.0, help="max seconds to wait for the full dump (a 0.6 s quiet period ends it early)")
    sh.set_defaults(fn=cmd_shot)

    sh = sub.add_parser("shell", help="one console open, then a peek/poke/raw REPL on the same link (the 3.5-5 s comok is paid once)")
    sh.add_argument("--wait", type=float, default=3.0, help="max seconds per command (a 0.6 s quiet period ends it early)")
    sh.set_defaults(fn=cmd_shell)

    u = sub.add_parser("upload")
    u.add_argument("file")
    u.add_argument("--target", default="ram/probe.jpg")
    u.add_argument("--repeat", type=int, default=3)
    u.add_argument("--page", type=int, help="switch to this page after a successful upload (the picture is drawn when its page loads)")
    u.add_argument("--bkcmd", type=int, choices=(0, 1, 2, 3), help="set bkcmd (reply level) first; 0 = no replies")
    u.add_argument("--delete", action="store_true", help="delfile the target first (the stock client does this before a retry)")
    u.add_argument("--no-touch", action="store_true", help="tsw 255,0 during the upload like the stock client does for thumbnails")
    u.add_argument("--fast", type=int, help="switch the screen to this baud rate (e.g. 230400) for the upload and back afterwards (needs --yes-baud)")
    u.add_argument("--yes-baud", action="store_true", help="accept that a failed baud rate change needs a power cycle")
    u.add_argument("--raw", action="store_true", help="send the file bytes without the 3A A1 BB 44 framing (plain twfile)")
    u.add_argument("--wait-fe", action="store_true", help="wait up to 1 s for the 0xFE (ready for data) reply to twfile")
    u.set_defaults(fn=cmd_upload)

    b = sub.add_parser("bench")
    b.add_argument("--count", type=int, default=500)
    b.add_argument("--fast", type=int, help="also measure at this baud rate, e.g. 230400 (needs --yes-baud)")
    b.add_argument("--yes-baud", action="store_true", help="accept that a failed baud rate change needs a power cycle")
    b.set_defaults(fn=cmd_bench)

    f = sub.add_parser("flash")
    f.add_argument("file")
    f.add_argument("--start-baud", type=int, default=115200,
                   help="baud rate the screen answers at before the transfer (9600 for a screen without a valid .tft)")
    f.add_argument("--flash-baud", type=int, default=921600)
    f.add_argument("--yes-flash", action="store_true", help="really write the file (otherwise only verify it)")
    f.set_defaults(fn=cmd_flash)
    a = p.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
