#!/usr/bin/env python3
"""Regression tests for YouTube AI Overview structured extraction.

Verifies that the parser traverses YouTube's InnerTube Elements protobuf hierarchy
directly to the answer text field without using destructive heuristic line-splitting
or raw readable-string scanning.

Tested edge cases:
- Real device captures (1167, 1402, 1651 characters)
- Markdown bullets starting with '*'
- Standalone 'Summary' headings
- CJK / Chinese text without whitespace
- Short answers without wire-type prefixes
- Rejection of payloads lacking structured renderers
"""

import base64
import glob
import json
import unittest
from pathlib import Path

ROOT_PATH = [
    1, 1, 1, 153515154, 172660663, 1, 168777401, 5, 413471385, 1,
    2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382, 2, 2, 1
]

BASIC_CONTENT_TAIL = [
    5, 413471385, 1, 1382, 2, 2, 1
]

CHAT_ITEM_TAIL = [
    5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382, 2, 2, 1
]


def encode_varint(n):
    res = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            res.append(b | 0x80)
        else:
            res.append(b)
            break
    return bytes(res)


def encode_field(field_num, wire_type, data):
    tag = (field_num << 3) | wire_type
    if wire_type == 2:
        return encode_varint(tag) + encode_varint(len(data)) + data
    elif wire_type == 0:
        return encode_varint(tag) + encode_varint(data)
    raise NotImplementedError()


def build_synthetic_payload(text):
    cur = text.encode("utf-8")
    for field_num in reversed(ROOT_PATH):
        cur = encode_field(field_num, 2, cur)
    return cur


def traverse_field_path(data, path, step=0):
    if step == len(path):
        try:
            return data.decode("utf-8")
        except Exception:
            return None
    target_field = path[step]
    pos = 0
    length = len(data)
    while pos < length:
        key = 0
        shift = 0
        p = pos
        while p < length and shift < 70:
            b = data[p]
            key |= (b & 0x7F) << shift
            p += 1
            if not (b & 0x80):
                break
            shift += 7
        if p == pos:
            break
        field = key >> 3
        wire = key & 7
        if field == 0:
            break
        pos = p
        if wire == 0:
            while pos < length and (data[pos] & 0x80):
                pos += 1
            pos += 1
        elif wire == 1:
            pos += 8
        elif wire == 2:
            flen = 0
            shift = 0
            p = pos
            while p < length and shift < 70:
                b = data[p]
                flen |= (b & 0x7F) << shift
                p += 1
                if not (b & 0x80):
                    break
                shift += 7
            pos = p
            if pos + flen > length:
                break
            sub = data[pos:pos + flen]
            if field == target_field:
                res = traverse_field_path(sub, path, step + 1)
                if res is not None:
                    return res
            pos += flen
        elif wire == 5:
            pos += 4
        else:
            break
    return None


def extract_answer_from_payload(payload_bytes):
    if len(payload_bytes) < 40:
        return None
    # Method 1: Root path
    ans = traverse_field_path(payload_bytes, ROOT_PATH)
    if ans:
        return ans.strip()

    # Method 2: Subtree search
    def search_subtrees(sub_data, depth=0):
        if depth > 24 or not sub_data:
            return None
        pos = 0
        L = len(sub_data)
        while pos < L:
            key = 0
            shift = 0
            p = pos
            while p < L and shift < 70:
                b = sub_data[p]
                key |= (b & 0x7F) << shift
                p += 1
                if not (b & 0x80):
                    break
                shift += 7
            if p == pos:
                break
            field = key >> 3
            wire = key & 7
            if field == 0:
                break
            pos = p
            if wire == 0:
                while pos < L and (sub_data[pos] & 0x80):
                    pos += 1
                pos += 1
            elif wire == 1:
                pos += 8
            elif wire == 2:
                flen = 0
                shift = 0
                p = pos
                while p < L and shift < 70:
                    b = sub_data[p]
                    flen |= (b & 0x7F) << shift
                    p += 1
                    if not (b & 0x80):
                        break
                    shift += 7
                pos = p
                if pos + flen > L:
                    break
                chunk = sub_data[pos:pos + flen]
                if field == 168777401:
                    if b"basic_content" in chunk:
                        res = traverse_field_path(chunk, BASIC_CONTENT_TAIL)
                        if res:
                            return res.strip()
                    if b"chat_response_item" in chunk:
                        res = traverse_field_path(chunk, CHAT_ITEM_TAIL)
                        if res:
                            return res.strip()
                res = search_subtrees(chunk, depth + 1)
                if res:
                    return res
                pos += flen
            elif wire == 5:
                pos += 4
            else:
                break
        return None

    res = search_subtrees(payload_bytes)
    return res.strip() if res else None


class TestAISummaryExtraction(unittest.TestCase):

    def test_captured_payload_1651_chars(self):
        """Verify real capture with 5 core concepts preserves complete text without metadata."""
        matches = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*6074b85e*.json"
        )
        if not matches:
            self.skipTest("Capture JSON not found")
        with open(matches[0]) as f:
            d = json.load(f)
        raw = base64.b64decode(d["events"][198]["items"][0]["payload"])
        ans = extract_answer_from_payload(raw)

        self.assertIsNotNone(ans)
        self.assertEqual(len(ans), 1651)
        self.assertTrue(ans.startswith("Based on the discussion, here are the top 5 core concepts"))
        self.assertTrue(ans.endswith('independent of the historical "resets" affecting our current world (0:17:12-0:32:51).'))

        # Assert zero metadata or suggestion leakage
        for forbidden in ["capabilities|", "theme|", "AI can make mistakes", "youchat_",
                          "support.google.com", "Load in progress", "How does one practice"]:
            self.assertNotIn(forbidden, ans)

    def test_captured_payload_1402_chars(self):
        """Verify real capture with 1402 chars preserves complete text without metadata."""
        matches = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*6074b85e*.json"
        )
        if not matches:
            self.skipTest("Capture JSON not found")
        with open(matches[0]) as f:
            d = json.load(f)
        raw = base64.b64decode(d["events"][76]["items"][0]["payload"])
        ans = extract_answer_from_payload(raw)

        self.assertIsNotNone(ans)
        self.assertEqual(len(ans), 1402)
        self.assertTrue(ans.startswith("In this astral projection interview, Rick discusses several core"))
        self.assertTrue(ans.endswith("that which we carry within ourselves (11:34 - 11:55)."))
        self.assertNotIn("capabilities|", ans)
        self.assertNotIn("AI can make mistakes", ans)

    def test_captured_payload_1167_chars(self):
        """Verify real capture with 1167 chars preserves complete text without metadata."""
        matches = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*da64654b*.json"
        )
        if not matches:
            self.skipTest("Capture JSON not found")
        with open(matches[0]) as f:
            d = json.load(f)
        raw = base64.b64decode(d["events"][171]["items"][0]["payload"])
        ans = extract_answer_from_payload(raw)

        self.assertIsNotNone(ans)
        self.assertEqual(len(ans), 1167)
        self.assertTrue(ans.startswith("This video features an astral interview with the entity Ra"))
        self.assertTrue(ans.endswith("is a reflection of what you carry within (11:25 - 11:49)."))
        self.assertNotIn("capabilities|", ans)
        self.assertNotIn("AI can make mistakes", ans)

    def test_markdown_bullets_preserved(self):
        """Bullets starting with '*' must not be stripped or treated as suggestion chips."""
        text = "* Bullet item 1\n* Bullet item 2\n* Bullet item 3\n* Final conclusion"
        payload = build_synthetic_payload(text)
        ans = extract_answer_from_payload(payload)
        self.assertEqual(ans, text)

    def test_standalone_heading_preserved(self):
        """Headings like 'Summary' or '# Summary' must not truncate following text."""
        text = "# Summary\n\nHere is the detailed summary:\n1. First point\n2. Second point"
        payload = build_synthetic_payload(text)
        ans = extract_answer_from_payload(payload)
        self.assertEqual(ans, text)

    def test_chinese_without_spaces_preserved(self):
        """Non-spaced CJK text must be extracted fully without failing space count checks."""
        text = "本视频总结了以下五个核心概念：\n第一、出体体验作为探索未知的途径；\n第二、生命本质与意识觉醒。"
        payload = build_synthetic_payload(text)
        ans = extract_answer_from_payload(payload)
        self.assertEqual(ans, text)

    def test_short_answer_without_wire_prefix(self):
        """Short answers must not receive leading '+' or framing characters."""
        text = "Yes, absolutely."
        payload = build_synthetic_payload(text)
        ans = extract_answer_from_payload(payload)
        self.assertEqual(ans, text)

    def test_unstructured_payload_returns_none(self):
        """Payloads lacking the structured renderer layout must return None (no raw byte fallback)."""
        random_bytes = b"capabilities|682a13b229e2cdb0 theme|dark AI can make mistakes random payload"
        ans = extract_answer_from_payload(random_bytes)
        self.assertIsNone(ans)


if __name__ == "__main__":
    unittest.main()
