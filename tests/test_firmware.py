import os
import struct
import sys
import unittest

from helpers import ROOT, T

sys.path.insert(0, os.path.join(ROOT, "tools"))
import fw_tables  # noqa: E402
import fw_unscramble  # noqa: E402

# the plain image of the Sovol SV08 Max screen firmware, next to the Nanachi checkout (not part of it)
FIRMWARE = os.path.join(os.path.dirname(ROOT), "app_10000_plain.bin")


def _scrambled(payload_words, key):
    """A tiny image in the loader format: 0x800 byte header + payload, XORed with the key like the stock loader expects."""
    length = 0x800 + 4 * len(payload_words)
    plain = bytearray(length)
    struct.pack_into("<I", plain, 0, 0x800000)                          # initial stack pointer
    for i, w in enumerate(payload_words):
        struct.pack_into("<I", plain, 0x800 + 4 * i, w)
    struct.pack_into("<I", plain, 464, length)
    struct.pack_into("<I", plain, 472, key ^ length)
    img = bytearray(plain)
    for lo, hi in ((0, 0x1C8), (616, 0x800), (0x800, length)):
        for o in range(lo, hi, 4):
            struct.pack_into("<I", img, o, struct.unpack_from("<I", img, o)[0] ^ key)
    struct.pack_into("<I", img, 468, fw_unscramble.crc32_words(bytes(img[0x800:length]), fw_unscramble.crc32_words(
        bytes(img[616:0x800]), fw_unscramble.crc32_words(bytes(img[0:0x1C8])))))
    struct.pack_into("<I", img, 456, fw_unscramble.crc32_words(bytes(img[460:616])))
    return bytes(plain), bytes(img)


class Unscramble(unittest.TestCase):
    def test_round_trip(self):
        plain, scrambled = _scrambled([1, 2, 3, 0xDEADBEEF], 0x1234)
        out, info = fw_unscramble.unscramble(scrambled)
        self.assertTrue(info["header_crc_ok"] and info["image_crc_ok"])
        self.assertEqual(info["key"], 0x1234)
        self.assertEqual(struct.unpack_from("<I", out, 0)[0], 0x800000)
        self.assertEqual(out[0x800:], plain[0x800:])

    def test_corruption_is_seen(self):
        _, scrambled = _scrambled([1, 2, 3, 4], 0x55)
        bad = bytearray(scrambled)
        bad[0x802] ^= 1
        self.assertFalse(fw_unscramble.unscramble(bytes(bad))[1]["image_crc_ok"])

    def test_hardware_crc_of_known_input(self):
        self.assertEqual(fw_unscramble.crc32_words(b"\x00\x00\x00\x00"), 0xC704DD7B)    # STM32 CRC unit: one zero word


class Tables(unittest.TestCase):
    def test_synthetic(self):
        blob = b"\xAA" * 7 + b"click\0\0\0" + bytes([0, 2, 0x6F, 0x23]) + b"comok\0\0\0" + bytes([5, 7, 255, 0])
        blob += b"i\0\0\0" + bytes([0, 0, 0, 0]) + b"page" + bytes([0, 1, 0x79, 9]) + b"\0" * 8
        t = fw_tables.extract(blob)
        self.assertEqual([e["name"] for e in t["long"]], ["click", "comok"])
        self.assertEqual([e["name"] for e in t["short"]], ["i", "page"])
        self.assertEqual(t["long"][0]["f"], [0, 2, 0x6F, 0x23])
        self.assertEqual((t["long"][0]["comindex"], t["long"][0]["canqyt"], t["long"][0]["canlei"], t["long"][0]["res"]), (0, 2, 0x6F, 0x23))

    @unittest.skipUnless(os.path.isfile(FIRMWARE), "needs the unscrambled firmware image next to the checkout")
    def test_firmware(self):
        with open(FIRMWARE, "rb") as f:
            t = fw_tables.extract(f.read())
        long_names = [e["name"] for e in t["long"]]
        self.assertEqual(len(long_names), 53)
        self.assertEqual(long_names[48], "doevents")             # the same number as TFTTool's operator class 8
        self.assertEqual(long_names[0], "click")
        short_names = [e["name"] for e in t["short"]]
        self.assertEqual(short_names[:5], ["i", "pic", "cle", "ref", "cir"])
        self.assertEqual(len(short_names), 41)
        self.assertIn("ramw", t["hidden"])
        self.assertNotIn("click", t["hidden"])


if __name__ == "__main__":
    unittest.main()


class Header2Key(unittest.TestCase):
    """The key of header 2 is computed from header 1's model_crc (`xor_sub`, the string "A678ert", the chip's CRC unit)."""

    def test_learned_models(self):
        for crc, (_, key) in T.TFTFile._learnedModels.items():
            self.assertEqual(T.TFTFile.header2KeyFromModelCRC(crc), key)

    def test_known_models(self):
        from NextionChecksum import Checksum
        hits = sum(T.TFTFile.header2KeyFromModelCRC(Checksum().CRC(m.encode("ascii"))) == k
                   for m, k in T.TFTFile._modelXORs.items())
        self.assertGreaterEqual(hits, 51)
        self.assertEqual(sum(k == 0 for k in T.TFTFile._modelXORs.values()), 9)            # 51 of the 60 table keys follow the formula, the other 9 are 0 (no encoding)
