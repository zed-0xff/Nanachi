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
  bench   draw command throughput at 115200 and (--fast 921600) at a higher baud rate
  flash   write a .tft with `whmi-wri` (what Sovol's `uart` does), only after the .tft checksums verified

Needs pyserial. Stop the stock UI client first (it owns the port): `sudo systemctl stop <service>` / kill it.
Examples:
  screen_probe.py --port /dev/ttyS4 scan
  screen_probe.py --port /dev/ttyS4 touch --seconds 20
  screen_probe.py --port /dev/ttyS4 upload tile.jpg --repeat 5
  screen_probe.py --port /dev/ttyS4 raw 'page 1'
"""
import argparse
import os
import struct
import sys
import time

BAUDS = [115200, 921600, 230400, 460800, 57600, 38400, 19200, 9600, 4800, 2400]
END = b"\xff\xff\xff"

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
    def __init__(self, port, baud, verbose=False):
        import serial
        self.ser = serial.serial_for_url(port, baudrate=baud, timeout=0.05) if "://" in port \
            else serial.Serial(port, baud, timeout=0.05)
        self.verbose = verbose
        self.buf = b""
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


def cmd_scan(a):
    for baud in ([a.baud] if a.baud else BAUDS):
        s = Screen(a.port, baud, a.verbose)
        s.ser.write(END)
        got = s.ask("connect", 0.6)
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
    s = Screen(a.port, a.baud or 115200, a.verbose)
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
    s = Screen(a.port, a.baud or 115200, a.verbose)
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
    s = Screen(a.port, a.baud or 115200, a.verbose)
    for cmd in a.commands:
        print(cmd, "->", [parse_frame(f) for f in s.ask(cmd, a.wait)] or "no reply")


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
    s = Screen(a.port, a.baud or 115200, a.verbose)
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
        print(f"average {sum(rates) / len(rates) / 1024:.1f} KiB/s; a full 480x272 frame as JPEG at this speed: "
              f"~{len(data) / (sum(rates) / len(rates)):.2f} s for a file of this size")


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
    s = Screen(a.port, a.baud or 115200, a.verbose)
    ok = _soft_reset(s)
    s.close()
    print("screen answers" if ok else "no answer; try `recover` (wrong baud rate) or power cycle the screen")
    return 0 if ok else 1


def cmd_recover(a):
    """The screen may be stuck mid-command (fixed by `_soft_reset`, tried first here) or sit at another baud rate than
    the host after a failed `baud` change (send `baud=115200` at every rate and look for the screen at 115200)."""
    target = a.baud or 115200
    s = Screen(a.port, target, a.verbose)
    if _soft_reset(s):
        s.close()
        print(f"screen answers at {target} baud after a soft reset")
        return 0
    s.close()
    for rate in BAUDS:
        s = Screen(a.port, rate, a.verbose)
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
    s = Screen(a.port, a.baud or 115200, a.verbose)
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


def cmd_flash(a):
    here = os.path.dirname(os.path.abspath(__file__))
    # TFTTool is the sibling library at the workspace root (<root>/TFTTool/),
    # i.e. three levels up from this file (tools/ -> Nanachi/ -> root -> TFTTool).
    sys.path.insert(0, os.path.abspath(os.path.join(here, "..", "..", "..", "TFTTool")))
    import TFTTool
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
    s = Screen(a.port, a.start_baud, a.verbose)
    if a.start_baud != a.flash_baud:
        # Change the rate first, with a handshake: bytes sent right after the host side changed its baud rate through a USB
        # serial bridge are unreliable, so the first 4096 byte block of the transfer would be short and never acknowledged.
        if not _switch_baud(s, a.flash_baud, a.start_baud):
            print("could not move the screen to the transfer baud rate")
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
        print(f"\r{min(pos + chunk, len(data)) * 100 // len(data)}%", end="", flush=True)
    print("\ndone; give the screen a few seconds to apply the update")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", required=True, help="serial device, e.g. /dev/ttyS4 (or a pyserial url)")
    p.add_argument("--baud", type=int, help="baud rate (default 115200; scan tries all when omitted)")
    p.add_argument("-v", "--verbose", action="store_true")
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
