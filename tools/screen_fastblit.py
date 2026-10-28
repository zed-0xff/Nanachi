#!/usr/bin/env python3
"""Mirrors a picture source onto the screen via the fast-blit firmware hook instead of JPEG +
`exp0`/`ref` (see screen_bridge.py for that older approach). The hook (injected into a patched
`app_10000_plain.bin`/`TFWriter_AiHmiT7.bin.make`, see the actr-decryptor/klipperscreen-goal
memory) intercepts any `twfile` transfer targeting the reserved name `ram/z` *before* it ever
touches the ram-disk, decodes a tiny (x,y,w,h) header + an RLE-compressed RGB565 pixel stream,
and writes straight into the framebuffer via the firmware's own `sub_12104` fill primitive - no
ram-disk write, no `ref`, and critically none of the `delfile`-style full-page dirty-cascade
repaint that the JPEG/`exp0` and `ramv` approaches both had to work around. Because each sent
rectangle carries its own position/size, partial-screen updates are a first-class feature here
(`exp0` could only ever redraw its whole bound widget, see screen_bridge.py's docstring) - only
the rectangles that actually changed are sent.

RLE compresses well on flat UI content (KlipperScreen's panels, text, gauges) and poorly on
photographic content - this protocol is not meant for the old picture-file test source, use
screen_bridge.py for that; this one targets the real KlipperScreen/X11 use case.

  screen_fastblit.py --port /dev/cu.usbmodemXXXX --source x
  screen_fastblit.py --port /dev/cu.usbmodemXXXX --latency-test 50
"""
import argparse
import os
import struct
import sys
import time

from . import screen_probe as sp  # noqa: E402
from . import screen_bridge as _sb  # noqa: E402
from .screen_bridge import (Bridge, Link, StaticSource, ViewOnly, XSource,  # noqa: E402
                            changed_rects, W, H)

try:
    import numpy as np
except ImportError:
    np = None

TARGET = "ram/z"
MAX_BAND_PIXELS = 14000   # 14000 px * 4 B (worst-case RLE) + 8 B header stays under MAX_BATCH_BYTES
DEFAULT_FPS = 200.0          # upper bound only; the real limit is the serial link
DEFAULT_CPU_BUDGET = 1.0     # no CPU throttling: it stretched the frame interval up to 2 s
MAX_BATCH_BYTES = 60000      # firmware SCRATCH is 64 KB (minus the length word)
FIRST_BATCH_BYTES = 1200     # small rectangles go out first (~13 ms on the wire): the visible reaction to a tap arrives early
DRAW_CMD = "blitrle"   # ASCII command word must be 5-8 characters (the hook only sees words of that length)


class ReconnectingXSource:
    """XSource that survives the Xvfb/KlipperScreen container restarting (KlipperScreen exits on some
    errors and Docker restarts it): grab() reconnects and reports a fresh frame, so the bridge redraws."""

    def __init__(self, display=None):
        self.display = display
        self.inner = None
        self.reconnected = False
        self._connect(retries=1)

    def _connect(self, retries=60):
        for _ in range(retries):
            try:
                self.inner = XSource(self.display)
                return True
            except Exception:
                time.sleep(1.0)
        return False

    def grab(self):
        while True:
            try:
                return self.inner.grab()
            except Exception:
                self.reconnected = True
                self.inner = None
                if not self._connect():
                    raise RuntimeError("X display did not come back")

    def inject(self, kind, x, y):
        try:
            self.inner.inject(kind, x, y)
        except Exception:
            pass


class FastLink(Link):
    """Link without the JPEG-era page setup (page switch, hidden widgets, warm-up picture): the hook
    draws straight into the framebuffer, so all that is needed is a live connection, silent replies
    and touch events. The patched image must be running (SD boot, see the usb-relay/camera notes)."""

    def open(self):
        self.s = sp.Screen(self.port, self.slow, self.verbose)
        if not sp._connect(self.s):
            for _ in range(3):
                self.s.ser.write(sp.TWFILE_EXIT)
            self.s.ser.flush()
            time.sleep(0.3)
            if not sp._connect(self.s, 3):
                # a bridge that was killed leaves the screen at the fast baud rate: find it there, bring it back
                self.s.ser.baudrate = self.fast or 921600
                sp._settle(self.s)
                if not sp._connect(self.s):
                    raise RuntimeError("the screen does not answer at 115200 or at the fast rate (power cycle it)")
                sp._restore_baud(self.s, self.slow)
                if not sp._connect(self.s):
                    raise RuntimeError("could not bring the screen back to 115200")
        for cmd in ("bkcmd=0", "tsw 255,0", "sendxy=1"):
            self.s.ask(cmd, 0.3)
        if self.fast and self.fast != self.slow and not sp._switch_baud(self.s, self.fast, self.slow):
            raise RuntimeError("could not move the screen to the fast baud rate")
        self.s.ser.timeout = 0.005
        self.rx = b""
        self.touch_q = []
        if not self.warm_up():
            raise RuntimeError("fast-blit receiver does not answer (is the patched image running?)")

    def resync(self):
        """After a failed attempt: flush the command parser with bare terminators (Link.upload already
        sent the end-of-file frames itself if a transfer had really started) and drop stale bytes."""
        time.sleep(0.05)
        self.s.ser.write(sp.END * 3)
        self.s.ser.flush()
        time.sleep(0.1)
        self.rx = b""
        self.s.ser.reset_input_buffer()

    def warm_up(self, tries=6):
        """The first transfers after a baud change often fail: burn them on a tiny throw-away upload
        (it only stages bytes in SCRATCH, nothing is drawn)."""
        junk = struct.pack("<HHHH", 0, 0, 0, 0)
        for _ in range(tries):
            if self.upload(junk, TARGET):
                return True
            self.resync()
        return False

    def send_batch(self, payload, retries=3):
        """One twfile of back-to-back rectangle records, then the draw command. No barrier: the next
        twfile is only answered (0xFE) after the screen has worked off the draw."""
        for _ in range(retries):
            if self.upload(payload, TARGET):
                self.command(DRAW_CMD)
                return True
            self.resync()
        return False


def to_rgb565(region):
    """PIL RGB Image -> flat list of w*h RGB565 ints, row-major."""
    w, h = region.size
    if np is not None:
        arr = np.asarray(region, dtype=np.uint32)
        r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
        packed = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        return packed.reshape(-1).tolist()
    px = region.load()
    return [((px[x, y][0] >> 3) << 11) | ((px[x, y][1] >> 2) << 5) | (px[x, y][2] >> 3)
            for y in range(h) for x in range(w)]


def rle_encode(pixels):
    """[(count:u16, pixel:u16), ...] run-length encoding of consecutive identical values,
    matching the firmware hook's decoder exactly (see fast_blit_hook.c's blit_rle)."""
    out = bytearray()
    i, n = 0, len(pixels)
    while i < n:
        j = i
        while j < n and pixels[j] == pixels[i] and (j - i) < 0xFFFF:
            j += 1
        out += struct.pack("<HH", j - i, pixels[i])
        i = j
    return bytes(out)


def fastblit_payload(x, y, w, h, region):
    return struct.pack("<HHHH", x, y, w, h) + rle_encode(to_rgb565(region))


def fastcost(w, h):
    """ms to send+draw a rectangle on this protocol (about 0.35 B/pixel at ~90 KB/s): only the
    8-byte record header is saved by merging, so merge only when the union is hardly bigger."""
    return 0.1 + 0.004 * w * h


def band_rects(rects):
    """Row bands so one record's worst case (4 B per pixel) fits the receive buffer."""
    for (x, y, w, h) in rects:
        band = max(1, MAX_BAND_PIXELS // w)
        for by in range(y, y + h, band):
            yield (x, by, w, min(band, y + h - by))


class FastBridge(Bridge):
    """Whole frame = a few batched transfers: small rectangles first (fast feedback), the rest after;
    every transfer is one twfile + one draw command, whatever the number of rectangles in it."""

    click = False      # off by default: both unexplained resets/USB drops (2026-10-23) happened only in runs with the buzzer click on
    debug_page = False

    def _emit(self, events):
        super()._emit(events)
        if self.click and any(kind == "press" for kind, _, _ in events):
            self.link.command("beep 20")      # the buzzer ignores the duration (always the same short beep)
        if self.debug_page and any(kind == "release" for kind, _, _ in events):
            time.sleep(0.2)
            self.log(f"  page after touch: dp={self.link.get('dp')}")

    def _batches(self, img, rects):
        recs = []
        for (x, y, w, h) in band_rects(rects):
            recs.append(((w * h), fastblit_payload(x, y, w, h, img.crop((x, y, x + w, y + h)))))
        recs.sort(key=lambda r: r[0])
        batches, cur, size, first = [], [], 0, True
        for _, payload in recs:
            limit = FIRST_BATCH_BYTES if first else MAX_BATCH_BYTES
            if cur and size + len(payload) > limit:
                batches.append(b"".join(cur))
                cur, size, first = [], 0, False
                limit = MAX_BATCH_BYTES
            cur.append(payload)
            size += len(payload)
        if cur:
            batches.append(b"".join(cur))
        return batches

    def step(self):
        self._poll_touch()
        now = time.time()
        if now - self.last_send >= self.min_interval:
            t_grab = time.time()
            img = self.source.grab().convert("RGB")
            if img.size != (W, H):
                img = img.resize((W, H))
            if getattr(self.source, "reconnected", False):
                self.source.reconnected = False
                self.prev = None
            rects = changed_rects(self.prev, img)
            if rects:
                ok = True
                first_done = None
                for payload in self._batches(img, rects):
                    t = time.time()
                    if not self.link.send_batch(payload):
                        ok = False
                        break
                    self.stats["rects"] += 1
                    self.stats["bytes"] += len(payload)
                    self.log(f"batch {len(payload)} B in {time.time() - t:.3f} s")
                    if first_done is None:
                        first_done = time.time()
                    self._poll_touch()
                if ok:
                    self.stats.setdefault("lat", []).append((t_grab, first_done, time.time()))
                    self.prev = img
                    self.stats["pictures"] += 1
                else:
                    self.prev = None
                    self.stats["failed"] += 1
                self.last_send = time.time()
        self._throttle()

    def run(self, seconds=None):
        end = time.time() + seconds if seconds else None
        while end is None or time.time() < end:
            self.step()
            time.sleep(0.001)


def latency_test(link, n):
    """Sends n small solid-color rectangles back to back - the thing this whole protocol exists
    to make fast; compare against screen_bridge.py's measured ~0.3-1.0s JPEG/twfile floor."""
    from PIL import Image
    img = Image.new("RGB", (32, 32), (255, 0, 0))
    t = time.time()
    ok = 0
    for i in range(n):
        payload = fastblit_payload(0, 0, 32, 32, img)
        if link.send_batch(payload):
            ok += 1
    elapsed = time.time() - t
    print(f"{ok}/{n} ok in {elapsed:.3f}s ({elapsed / n * 1000:.1f} ms/rect)")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", required=True)
    p.add_argument("--source", nargs="+", help="picture files shown in turn (every 4 s), or `x` for the X display")
    p.add_argument("--fast-baud", type=int, default=921600)
    p.add_argument("--fps", type=float, default=DEFAULT_FPS)
    p.add_argument("--cpu-budget", type=float, default=DEFAULT_CPU_BUDGET)
    p.add_argument("--seconds", type=float)
    p.add_argument("--view-only", action="store_true")
    p.add_argument("--click", action="store_true", help="buzzer beep on touch (suspected of causing power dips/resets, off by default)")
    p.add_argument("--debug-page", action="store_true", help="log the screen's current page id after every touch")
    p.add_argument("--latency-test", type=int, metavar="N")
    a = p.parse_args()
    import signal
    signal.signal(signal.SIGTERM, signal.default_int_handler)   # kill/pkill: still restore the screen's baud rate

    link = FastLink(a.port, a.fast_baud)
    link.open()
    try:
        if a.latency_test:
            latency_test(link, a.latency_test)
            return 0
        src = ReconnectingXSource() if a.source == ["x"] else StaticSource(a.source)
        if a.view_only:
            src = ViewOnly(src)
        bridge = FastBridge(link, src, a.fps, a.cpu_budget)
        bridge.click = a.click
        bridge.debug_page = a.debug_page
        try:
            bridge.run(a.seconds)
        except KeyboardInterrupt:
            pass
        print({k: v for k, v in bridge.stats.items() if k != "lat"}, f"CPU {time.process_time():.2f} s")
    finally:
        link.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
