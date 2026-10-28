#!/usr/bin/env python3
"""Mirrors a picture source (KlipperScreen on a virtual X display) onto the stock Sovol / TJC screen and turns its touch panel into
pointer events. Run on the real screen with the picture-file source and with KlipperScreen in Docker (tools/ks_docker).

How it works (measured on the SV08 Max screen, see sovol/flash_layout.md and the notes in README):
  * the screen runs the stock .tft on page 20 (its objects hidden). Page 90 (an otherwise-empty-looking page meant as a
    blank canvas) was tried and rejected: it is a stock modal dialog page, and dialog pages keep re-painting their own
    background picture on top of anything drawn over them. Page 20 is a plain content page with no such re-paint
    behaviour, and permanently taking it over is fine here since the goal is for KlipperScreen to fully replace the
    native UI, not to coexist with it. The picture is shown through page 20's own `exp0` (`external_picture`) widget,
    patched at build time to cover the whole screen (0,0,480,272; see `patch_tft.py --page 20 --object 10 --geometry
    0,0,480,272`) - every frame is a `twfile` upload to `exp0`'s own compiled `path` (`TARGET`, always the same name)
    followed by `ref exp0` to make it reload. This was chosen over an earlier `ramv`-based approach (`sets "ramv: X, Y,
    path"`, draws directly at X,Y without needing any widget): `ramv` flickers to the page's native content for ~0.1 s on
    every draw after the first one, and separately, deleting or overwriting *any* ram file under the same name
    unconditionally triggers a full native repaint of the whole page (traced to the firmware's `delfile` handler - see
    the screen-update-and-bridge memory for the exact mechanism). `exp0`/`ref` has neither problem: repeated same-name
    overwrite + `ref` is seamless, confirmed at 64x64, 176x176 and a patched 480x272. A tiled multi-widget variant (6
    `external_picture` tiles on page 11 for partial updates) was tried and abandoned: page 11 itself is anomalously slow
    for *any* ram/ file write (confirmed independent of tile count, format or protocol - likely page-specific background
    logic, e.g. a file-list refresh scan, since it is the stock "file_list" page), 3-10x slower than the same-size
    operation on page 20 - see the screen-update-and-bridge memory for the full investigation. Each frame needs a
    180-degree rotation before encoding, like every `external_picture`/"crop"-type (0x3c) widget on this firmware.
  * touch: `sendxy=1` reports press and release (a short tap can fall entirely between two polls, the screen is busy with a picture
    part of the time; the release repeats the coordinates of the press), while a finger is down the system variables `tch0` / `tch1`
    give its position ((0, 0) when nothing touches the panel) and are polled between the pictures. Coordinates are those of the
    upright screen (0,0 top left, x 0..479, y 0..271).
  * the CPU of the printer is the budget: nothing is encoded or sent for an unchanged picture (one C level comparison), the loop wakes up
    about 30 times a second, a `--cpu-budget` keeps the average CPU use of this process under a fraction of one core.

  screen_bridge.py --port /dev/cu.usbmodemXXXX --source x            (DISPLAY of the X server, e.g. 127.0.0.1:99)
  screen_bridge.py --port /dev/cu.usbmodemXXXX --source a.png b.png  (pictures in turn, for tests)
"""
import argparse
import io
import os
import signal
import struct
import sys
import time

from PIL import Image, ImageChops

from . import screen_probe as sp  # noqa: E402

W, H = 480, 272
PAGE = 20                         # page 90 was tried and rejected: it is a dialog page, see the module docstring
TARGET = "ram/176.jpg"             # exp0's compiled `path` attribute - fixed at build time, every frame overwrites this same name
QUALITY = 90                      # 4:4:4: sharp text and edges, the rectangles are small anyway
BLOCK = 16                        # used only to decide whether anything changed at all, see changed_rects()
# objects of page 20 that are above `exp0` (they overlap it): the screen draws them over the picture again at every `ref exp0`
HIDE = ("q0", "t3", "b0", "b1", "b17", "t4", "t5", "t6", "t7")


def encode(img, quality=QUALITY, subsampling=0):
    """The picture (or the part of it) as a baseline JPEG, 4:4:4 by default."""
    out = io.BytesIO()
    img.convert("RGB").save(out, "JPEG", quality=quality, subsampling=subsampling)
    return out.getvalue()


def cost(w, h):
    """Rough time in ms to send and draw a rectangle (fit of the measurements: 25 ms + 5.5 us per pixel)."""
    return 25 + 0.0055 * w * h


def changed_rects(prev, cur, block=BLOCK):
    """Rectangles (x, y, w, h) that cover everything that differs between two pictures of the same size, merged while that is
    cheaper than sending them apart; [] if they are equal and the whole picture if that is cheapest."""
    W_, H_ = cur.size
    if prev is None or prev.size != cur.size:
        return [(0, 0, W_, H_)]
    diff = ImageChops.difference(prev, cur)
    box = diff.getbbox()
    if box is None:
        return []
    gw, gh = (W_ + block - 1) // block, (H_ + block - 1) // block
    x0, y0 = box[0] // block, box[1] // block
    x1, y1 = (box[2] + block - 1) // block, (box[3] + block - 1) // block
    cells = set()
    for gy in range(y0, y1):
        for gx in range(x0, x1):
            if diff.crop((gx * block, gy * block, min((gx + 1) * block, W_), min((gy + 1) * block, H_))).getbbox():
                cells.add((gx, gy))
    boxes = []                                  # connected groups of changed blocks -> boxes in blocks
    while cells:
        stack = [cells.pop()]
        gx0 = gx1 = stack[0][0]
        gy0 = gy1 = stack[0][1]
        while stack:
            cx, cy = stack.pop()
            gx0, gx1, gy0, gy1 = min(gx0, cx), max(gx1, cx), min(gy0, cy), max(gy1, cy)
            for n in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                if n in cells:
                    cells.remove(n)
                    stack.append(n)
        boxes.append((gx0 * block, gy0 * block, min((gx1 + 1) * block, W_) - gx0 * block, min((gy1 + 1) * block, H_) - gy0 * block))
    merged = True
    while merged and len(boxes) > 1:
        merged = False
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i], boxes[j]
                ux, uy = min(a[0], b[0]), min(a[1], b[1])
                uw, uh = max(a[0] + a[2], b[0] + b[2]) - ux, max(a[1] + a[3], b[1] + b[3]) - uy
                if cost(uw, uh) <= cost(a[2], a[3]) + cost(b[2], b[3]):
                    boxes[i] = (ux, uy, uw, uh)
                    del boxes[j]
                    merged = True
                    break
            if merged:
                break
    if sum(cost(w, h) for _, _, w, h in boxes) >= cost(W_, H_):
        return [(0, 0, W_, H_)]
    return boxes


class TouchTracker:
    """press / move / release events out of polled (tch0, tch1); (0, 0) means that nothing touches the panel."""

    def __init__(self):
        self.pos = None

    def press(self, x, y):
        """A press frame of `sendxy`."""
        if self.pos is not None:
            return []
        self.pos = (x, y)
        return [("press", x, y)]

    def release(self):
        """A release frame of `sendxy` (it repeats the coordinates of the press, so the last known position is used)."""
        if self.pos is None:
            return []
        x, y = self.pos
        self.pos = None
        return [("release", x, y)]

    def update(self, x, y):
        events = []
        touching = not (x == 0 and y == 0)
        if touching and self.pos is None:
            events.append(("press", x, y))
        elif touching and (x, y) != self.pos:
            events.append(("move", x, y))
        elif not touching and self.pos is not None:
            events.append(("release", *self.pos))
        self.pos = (x, y) if touching else None
        return events


class Link:
    """The serial connection to the screen. Everything the screen sends is read through `_pump`, which understands the three kinds of
    data that can be on the line at the same time: touch frames of `sendxy` (67 xh xl yh yl state FF FF FF), numbers (71 + 4 bytes + FF FF FF,
    the answer to `get`) and the single byte acknowledgements of a `twfile` transfer (05 / 04 / FD FF FF FF, FE FF FF FF)."""

    def __init__(self, port, fast=921600, page=PAGE, hide=HIDE, verbose=False):
        self.port, self.fast, self.verbose = port, fast, verbose
        self.page, self.hide = page, hide
        self.s = None
        self.slow = 115200
        self.rx = b""
        self.touch_q = []

    def open(self):
        self.s = sp.Screen(self.port, self.slow, self.verbose)
        if not sp._connect(self.s):
            # a transfer that was cut off leaves the screen waiting for file data: the end-of-file frame frees it
            for rate in (self.slow, self.fast or 921600):
                self.s.ser.baudrate = rate
                sp._settle(self.s)
                for _ in range(3):
                    self.s.ser.write(sp.TWFILE_EXIT)
                self.s.ser.flush()
                time.sleep(0.3)
                if sp._connect(self.s, 2):
                    break
            self.s.ser.baudrate = self.slow
            sp._settle(self.s)
        if not sp._connect(self.s):
            # a bridge that was killed leaves the screen at the fast baud rate: find it there and bring it back
            self.s.ser.baudrate = self.fast or 921600
            sp._settle(self.s)
            if not sp._connect(self.s):
                raise RuntimeError("the screen does not answer at 115200 or at the fast rate (power cycle it, or run screen_probe.py recover)")
            sp._restore_baud(self.s, self.slow)
            if not sp._connect(self.s):
                raise RuntimeError("could not bring the screen back to 115200")
        for cmd in ("bkcmd=0", f"page {self.page}", "tsw 255,0", "tm0.en=0") + tuple(f"vis {n},0" for n in self.hide) + ("sendxy=1",):
            self.s.ask(cmd, 0.3)
        time.sleep(1.5)         # the load event of the page draws its own picture for a while: a picture drawn before it is painted over
        if self.fast and not sp._switch_baud(self.s, self.fast, self.slow):
            raise RuntimeError("could not move the screen to the fast baud rate")
        self.s.ser.timeout = 0.005
        self.rx = b""
        self.touch_q = []
        # the first file transfer after a baud rate change often fails: do a throw-away one
        warm = encode(Image.new("RGB", (8, 8)))
        for _ in range(3):
            if self.upload(warm, "ram/warm.jpg") and self.barrier():
                break
        self.command('delfile "ram/warm.jpg"')

    def command(self, cmd):
        self.s.send(cmd)

    def _pump(self, timeout, want=None):
        """Reads and sorts what the screen sends for up to `timeout` seconds. Touch frames go to `touch_q`. Returns, if wanted, the
        first number (want="number"), acknowledgement byte (want="ack") or 0xFE (want="fe") that arrives, else None."""
        end = time.time() + timeout
        ser = self.s.ser
        while True:
            n = ser.in_waiting
            if n:
                self.rx += ser.read(n)
            while self.rx:
                b = self.rx[0]
                if b == 0x67 or b == 0x71:
                    size = 9 if b == 0x67 else 8
                    if len(self.rx) < size:
                        break
                    if self.rx[size - 3:size] == sp.END:
                        if b == 0x67:
                            self.touch_q.append((self.rx[5], *struct.unpack(">HH", self.rx[1:5])))
                        elif want == "number":
                            value = struct.unpack("<i", self.rx[1:5])[0]
                            self.rx = self.rx[size:]
                            return value
                        self.rx = self.rx[size:]
                        continue
                elif want == "ack" and b in (0x05, 0x04):
                    self.rx = self.rx[1:]
                    return b
                elif b == 0xfd or b == 0xfe:
                    if len(self.rx) < 4:
                        break
                    if self.rx[1:4] == sp.END:
                        self.rx = self.rx[4:]
                        if (want == "ack" and b == 0xfd) or (want == "fe" and b == 0xfe):
                            return b
                        continue
                self.rx = self.rx[1:]
            if time.time() >= end:
                return None
            more = self.s.ser.read(64)
            if more:
                self.rx += more

    def get(self, name):
        """Number of a variable, or None."""
        self._pump(0)
        self.s.send("get " + name)
        return self._pump(0.6, "number")

    def barrier(self):
        """Returns when the screen has worked off everything sent so far (it answers commands in order). After a file transfer the screen is
        busy for ~40 ms with the file; a picture asked for in that time is not drawn (seen on the screen)."""
        return self.get("tch0") is not None

    def get_xy(self):
        """Position of the finger from the system variables tch0 / tch1, (0, 0) when nothing touches the panel; None on a bad answer."""
        x, y = self.get("tch0"), self.get("tch1")
        return None if x is None or y is None else (x, y)

    def poll_events(self):
        """Touch frames that arrived: [(state, x, y)] with state 1 press, 0 release."""
        self._pump(0)
        q, self.touch_q = self.touch_q, []
        return q

    def upload(self, data, target):
        """twfile transfer of one file; True when every frame of the transfer was acknowledged (the caller sends its own
        `ref <name>` afterward - which widget(s) use this file isn't `Link`'s business)."""
        self._pump(0)
        self.command(f'twfile "{target}",{len(data)}')
        ok = self._pump(1.5, "fe") == 0xfe      # the screen answers when it has finished drawing the previous picture
        if ok:
            ser = self.s.ser
            for pkt in sp.twfile_packets(data):
                ser.write(pkt)
                ser.flush()
                if self._pump(3.0, "ack") not in (0x05, 0xfd):
                    for _ in range(3):
                        ser.write(sp.TWFILE_EXIT)
                    ok = False
                    break
        return ok

    def close(self):
        if self.s is not None:
            if self.fast:
                sp._restore_baud(self.s, self.slow)
            self.s.close()


class StaticSource:
    """Pictures from files, shown in turn (a stand-in for the X display); pointer events are only printed."""

    def __init__(self, paths, every=4.0):
        self.images = [Image.open(p).convert("RGB") for p in paths]
        self.every = every
        self.t0 = time.time()

    def grab(self):
        return self.images[int((time.time() - self.t0) // self.every) % len(self.images)]

    def inject(self, kind, x, y):
        print(f"  pointer {kind} {x},{y}")


class ViewOnly:
    """Wraps a source: frames pass, pointer events are only printed (so that touching the screen cannot press buttons)."""

    def __init__(self, source):
        self.source = source

    def grab(self):
        return self.source.grab()

    def inject(self, kind, x, y):
        print(f"  (view only) pointer {kind} {x},{y}")


class XSource:
    """A virtual X display (Xvfb) with python-xlib: the root window is the picture, XTEST makes the pointer. NOT TESTED yet."""

    def __init__(self, display=None):
        from Xlib import X, display as xdisplay
        from Xlib.ext import xtest
        self.X, self.xtest = X, xtest
        self.d = xdisplay.Display(display)
        self.root = self.d.screen().root
        geo = self.root.get_geometry()
        self.size = (geo.width, geo.height)

    def grab(self):
        raw = self.root.get_image(0, 0, self.size[0], self.size[1], self.X.ZPixmap, 0xffffffff)
        return Image.frombytes("RGB", self.size, raw.data, "raw", "BGRX")

    def inject(self, kind, x, y):
        X = self.X
        if kind in ("press", "move", "release"):
            self.xtest.fake_input(self.d, X.MotionNotify, x=x, y=y)
            if kind == "press":
                self.xtest.fake_input(self.d, X.ButtonPress, 1)
            elif kind == "release":
                self.xtest.fake_input(self.d, X.ButtonRelease, 1)
            self.d.sync()


class Bridge:
    """Rectangle scheduler and touch loop."""

    def __init__(self, link, source, fps=30.0, cpu_budget=0.10, log=print):
        self.link, self.source = link, source
        self.min_interval = 1.0 / fps
        self.cpu_budget = cpu_budget
        self.log = log
        self.touch = TouchTracker()
        self.prev = None            # what the screen shows (None: unknown, draw everything)
        self.last_send = 0.0
        self.stats = {"pictures": 0, "rects": 0, "failed": 0, "bytes": 0, "touch": 0}
        self._cpu0 = time.process_time()
        self._wall0 = time.time()

    def _draw(self, img):
        # `ramv` draws are tied to the backing ram file's lifetime: deleting it (even well after the draw finished), or
        # overwriting it under the same name, makes the whole page revert to its native content almost immediately (~0.1 s) -
        # traced to the firmware's `delfile` handler, which unconditionally marks the active page dirty on success and cascades
        # to every widget (see the screen-update-and-bridge memory). `ramv` itself also flickers once per *subsequent* draw
        # regardless of file name (an apparent side effect of `load_img`'s own repaint-then-blit).
        # `exp0` + `ref` has neither problem - confirmed seamless (no flicker at all) through repeated same-name overwrite +
        # `ref`, at 64x64, 176x176 and a patched 480x272. `exp0`'s `path` is baked into the compiled usercode at build time
        # (TARGET, not renameable at runtime), so every frame reuses the same file name - no rotating names, no delete, ever.
        # Unlike `ramv` (which draws upright), the `external_picture` widget itself renders 180 degrees rotated (confirmed on
        # hardware, both axes - a vertical-only flip comes out mirrored left/right) - rotate the source image before encoding.
        t = time.time()
        data = encode(img.rotate(180))
        if not self.link.upload(data, TARGET) or not self.link.barrier():
            return False
        self.link.command("ref exp0")
        if not self.link.barrier():
            return False
        self.stats["rects"] += 1
        self.stats["bytes"] += len(data)
        self.log(f"frame {len(data)} B in {time.time() - t:.3f} s")
        return True

    def _throttle(self):
        """Keeps the CPU use of this process under the budget by stretching the interval between pictures."""
        wall = time.time() - self._wall0
        if wall >= 2.0:
            use = (time.process_time() - self._cpu0) / wall
            if use > self.cpu_budget:
                self.min_interval = min(self.min_interval * 1.5, 2.0)
            self._cpu0, self._wall0 = time.process_time(), time.time()

    def _emit(self, events):
        for kind, x, y in events:
            self.stats["touch"] += 1
            self.log(f"touch {kind} {x},{y}")
            self.source.inject(kind, x, y)

    def _poll_touch(self):
        """press / release from the `sendxy` frames, movement from tch0 / tch1 while a finger is down."""
        for state, x, y in self.link.poll_events():
            self._emit(self.touch.press(x, y) if state else self.touch.release())
        if self.touch.pos is not None:
            pos = self.link.get_xy()
            if pos is not None:
                self._emit(self.touch.update(*pos))
        return self.touch.pos is not None

    def step(self):
        self._poll_touch()
        now = time.time()
        if now - self.last_send >= self.min_interval:
            img = self.source.grab().convert("RGB")
            if img.size != (W, H):
                img = img.resize((W, H))
            if changed_rects(self.prev, img):
                ok = self._draw(img)
                self._poll_touch()
                if ok:
                    self.prev = img
                    self.stats["pictures"] += 1
                else:
                    self.prev = None        # the screen may show half of it: draw everything again
                    self.stats["failed"] += 1
                self.last_send = time.time()
        self._throttle()

    def run(self, seconds=None):
        end = time.time() + seconds if seconds else None
        while end is None or time.time() < end:
            self.step()
            time.sleep(0.005 if self.touch.pos is not None else 0.03)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", required=True)
    p.add_argument("--source", nargs="+", help="picture files shown in turn (every 4 s), or `x` for the X display (:DISPLAY env)")
    p.add_argument("--fast-baud", type=int, default=921600, help="0 keeps 115200")
    p.add_argument("--fps", type=float, default=30.0, help="upper limit of the rate of checks for changes")
    p.add_argument("--cpu-budget", type=float, default=0.10, help="average CPU use of this process, 1.0 = one core")
    p.add_argument("--seconds", type=float)
    p.add_argument("--view-only", action="store_true", help="do not inject pointer events (KlipperScreen would press real buttons)")
    a = p.parse_args()
    src = XSource() if a.source == ["x"] else StaticSource(a.source)
    if a.view_only:
        src = ViewOnly(src)
    link = Link(a.port, a.fast_baud)
    link.open()
    bridge = Bridge(link, src, a.fps, a.cpu_budget)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))     # stop like Ctrl-C: the baud rate is restored
    try:
        bridge.run(a.seconds)
    except KeyboardInterrupt:
        pass
    finally:
        link.close()
        print(bridge.stats, f"CPU {time.process_time():.2f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
