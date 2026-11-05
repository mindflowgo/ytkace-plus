import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from inspect_recommendations import ObjCImage
from macho_inject import MachOError

BASE = 0x100000000


def fixture(relative=True):
    data = bytearray(0x1000)
    struct.pack_into("<IiiIIIII", data, 0, 0xFEEDFACF, 0x0100000C, 0, 2, 1, 152, 0, 0)
    struct.pack_into("<II16sQQQQiiII", data, 32, 0x19, 152, b"__TEXT", BASE,
                     len(data), 0, len(data), 7, 5, 1, 0)
    struct.pack_into("<16s16sQQI", data, 104, b"__objc_classlist", b"__DATA_CONST", BASE + 0x200, 8, 0x200)
    struct.pack_into("<Q", data, 0x200, BASE + 0x280)
    struct.pack_into("<5Q", data, 0x280, BASE + 0x2C0, 0, 0, 0, BASE + 0x300)
    struct.pack_into("<5Q", data, 0x2C0, 0, 0, 0, 0, BASE + 0x350)
    struct.pack_into("<Q", data, 0x300 + 24, BASE + 0x400)
    struct.pack_into("<Q", data, 0x300 + 32, BASE + 0x500)
    struct.pack_into("<Q", data, 0x350 + 24, BASE + 0x400)
    data[0x400:0x408] = b"Fixture\0"
    data[0x420:0x427] = b"fetch:\0"
    data[0x440:0x44B] = b"v24@0:8@16\0"
    if relative:
        struct.pack_into("<II", data, 0x500, 0x8000000C, 1)
        struct.pack_into("<iii", data, 0x508, 0x600 - 0x508, 0x440 - 0x50C, 0x700 - 0x510)
        struct.pack_into("<Q", data, 0x600, BASE + 0x420)
    else:
        struct.pack_into("<IIQQQ", data, 0x500, 24, 1, BASE + 0x420, BASE + 0x440, BASE + 0x700)
    return data


class InspectRecommendationTests(unittest.TestCase):
    def test_relative_method_and_signed_type_offset(self):
        result = ObjCImage(fixture()).inspect(["Fixture", "Missing"])
        method = result["classes"]["Fixture"]["instanceMethods"][0]
        self.assertEqual(method, {"selector": "fetch:", "types": "v24@0:8@16", "implementation": "0x100000700"})
        self.assertEqual(result["missingClasses"], ["Missing"])

    def test_absolute_method(self):
        image = ObjCImage(fixture(relative=False))
        self.assertEqual(image.inspect(["Fixture"])["classes"]["Fixture"]["instanceMethods"][0]["selector"], "fetch:")

    def test_chained_offset_rebase_and_bind(self):
        data = fixture()
        struct.pack_into("<Q", data, 0x600, (2 << 51) | 0x420)
        image = ObjCImage(data)
        image.pointer_format = 6
        self.assertEqual(image.pointer(BASE + 0x600), BASE + 0x420)
        struct.pack_into("<Q", data, 0x600, 1 << 63)
        self.assertEqual(image.pointer(BASE + 0x600), 0)

    def test_rejects_unmapped_address(self):
        with self.assertRaises(MachOError):
            ObjCImage(fixture()).string(BASE + 0x2000)


if __name__ == "__main__":
    unittest.main()
