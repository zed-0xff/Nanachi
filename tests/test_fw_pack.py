import os
import struct
import sys
import unittest

from helpers import ROOT

sys.path.insert(0, os.path.join(ROOT, "tools"))
import fw_pack as P  # noqa: E402
import fw_unscramble as U  # noqa: E402

try:
    import elftools  # noqa: F401
    import shutil
    HAVE_TOOLCHAIN = shutil.which("clang") is not None
except ImportError:
    HAVE_TOOLCHAIN = False


class Pack(unittest.TestCase):
    def test_round_trip(self):
        image = bytearray(0x900)
        struct.pack_into("<I", image, 0, 0x800000)
        struct.pack_into("<I", image, 4, 0x349)
        image[0x800:] = b"\xAB" * 0x100
        packed = P.pack(bytes(image), key=0x1234)
        out, info = U.unscramble(packed)
        self.assertTrue(info["header_crc_ok"] and info["image_crc_ok"])
        # pack() fills in the header fields itself (length, key, the two CRCs); everything else round-trips unchanged
        self.assertEqual(out[:0x1C8], bytes(image[:0x1C8]))
        self.assertEqual(out[0x268:], bytes(image[0x268:]))

    def test_key_zero_is_plain(self):
        image = bytearray(0x800)
        packed = P.pack(bytes(image), key=0)
        self.assertEqual(packed[:0x1C8], image[:0x1C8])

    def test_rejects_bad_sizes(self):
        self.assertRaises(ValueError, P.pack, b"\0" * 0x100)       # shorter than the header
        self.assertRaises(ValueError, P.pack, b"\0" * 0x801)       # not a multiple of 4


@unittest.skipUnless(HAVE_TOOLCHAIN, "needs clang and pyelftools to assemble tools/sdboot.S")
class SdBoot(unittest.TestCase):
    def test_payload_is_the_stock_image_untouched(self):
        stock = bytes(range(256)) * 4            # stand-in for app_10000_plain.bin, not a real firmware image
        made = P.sdboot_image(stock)
        img, info = U.unscramble(made)
        self.assertTrue(info["header_crc_ok"] and info["image_crc_ok"])
        self.assertEqual(img[P.PAYLOAD_AT:P.PAYLOAD_AT + len(stock)], stock)

    def test_start_code_fits_before_the_payload(self):
        made = P.sdboot_image(b"\0" * 0x40)
        img, _ = U.unscramble(made)
        self.assertEqual(len(img), P.PAYLOAD_AT + 0x40)

    def test_vectors_point_at_the_copy_loop(self):
        made = P.sdboot_image(b"\0" * 0x40)
        img, _ = U.unscramble(made)
        sp, reset = struct.unpack_from("<II", img, 0)
        self.assertEqual(sp, 0x20000680)
        self.assertTrue(reset & 1)                # Thumb


if __name__ == "__main__":
    unittest.main()
