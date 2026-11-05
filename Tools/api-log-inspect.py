#!/usr/bin/env python3
"""Inspect the recommendation server's api.log (JSONL of raw request data).

Every line is one transform: envelope fields plus the base64 of the untouched
original protobuf. This tool lists, filters, extracts and wire-dumps those
payloads so structures can be reverse-engineered offline.

Examples:
  Tools/api-log-inspect.py --list
  Tools/api-log-inspect.py --contains "Breaking news" --out /tmp/mine
  Tools/api-log-inspect.py --surface home --dump --limit 1
  Tools/api-log-inspect.py --request-id <id> --out /tmp/mine
"""

import argparse
import base64
import json
import sys
from pathlib import Path


def read_entries(path):
    entries = []
    for index, line in enumerate(Path(path).read_text().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            record["payload_bytes"] = base64.b64decode(record.get("payload") or "")
        except Exception:
            continue
        entries.append(record)
    return entries


def read_varint(data, i):
    result = shift = 0
    while i < len(data):
        byte = data[i]
        i += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, i
        shift += 7
        if shift > 63:
            return None, None
    return None, None


def dump_wire(data, indent=0, depth=0, budget=None):
    """Lenient wire dump: field numbers, wire types, printable strings."""
    if budget is None:
        budget = [4000]
    i = 0
    while i < len(data) and depth < 40 and budget[0] > 0:
        key, j = read_varint(data, i)
        if key is None:
            return
        field, wire = key >> 3, key & 7
        i = j
        if field == 0 or field > 536870911 or wire not in (0, 1, 2, 5):
            return
        budget[0] -= 1
        if wire == 0:
            value, i = read_varint(data, i)
            if i is None:
                return
            print("  " * indent + f"f{field}: varint {value}")
        elif wire == 1:
            print("  " * indent + f"f{field}: fixed64")
            i += 8
        elif wire == 5:
            print("  " * indent + f"f{field}: fixed32")
            i += 4
        else:
            length, i = read_varint(data, i)
            if i is None or i + length > len(data):
                return
            segment = data[i:i + length]
            i += length
            try:
                text = segment.decode("utf-8")
                printable = all(32 <= ord(ch) < 127 for ch in text)
            except UnicodeDecodeError:
                text, printable = None, False
            if printable and text is not None:
                print("  " * indent + f"f{field}: {text[:120]!r}")
            else:
                print("  " * indent + f"f{field}: msg({length}B)")
                dump_wire(segment, indent + 1, depth + 1, budget)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", default="api.log")
    parser.add_argument("--list", action="store_true", help="list matching entries")
    parser.add_argument("--request-id")
    parser.add_argument("--surface", choices=["home", "watch", "search", "FEwhat_to_watch"])
    parser.add_argument("--contains", help="payload must contain this text")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--out", type=Path, help="write matching payloads (<requestId>.bin/.json)")
    parser.add_argument("--dump", action="store_true", help="print a wire dump per match")
    args = parser.parse_args()

    entries = read_entries(args.log)
    needle = args.contains.encode() if args.contains else None
    matches = []
    for record in entries:
        if args.request_id and record.get("requestId") != args.request_id:
            continue
        if args.surface and record.get("surface") != args.surface:
            continue
        if needle is not None and needle not in record["payload_bytes"]:
            continue
        matches.append(record)
    if args.limit:
        matches = matches[:args.limit]

    if args.list or not (args.out or args.dump):
        for index, record in enumerate(matches):
            print(f"[{index}] {record.get('time', '?')} {record.get('endpoint', '?')} "
                  f"req={record.get('requestId', '?')} surface={record.get('surface', '?')} "
                  f"phase={record.get('phase', '?')} bytes={len(record['payload_bytes'])} "
                  f"sha256={(record.get('sha256') or '')[:16]}")
        print(f"{len(matches)} of {len(entries)} entries")
        return 0

    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        for record in matches:
            name = record.get("requestId", "unknown")
            (args.out / f"{name}.bin").write_bytes(record["payload_bytes"])
            envelope = {key: value for key, value in record.items() if key != "payload_bytes"}
            (args.out / f"{name}.json").write_text(json.dumps(envelope, indent=2) + "\n")
        print(f"wrote {len(matches)} payload(s) to {args.out}")

    if args.dump:
        for record in matches:
            print(f"=== {record.get('requestId')} {record.get('endpoint')} "
                  f"{record.get('surface')}/{record.get('phase')} ===")
            dump_wire(record["payload_bytes"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
