#!/usr/bin/env python3
"""Read selected Objective-C metadata from a decrypted arm64 YouTube executable.

Supports the plain pointers and DYLD_CHAINED_PTR_64[_OFFSET] rebases used by the
supplied binaries. This is static evidence; it cannot establish block ownership.
"""

import argparse
import json
import mmap
import struct
from pathlib import Path

from macho_inject import MachOError, commands, slices


DEFAULT_CLASSES = (
    "YTAppBrowseService", "YTBrowseService", "YTAppWatchNextService",
    "YTWatchNextService", "YTCompositeWatchNextService", "YTWatchService",
    "YTIBrowseRequest", "YTIBrowseResponse", "YTIWatchNextRequest",
    "YTIWatchNextResponse", "YTBrowseViewController",
)


class ObjCImage:
    def __init__(self, data):
        self.data = data
        images = slices(data)
        if len(images) != 1 or images[0].offset:
            raise MachOError("expected a thin 64-bit Mach-O")
        if struct.unpack_from("<I", data, 4)[0] != 0x0100000C:
            raise MachOError("expected arm64")
        self.segments = []
        self.sections = {}
        self.pointer_format = None
        self.encryption = None
        fixups = None
        for command in commands(data, images[0]):
            pos = command.offset
            if command.command == 0x19:
                name, va, size, offset, file_size, _, _, count, _ = struct.unpack_from(
                    "<16sQQQQiiII", data, pos + 8)
                self.segments.append((va, size, offset, file_size))
                if name.rstrip(b"\0") == b"__TEXT":
                    self.base = va
                for index in range(count):
                    sec, seg, addr, length, fileoff = struct.unpack_from(
                        "<16s16sQQI", data, pos + 72 + index * 80)
                    self.sections[(seg.rstrip(b"\0").decode(), sec.rstrip(b"\0").decode())] = (
                        addr, length, fileoff)
            elif command.command == 0x80000034:
                fixups = struct.unpack_from("<I", data, pos + 8)[0]
            elif command.command == 0x2C:
                self.encryption = struct.unpack_from("<I", data, pos + 16)[0]
        if self.encryption not in (None, 0):
            raise MachOError("executable is still encrypted")
        if fixups is not None:
            starts = fixups + struct.unpack_from("<I", data, fixups + 4)[0]
            count = struct.unpack_from("<I", data, starts)[0]
            formats = set()
            for index in range(count):
                relative = struct.unpack_from("<I", data, starts + 4 + index * 4)[0]
                if relative:
                    formats.add(struct.unpack_from("<H", data, starts + relative + 6)[0])
            if len(formats) != 1 or not formats.issubset({2, 6}):
                raise MachOError(f"unsupported chained pointer formats: {formats}")
            self.pointer_format = formats.pop()

    def offset(self, address, length=1):
        for va, _, offset, file_size in self.segments:
            if va <= address and address + length <= va + file_size:
                return offset + address - va
        raise MachOError(f"unmapped address 0x{address:x}")

    def unpack(self, fmt, address):
        return struct.unpack_from(fmt, self.data, self.offset(address, struct.calcsize(fmt)))

    def pointer(self, address):
        raw = self.unpack("<Q", address)[0]
        if not raw:
            return 0
        if self.pointer_format is None:
            return raw
        if raw >> 63:  # External bind: no local target to dereference.
            return 0
        target = raw & ((1 << 36) - 1)
        high = ((raw >> 36) & 0xFF) << 56
        return (target + (self.base if self.pointer_format == 6 else 0)) | high

    def string(self, address):
        if not address:
            return None
        offset = self.offset(address)
        end = self.data.find(b"\0", offset, min(len(self.data), offset + 65536))
        if end < 0:
            raise MachOError("unterminated metadata string")
        return self.data[offset:end].decode("utf-8")

    def class_ro(self, address):
        return self.pointer(address + 32) & ~7

    def class_name(self, address):
        return self.string(self.pointer(self.class_ro(address) + 24))

    def methods(self, address):
        if not address:
            return []
        flags, count = self.unpack("<II", address)
        relative = bool(flags & 0x80000000)
        direct_names = bool(flags & 0x40000000)
        stride = flags & 0xFFFC
        if count > 100000 or stride < (12 if relative else 24):
            raise MachOError("invalid method list")
        result = []
        for index in range(count):
            entry = address + 8 + index * stride
            if relative:
                nameoff, typeoff, impoff = self.unpack("<iii", entry)
                name = entry + nameoff
                if not direct_names:
                    name = self.pointer(name)
                types = entry + 4 + typeoff
                imp = entry + 8 + impoff
            else:
                name = self.pointer(entry)
                types = self.pointer(entry + 8)
                imp = self.pointer(entry + 16)
            result.append({"selector": self.string(name), "types": self.string(types),
                           "implementation": f"0x{imp:x}"})
        return result

    def inspect(self, names):
        found = {}
        for (_, section), (address, length, _) in self.sections.items():
            if section != "__objc_classlist":
                continue
            for entry in range(address, address + length, 8):
                cls = self.pointer(entry)
                try:
                    name = self.class_name(cls)
                except (MachOError, UnicodeError):
                    continue  # Swift/non-Objective-C metadata can share the list.
                if name not in names:
                    continue
                superclass = self.pointer(cls + 8)
                meta = self.pointer(cls)
                found[name] = {
                    "address": f"0x{cls:x}",
                    "superclass": self.class_name(superclass) if superclass else "<external>",
                    "instanceMethods": self.methods(self.pointer(self.class_ro(cls) + 32)),
                    "classMethods": self.methods(self.pointer(self.class_ro(meta) + 32)),
                }
        return {"cryptid": self.encryption, "chainedPointerFormat": self.pointer_format,
                "classes": found, "missingClasses": sorted(set(names) - set(found))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--class", dest="classes", action="append")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with args.executable.open("rb") as source:
        with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
            result = ObjCImage(data).inspect(args.classes or DEFAULT_CLASSES)
    result["executable"] = str(args.executable)
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
        print(args.output)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
