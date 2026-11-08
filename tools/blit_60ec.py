#!/usr/bin/env python3
"""FINAL: replace the live display source buffer 0x60EC00 (the continuously
scanned 480x272 RGB565 splash buffer, pbuf->fb, verified 1:1 with the camera
image) with the Nanachi frame (nanachi_stored.rgb565, pre-rotated storage
order) via 255 B pokes. Camera before/after; spot-verify from a fresh console.
RAM-only: a power cycle restores the stock splash from the HMI image bank."""
import os, sys, time, urllib.request
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
from tools.screen_probe import Screen, _open_console, _peek_read, _poke_reply  # noqa: E402

PORT = "socket://rpi2.local:2000"
ADDR = 0x60EC00
CHUNK = 255
SNAP = "http://rpi2.local:9292/api/snapshot"


def open_console():
    for baud in (921600, 115200):
        s = Screen(PORT, baud, iac=True, rfc2217_baud=921600)
        for _ in range(10):
            if _open_console(s):
                print("console up at", baud, flush=True)
                return s
            time.sleep(1.5)
        s.close()
    return None


def poke(s, addr, data):
    s.ser.reset_input_buffer()
    s.send("poke 0x%x,%d,%s" % (addr, len(data), data.hex().upper()))
    _, err, beacons, _ = _poke_reply(s, 2.0)
    return beacons > 0, err


def peek(s, addr, n, wait=4.0):
    s.ser.reset_input_buffer()
    s.send("peek 0x%x,%d" % (addr, n))
    return _peek_read(s, n, wait)[0]


def snap(tag):
    out = os.path.join(HERE, "snap_%s.img" % tag)
    try:
        urllib.request.urlretrieve(SNAP, out)
        im = Image.open(out).convert("L")
        c = np.asarray(im.crop((318, 48, 692, 544)), dtype=float)
        print("  snap %s: mean=%.1f std=%.1f" % (tag, c.mean(), c.std()), flush=True)
        return out
    except Exception as e:
        print("  snap %s FAIL: %r" % (tag, e), flush=True)
        return None


def norm(im, size=(60, 34)):
    g = np.asarray(im.convert("L").resize(size), dtype=float)
    return g - g.mean()


img = open(os.path.join(HERE, "nanachi_stored.rgb565"), "rb").read()
assert len(img) == 261120
total = (len(img) + CHUNK - 1) // CHUNK
print("replacing %d B @ 0x%06X (%d chunks)" % (len(img), ADDR, total), flush=True)

s = open_console()
if not s:
    sys.exit("no console")

# defensive: pbuf struct still points at 0x60EC00?
p = peek(s, 0x760000, 16)
if p:
    import struct
    fb = struct.unpack("<I", p[8:12])[0]
    print("pbuf->fb = 0x%08X %s" % (fb, "OK" if fb == ADDR else "CHANGED!"), flush=True)

snap("final_before")

t0 = time.time()
fails = 0
for i, off in enumerate(range(0, len(img), CHUNK)):
    ok, err = poke(s, ADDR + off, img[off:off + CHUNK])
    if not ok:
        fails += 1
        print("  poke 0x%06X fail (%s) -> re-prime + retry" % (ADDR + off, err), flush=True)
        s.close()
        s = open_console()
        if not s:
            sys.exit("console lost")
        ok, err = poke(s, ADDR + off, img[off:off + CHUNK])
        if not ok:
            print("  retry FAILED at 0x%06X -- aborting" % (ADDR + off), flush=True)
            s.close()
            sys.exit(1)
    if (i + 1) % 128 == 0:
        print("  %d/%d chunks, %d fails, %.1f s"
              % (i + 1, total, fails, time.time() - t0), flush=True)
print("poke done: %d chunks, %d fails, %.1f s" % (total, fails, time.time() - t0), flush=True)
s.close()

# spot-verify from a fresh console: 12 windows across the frame
s = open_console()
if not s:
    sys.exit("no verify console")
offs = [0, 0x2000, 0x8000, 0x10000, 0x16000, 0x1C000,
        0x22000, 0x28000, 0x2E000, 0x32000, 0x36000, 0x3EE00]
bad = 0
for off in offs:
    d = peek(s, ADDR + off, 256)
    if d != img[off:off + 256]:
        bad += 1
        print("  !! 0x%06X: got %d B (mismatch)" % (ADDR + off, len(d) if d else 0), flush=True)
print("verify: %d/12 windows OK" % (12 - bad), flush=True)
s.close()

snap("final_after")
time.sleep(5)
snap("final_after5s")

# correlation vs the expected on-screen Nanachi (pre-rotated storage -> rot180)
exp = norm(Image.open(os.path.join(HERE, "nanachi_expected_screen.png")))
for tag in ("final_after", "final_after5s"):
    out = os.path.join(HERE, "snap_%s.img" % tag)
    if not os.path.exists(out):
        continue
    g = norm(Image.open(out).convert("L").crop((318, 48, 692, 544)))
    c = float((exp * g).sum() / (np.linalg.norm(exp) * np.linalg.norm(g) + 1e-9))
    print("  %s vs nanachi-expected: corr=%.3f" % (tag, c), flush=True)
print("DONE (panel left with Nanachi; power cycle restores stock)")
