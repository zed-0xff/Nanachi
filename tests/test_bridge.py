import io
import os
import sys
import unittest

from PIL import Image

from helpers import ROOT

sys.path.insert(0, os.path.dirname(ROOT))
from tools import screen_bridge as B  # noqa: E402


def pattern(color=(200, 30, 30)):
    img = Image.new("RGB", (480, 272), (10, 10, 30))
    img.paste(color, (0, 0, 100, 50))          # a mark in the top left corner
    return img


class Encode(unittest.TestCase):
    def test_not_turned_and_sharp(self):
        jpeg = B.encode(pattern())
        out = Image.open(io.BytesIO(jpeg)).convert("RGB")
        self.assertEqual(out.size, (480, 272))
        r, g, b = out.getpixel((20, 20))          # ramv draws upright: the mark stays in the top left corner
        self.assertGreater(r, 150)
        self.assertEqual(Image.open(io.BytesIO(jpeg)).layer[0][1:3], (1, 1))       # 4:4:4

    def test_baseline(self):
        im = Image.open(io.BytesIO(B.encode(pattern(), 40)))
        self.assertFalse(im.info.get("progressive"))


class Rects(unittest.TestCase):
    def test_equal_pictures(self):
        self.assertEqual(B.changed_rects(pattern(), pattern()), [])

    def test_first_picture_is_whole(self):
        self.assertEqual(B.changed_rects(None, pattern()), [(0, 0, 480, 272)])

    def test_small_change_small_rect(self):
        a, b = pattern(), pattern()
        b.paste((255, 255, 255), (100, 100, 110, 108))
        (x, y, w, h), = B.changed_rects(a, b)
        self.assertTrue(x <= 100 and y <= 100 and x + w >= 110 and y + h >= 108)
        self.assertLessEqual(w * h, 48 * 48)

    def test_far_apart_changes_stay_apart(self):
        a, b = pattern(), pattern()
        b.paste((255, 255, 255), (4, 4, 12, 12))
        b.paste((255, 255, 255), (460, 255, 476, 268))
        self.assertEqual(len(B.changed_rects(a, b)), 2)

    def test_near_changes_are_merged(self):
        a, b = pattern(), pattern()
        b.paste((255, 255, 255), (100, 100, 108, 108))
        b.paste((255, 255, 255), (130, 100, 138, 108))
        self.assertEqual(len(B.changed_rects(a, b)), 1)

    def test_most_of_the_picture_is_whole(self):
        a, b = pattern(), Image.new("RGB", (480, 272), (200, 200, 200))
        self.assertEqual(B.changed_rects(a, b), [(0, 0, 480, 272)])

    def test_single_pixel_difference_is_seen(self):
        a, b = pattern(), pattern()
        b.putpixel((300, 200), (11, 10, 30))
        self.assertEqual(len(B.changed_rects(a, b)), 1)


class Touch(unittest.TestCase):
    def test_tracker(self):
        t = B.TouchTracker()
        self.assertEqual(t.update(0, 0), [])
        self.assertEqual(t.update(19, 126), [("press", 19, 126)])
        self.assertEqual(t.update(19, 126), [])
        self.assertEqual(t.update(40, 127), [("move", 40, 127)])
        self.assertEqual(t.update(0, 0), [("release", 40, 127)])
        self.assertEqual(t.update(0, 0), [])


class FakeLink:
    def __init__(self):
        self.uploads = []
        self.commands = []
        self.frames = []
        self.values = []
        self.ok = True

    def upload(self, data, target):
        self.uploads.append((target, len(data)))
        return self.ok

    def command(self, cmd):
        self.commands.append(cmd)

    def barrier(self):
        return True

    def get_xy(self):
        return self.values.pop(0) if self.values else (0, 0)

    def poll_events(self):
        q, self.frames = self.frames, []
        return q


class FakeSource:
    def __init__(self, images):
        self.images, self.i, self.events = images, 0, []

    def grab(self):
        return self.images[min(self.i, len(self.images) - 1)]

    def inject(self, kind, x, y):
        self.events.append((kind, x, y))


class Scheduler(unittest.TestCase):
    def make(self, images):
        link, src = FakeLink(), FakeSource(images)
        bridge = B.Bridge(link, src, fps=1000, log=lambda *_: None)
        bridge.min_interval = 0.0
        return link, src, bridge

    def test_whole_picture_first_then_only_on_change(self):
        # exp0 cannot do partial/incremental updates (a smaller picture only paints its own area, the rest reverts to the
        # page's native content - confirmed on hardware), so every change resends the whole frame to the same fixed name.
        changed = pattern()
        changed.paste((255, 255, 255), (200, 100, 216, 116))
        link, src, b = self.make([pattern(), changed])
        b.step()
        self.assertEqual(link.commands, ["ref exp0"])
        self.assertEqual([u[0] for u in link.uploads], [B.TARGET])
        for _ in range(3):
            b.step()                                    # nothing new
        self.assertEqual(len(link.uploads), 1)
        src.i = 1
        b.step()
        self.assertEqual(len(link.uploads), 2)
        self.assertEqual([u[0] for u in link.uploads], [B.TARGET, B.TARGET])      # same fixed name both times, never deleted
        self.assertEqual(link.commands, ["ref exp0", "ref exp0"])
        self.assertNotIn("delfile", " ".join(link.commands))

    def test_failed_upload_means_draw_everything_again(self):
        link, src, b = self.make([pattern()])
        link.ok = False
        b.step()
        self.assertEqual((b.stats["failed"], b.prev), (1, None))
        link.ok = True
        b.step()
        self.assertEqual(b.stats["pictures"], 1)

    def test_touch_events_reach_the_source(self):
        link, src, b = self.make([pattern()])
        link.frames = [(1, 10, 20)]
        link.values = [(10, 20), (12, 21)]
        b.step()
        b.step()
        link.frames = [(0, 10, 20)]            # the release frame repeats the press coordinates; the last moved position is used
        b.step()
        self.assertEqual(src.events, [("press", 10, 20), ("move", 12, 21), ("release", 12, 21)])

    def test_tap_between_polls(self):
        link, src, b = self.make([pattern()])
        link.frames = [(1, 5, 6), (0, 5, 6)]    # both frames arrive together, nothing to poll
        b.step()
        self.assertEqual(src.events, [("press", 5, 6), ("release", 5, 6)])


if __name__ == "__main__":
    unittest.main()
