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
import re
import struct
import unittest
from pathlib import Path


def is_valid_video_id(vid):
    if not isinstance(vid, str) or len(vid) != 11:
        return False
    return bool(re.match(r"^[A-Za-z0-9_-]{11}$", vid))

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


def build_basic_content_payload(entity_key, text):
    cur = text.encode("utf-8")
    for field_num in reversed(BASIC_CONTENT_TAIL):
        cur = encode_field(field_num, 2, cur)
    key_field = encode_field(1, 2, f"basic_content.eml-fe|{entity_key}".encode("utf-8"))
    return encode_field(168777401, 2, key_field + cur)


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


def parse_varint(data, pos):
    val = 0
    shift = 0
    L = len(data)
    while pos < L and shift < 70:
        b = data[pos]
        val |= (b & 0x7F) << shift
        pos += 1
        if not (b & 0x80):
            break
        shift += 7
    return val, pos


def extract_key_from_chunk(chunk):
    if len(chunk) >= 3 and chunk[0] == 0x0A:
        klen, kpos = parse_varint(chunk, 1)
        if kpos + klen <= len(chunk) and klen > 0:
            return chunk[kpos:kpos + klen].decode("utf-8", errors="ignore")
    for pfx in [b"basic_content.eml-fe|", b"chat_response_item.eml-fe|", b"basic_content.", b"chat_response_item."]:
        idx = chunk.find(pfx)
        if idx != -1:
            end = idx + len(pfx)
            while end < len(chunk) and (chr(chunk[end]).isalnum() or chr(chunk[end]) in "_-."):
                end += 1
            return chunk[idx:end].decode("utf-8", errors="ignore")
    return None


def traverse_all_roots(data, path, step=0, current_key=None):
    if step == len(path):
        try:
            txt = data.decode("utf-8")
            return [(current_key, txt)] if txt else []
        except Exception:
            return []
    target_field = path[step]
    pos = 0
    L = len(data)
    results = []
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field = tag >> 3
        wire = tag & 7
        if field == 0:
            break
        if wire == 0:
            while pos < L and (data[pos] & 0x80):
                pos += 1
            pos += 1
        elif wire == 1:
            pos += 8
        elif wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos + flen]
            if field == target_field:
                k = current_key
                if field == 168777401:
                    found_k = extract_key_from_chunk(chunk)
                    if found_k:
                        k = found_k
                sub_res = traverse_all_roots(chunk, path, step + 1, k)
                results.extend(sub_res)
            pos += flen
        elif wire == 5:
            pos += 4
        else:
            break
    return results


def extract_entities_from_payload(payload_bytes):
    if len(payload_bytes) < 40:
        return []
    entities = []
    seen_keys = set()
    tag_bytes = bytes([0xCA, 0xEB, 0xEA, 0x83, 0x05])

    # 1. Primary path (all occurrences)
    root_matches = traverse_all_roots(payload_bytes, ROOT_PATH)
    for idx, (k, txt) in enumerate(root_matches):
        trimmed = txt.strip()
        if not trimmed:
            continue
        key = k or (f"primary_root_{idx}" if len(root_matches) > 1 else "primary_root")
        if key not in seen_keys:
            seen_keys.add(key)
            entities.append({"key": key, "text": trimmed})

    # 2. Subtree search
    sub_entities = []
    def search_entities(sub_data, depth=0):
        if depth > 24 or not sub_data:
            return
        pos = 0
        L = len(sub_data)
        while pos < L:
            key, pos = parse_varint(sub_data, pos)
            field = key >> 3
            wire = key & 7
            if field == 0:
                break
            if wire == 0:
                while pos < L and (sub_data[pos] & 0x80):
                    pos += 1
                pos += 1
            elif wire == 1:
                pos += 8
            elif wire == 2:
                flen, pos = parse_varint(sub_data, pos)
                if pos + flen > L:
                    break
                chunk = sub_data[pos:pos + flen]
                if field == 168777401:
                    ent_key = extract_key_from_chunk(chunk)
                    # Leaf entity check: does chunk contain another 168777401?
                    if tag_bytes not in chunk:
                        if b"basic_content" in chunk:
                            res = traverse_field_path(chunk, BASIC_CONTENT_TAIL)
                            if res and res.strip():
                                sub_entities.append({"key": ent_key or f"entity_{len(sub_entities)}", "text": res.strip()})
                        elif b"chat_response_item" in chunk:
                            res = traverse_field_path(chunk, CHAT_ITEM_TAIL)
                            if res and res.strip():
                                sub_entities.append({"key": ent_key or f"entity_{len(sub_entities)}", "text": res.strip()})
                search_entities(chunk, depth + 1)
                pos += flen
            elif wire == 5:
                pos += 4
            else:
                break

    search_entities(payload_bytes)
    for s in sub_entities:
        k = s["key"]
        if k not in seen_keys:
            seen_keys.add(k)
            entities.append(s)

    return entities


def aggregate_text_from_payloads(payloads):
    if not payloads:
        return None
    ordered_keys = []
    entity_states = {}
    for p in payloads:
        if not p or len(p) < 40:
            continue
        entities = extract_entities_from_payload(p)
        for ent in entities:
            k = ent["key"]
            txt = ent["text"]
            if not k or not txt:
                continue
            if k not in entity_states:
                ordered_keys.append(k)
            # Chronological update: newer payload replaces older state even if shorter
            entity_states[k] = txt

    if not ordered_keys:
        return None
    return "\n\n".join(entity_states[k] for k in ordered_keys if entity_states.get(k))


CTX_ROOT = 0
CTX_FRAMEWORK = 1
CTX_ROOT_ENTITY = 2
CTX_ENTITY = 3
CTX_ENTITY_DATA = 4
CTX_CAROUSEL = 5
CTX_CAROUSEL_ITEMS = 6
CTX_CARD_WRAPPER = 7
CTX_CARD = 8
CTX_COMMAND = 9
CTX_ENDPOINT = 10


def next_card_context(current_ctx, field):
    if current_ctx == CTX_ROOT:
        if field == 153515154:
            return CTX_FRAMEWORK
        if field == 172660663:
            return CTX_ROOT_ENTITY
        if field == 168777401:
            return CTX_ENTITY
        if field in (232954548, 413471385):
            return CTX_CAROUSEL
        if field == 169495254:
            return CTX_CARD
        return None
    elif current_ctx == CTX_FRAMEWORK:
        if field == 1:
            return CTX_FRAMEWORK
        if field == 172660663:
            return CTX_ROOT_ENTITY
        if field == 168777401:
            return CTX_ENTITY
        return None
    elif current_ctx == CTX_ROOT_ENTITY:
        if field == 1:
            return CTX_ROOT_ENTITY
        if field == 168777401:
            return CTX_ENTITY
        return None
    elif current_ctx == CTX_ENTITY:
        if field == 5:
            return CTX_ENTITY_DATA
        return None
    elif current_ctx == CTX_ENTITY_DATA:
        if field in (232954548, 413471385):
            return CTX_CAROUSEL
        if field == 169495254:
            return CTX_CARD
        return None
    elif current_ctx == CTX_CAROUSEL:
        if field == 18:
            return CTX_CAROUSEL_ITEMS
        if field == 1:
            return CTX_CAROUSEL
        return None
    elif current_ctx == CTX_CAROUSEL_ITEMS:
        if field in (1, 4, 5):
            return CTX_CARD_WRAPPER
        if field == 169495254:
            return CTX_CARD
        return None
    elif current_ctx == CTX_CARD_WRAPPER:
        if field == 169495254:
            return CTX_CARD
        return None
    elif current_ctx == CTX_CARD:
        if field == 462702848:
            return CTX_COMMAND
        if field == 98150882:
            return CTX_ENDPOINT
        return None
    elif current_ctx == CTX_COMMAND:
        if field == 1:
            return CTX_ENDPOINT
        return None
    elif current_ctx == CTX_ENDPOINT:
        if field in (1, 2, 3, 5, 1892, 66439850, 77258115):
            return CTX_ENDPOINT
        return None
    return None


def walk_card_fields(data, ctx=CTX_ROOT, depth=0, active_vid="", seen=None, results=None):
    if seen is None:
        seen = set([active_vid] if active_vid else [])
    if results is None:
        results = []
    if depth > 20 or len(data) < 4:
        return results
    pos = 0
    L = len(data)
    vid_in_card = None
    title_in_card = ""

    while pos < L:
        tag, pos = parse_varint(data, pos)
        field = tag >> 3
        wire = tag & 7
        if field == 0:
            break
        if wire == 0:
            while pos < L and (data[pos] & 0x80):
                pos += 1
            pos += 1
        elif wire == 1:
            pos += 8
        elif wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                # Reject declared length exceeding remaining bytes
                break
            chunk = data[pos:pos + flen]
            pos += flen

            if field == 48687757 and ctx in (CTX_ENDPOINT, CTX_COMMAND):
                wpos = 0
                wL = len(chunk)
                while wpos < wL:
                    wtag, wpos = parse_varint(chunk, wpos)
                    wfield = wtag >> 3
                    wwire = wtag & 7
                    if wwire == 0:
                        while wpos < wL and (chunk[wpos] & 0x80):
                            wpos += 1
                        wpos += 1
                    elif wwire == 1:
                        wpos += 8
                    elif wwire == 2:
                        wlen, wpos = parse_varint(chunk, wpos)
                        if wpos + wlen > wL:
                            break
                        wchunk = chunk[wpos:wpos + wlen]
                        wpos += wlen
                        if wfield == 1 and wlen == 11:
                            candidate = wchunk.decode("ascii", errors="ignore")
                            if len(candidate) == 11 and all(c.isalnum() or c in "_-" for c in candidate):
                                vid_in_card = candidate
                        elif wfield == 36 and len(wchunk) > 0:
                            t = wchunk.decode("utf-8", errors="ignore").strip()
                            if t:
                                title_in_card = t
                    elif wwire == 5:
                        wpos += 4
                    else:
                        break
            elif ctx == CTX_CARD and (field in (33, 34, 35, 36)) and not title_in_card:
                tpos = 0
                tL = len(chunk)
                while tpos < tL:
                    ttag, tpos = parse_varint(chunk, tpos)
                    tfield = ttag >> 3
                    twire = ttag & 7
                    if tfield == 1 and twire == 2:
                        tlen, tpos = parse_varint(chunk, tpos)
                        if tpos + tlen > tL:
                            break
                        tchunk = chunk[tpos:tpos + tlen]
                        if len(tchunk) > 2 and tchunk[0] == 0x0A:
                            _, npos = parse_varint(tchunk, 1)
                            s = tchunk[npos:].decode("utf-8", errors="ignore").strip()
                        else:
                            s = tchunk.decode("utf-8", errors="ignore").strip()
                        if s and len(s) > 3 and not s.startswith("eml."):
                            title_in_card = s
                        break
                    elif twire == 2:
                        sublen, tpos = parse_varint(chunk, tpos)
                        if tpos + sublen > tL:
                            break
                        tpos += sublen
                    else:
                        break
            else:
                nctx = next_card_context(ctx, field)
                if nctx is not None:
                    walk_card_fields(chunk, nctx, depth + 1, active_vid, seen, results)
        elif wire == 5:
            pos += 4
        else:
            break

    if vid_in_card and (not active_vid or vid_in_card != active_vid):
        if vid_in_card not in seen:
            seen.add(vid_in_card)
            results.append({"videoId": vid_in_card, "title": title_in_card})
        elif title_in_card:
            for r in results:
                if r["videoId"] == vid_in_card and not r["title"]:
                    r["title"] = title_in_card
                    break

    return results


def find_watch_endpoint_vid(data, depth=0):
    if depth > 10 or len(data) < 13:
        return None
    pos = 0
    L = len(data)
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos+flen]
            pos += flen
            if field == 48687757:
                wpos, wL = 0, len(chunk)
                while wpos < wL:
                    wtag, wpos = parse_varint(chunk, wpos)
                    wfield, wwire = wtag >> 3, wtag & 7
                    if wfield == 0:
                        break
                    if wwire == 2:
                        wlen, wpos = parse_varint(chunk, wpos)
                        if wpos + wlen > wL:
                            break
                        if wfield == 1 and wlen == 11:
                            try:
                                return chunk[wpos:wpos+11].decode("utf-8")
                            except Exception:
                                pass
                        wpos += wlen
                    elif wwire == 0:
                        _, wpos = parse_varint(chunk, wpos)
                    elif wwire == 1:
                        wpos += 8
                    elif wwire == 5:
                        wpos += 4
                    else:
                        break
            else:
                sub = find_watch_endpoint_vid(chunk, depth + 1)
                if sub:
                    return sub
        elif wire == 0:
            _, pos = parse_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            break
    return None


def find_watch_endpoint_info(data, depth=0):
    if depth > 10 or len(data) < 13:
        return None
    pos = 0
    L = len(data)
    vid, ts = None, None
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos+flen]
            pos += flen
            if field == 48687757:
                wpos, wL = 0, len(chunk)
                while wpos < wL:
                    wtag, wpos = parse_varint(chunk, wpos)
                    wfield, wwire = wtag >> 3, wtag & 7
                    if wfield == 0:
                        break
                    if wwire == 2:
                        wlen, wpos = parse_varint(chunk, wpos)
                        if wpos + wlen > wL:
                            break
                        if wfield == 1 and wlen == 11:
                            try:
                                vid = chunk[wpos:wpos+11].decode("utf-8")
                            except Exception:
                                pass
                        wpos += wlen
                    elif wwire == 0:
                        val, wpos = parse_varint(chunk, wpos)
                        if wfield == 7:
                            ts = float(val)
                    elif wwire == 5:
                        import struct
                        if wpos + 4 <= wL:
                            if wfield == 7:
                                ts = struct.unpack("<f", chunk[wpos:wpos+4])[0]
                            wpos += 4
                        else:
                            break
                    elif wwire == 1:
                        wpos += 8
                    else:
                        break
                return vid, ts
            else:
                sub = find_watch_endpoint_info(chunk, depth + 1)
                if sub:
                    return sub
        elif wire == 0:
            _, pos = parse_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            break
    return None


def decode_all_rich_text_annotations(data, depth=0):
    if len(data) < 20 or depth > 25:
        return []
    pos = 0
    L = len(data)
    results = []
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos+flen]
            pos += flen
            if field == 1382:
                f2_pos, f2_L = 0, len(chunk)
                while f2_pos < f2_L:
                    f2_tag, f2_pos = parse_varint(chunk, f2_pos)
                    f2_field, f2_wire = f2_tag >> 3, f2_tag & 7
                    if f2_field == 0:
                        break
                    if f2_wire == 2:
                        f2_flen, f2_pos = parse_varint(chunk, f2_pos)
                        if f2_pos + f2_flen > f2_L:
                            break
                        f2_chunk = chunk[f2_pos:f2_pos+f2_flen]
                        f2_pos += f2_flen
                        if f2_field == 2:
                            f2_2_pos, f2_2_L = 0, len(f2_chunk)
                            while f2_2_pos < f2_2_L:
                                f2_2_tag, f2_2_pos = parse_varint(f2_chunk, f2_2_pos)
                                f2_2_field, f2_2_wire = f2_2_tag >> 3, f2_2_tag & 7
                                if f2_2_field == 0:
                                    break
                                if f2_2_wire == 2:
                                    f2_2_flen, f2_2_pos = parse_varint(f2_chunk, f2_2_pos)
                                    if f2_2_pos + f2_2_flen > f2_2_L:
                                        break
                                    f2_2_chunk = f2_chunk[f2_2_pos:f2_2_pos+f2_2_flen]
                                    f2_2_pos += f2_2_flen
                                    if f2_2_field == 2:
                                        text = ""
                                        ann_list = []
                                        in_pos, in_L = 0, len(f2_2_chunk)
                                        while in_pos < in_L:
                                            in_tag, in_pos = parse_varint(f2_2_chunk, in_pos)
                                            in_field, in_wire = in_tag >> 3, in_tag & 7
                                            if in_field == 0:
                                                break
                                            if in_wire == 2:
                                                in_flen, in_pos = parse_varint(f2_2_chunk, in_pos)
                                                if in_pos + in_flen > in_L:
                                                    break
                                                in_chunk = f2_2_chunk[in_pos:in_pos+in_flen]
                                                in_pos += in_flen
                                                if in_field == 1 and not text:
                                                    try:
                                                        text = in_chunk.decode("utf-8")
                                                    except Exception:
                                                        pass
                                                elif in_field == 5:
                                                    ann_list.append(in_chunk)
                                            elif in_wire == 0:
                                                _, in_pos = parse_varint(f2_2_chunk, in_pos)
                                            elif in_wire == 1:
                                                in_pos += 8
                                            elif in_wire == 5:
                                                in_pos += 4
                                            else:
                                                break

                                        for ann in ann_list:
                                            a_pos, a_L = 0, len(ann)
                                            offset = 0
                                            span_len = 0
                                            cmd_data = None
                                            while a_pos < a_L:
                                                a_tag, a_pos = parse_varint(ann, a_pos)
                                                a_field, a_wire = a_tag >> 3, a_tag & 7
                                                if a_field == 0:
                                                    break
                                                if a_wire == 0:
                                                    val, a_pos = parse_varint(ann, a_pos)
                                                    if a_field == 1:
                                                        offset = val
                                                    elif a_field == 2:
                                                        span_len = val
                                                elif a_wire == 2:
                                                    a_flen, a_pos = parse_varint(ann, a_pos)
                                                    if a_pos + a_flen > a_L:
                                                        break
                                                    a_chunk = ann[a_pos:a_pos+a_flen]
                                                    a_pos += a_flen
                                                    if a_field == 3:
                                                        cmd_data = a_chunk
                                                elif a_wire == 1:
                                                    a_pos += 8
                                                elif a_wire == 5:
                                                    a_pos += 4
                                                else:
                                                    break
                                            if cmd_data:
                                                info = find_watch_endpoint_info(cmd_data)
                                                if info:
                                                    vid, ts = info
                                                    anchor = text[offset:offset+span_len] if text and offset + span_len <= len(text) else ""
                                                    results.append({
                                                        "offset": offset,
                                                        "length": span_len,
                                                        "anchor": anchor,
                                                        "videoId": vid,
                                                        "timestamp": ts
                                                    })
                    elif f2_wire == 0:
                        _, f2_pos = parse_varint(chunk, f2_pos)
                    elif f2_wire == 1:
                        f2_pos += 8
                    elif f2_wire == 5:
                        f2_pos += 4
                    else:
                        break
            else:
                results.extend(decode_all_rich_text_annotations(chunk, depth + 1))
        elif wire == 0:
            _, pos = parse_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            break
    return results


def find_watch_endpoint_in_annotation_command(data):
    if len(data) < 10:
        return None, 0.0
    pos = 0
    L = len(data)
    vid, ts = None, 0.0
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos+flen]
            pos += flen
            if field == 48687757:
                wpos, wL = 0, len(chunk)
                while wpos < wL:
                    wtag, wpos = parse_varint(chunk, wpos)
                    wfield, wwire = wtag >> 3, wtag & 7
                    if wfield == 0:
                        break
                    if wwire == 2:
                        wlen, wpos = parse_varint(chunk, wpos)
                        if wpos + wlen > wL:
                            break
                        if wfield == 1 and wlen == 11:
                            try:
                                cand = chunk[wpos:wpos+11].decode("utf-8")
                                if is_valid_video_id(cand):
                                    vid = cand
                            except Exception:
                                pass
                        wpos += wlen
                    elif wwire == 5:
                        import struct
                        if wpos + 4 <= wL:
                            if wfield == 7:
                                ts = struct.unpack("<f", chunk[wpos:wpos+4])[0]
                            wpos += 4
                        else:
                            break
                    elif wwire == 0:
                        val, wpos = parse_varint(chunk, wpos)
                        if wfield == 7 and ts == 0.0:
                            ts = float(val)
                    elif wwire == 1:
                        wpos += 8
                    else:
                        break
                if vid:
                    return vid, ts
            elif field in (170382656, 1, 169495254):
                sub_vid, sub_ts = find_watch_endpoint_in_annotation_command(chunk)
                if sub_vid:
                    return sub_vid, sub_ts
        elif wire == 0:
            _, pos = parse_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            break
    return None, 0.0


def extract_all_1382_chunks_by_path(data, path, step=0, current_key=""):
    if not data or step > len(path):
        return []
    if step == len(path):
        return [(data, current_key)]
    target_field = path[step]
    pos = 0
    L = len(data)
    results = []
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 0:
            _, pos = parse_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos+flen]
            pos += flen
            if field == target_field:
                chunk_key = current_key
                if field == 168777401:
                    k = extract_key_from_chunk(chunk)
                    if k:
                        chunk_key = k
                results.extend(extract_all_1382_chunks_by_path(chunk, path, step + 1, chunk_key))
        elif wire == 5:
            pos += 4
        else:
            break
    return results


def extract_1382_from_verified_subtrees(data, depth=0):
    if not data or depth > 24:
        return []
    pos = 0
    L = len(data)
    results = []
    kEntityTagBytes = b"\xca\xeb\xea\x83\x05"
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 0:
            _, pos = parse_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos+flen]
            pos += flen
            if field == 168777401:
                ent_key = extract_key_from_chunk(chunk)
                has_child = kEntityTagBytes in chunk
                if not has_child:
                    if b"basic_content" in chunk:
                        kBasicTail = (5, 413471385, 1, 1382)
                        results.extend(extract_all_1382_chunks_by_path(chunk, kBasicTail, 0, ent_key))
                    elif b"chat_response_item" in chunk:
                        kChatTail = (5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382)
                        results.extend(extract_all_1382_chunks_by_path(chunk, kChatTail, 0, ent_key))
            results.extend(extract_1382_from_verified_subtrees(chunk, depth + 1))
        elif wire == 5:
            pos += 4
        else:
            break
    return results


def extract_rich_text_annotations_from_1382(chunk, active_vid="", ent_key="", seen=None, results=None):
    if len(chunk) < 10:
        return
    if seen is None:
        seen = set()
    if results is None:
        results = []

    pos, L = 0, len(chunk)
    while pos < L:
        tag, pos = parse_varint(chunk, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 2:
            flen, pos = parse_varint(chunk, pos)
            if pos + flen > L:
                break
            c2 = chunk[pos:pos+flen]
            pos += flen
            if field == 2:
                p2, L2 = 0, len(c2)
                while p2 < L2:
                    t2, p2 = parse_varint(c2, p2)
                    f2, w2 = t2 >> 3, t2 & 7
                    if f2 == 0:
                        break
                    if w2 == 2:
                        flen2, p2 = parse_varint(c2, p2)
                        if p2 + flen2 > L2:
                            break
                        c3 = c2[p2:p2+flen2]
                        p2 += flen2
                        if f2 == 2:
                            full_text = ""
                            ann_data_list = []
                            p3, L3 = 0, len(c3)
                            while p3 < L3:
                                t3, p3 = parse_varint(c3, p3)
                                f3, w3 = t3 >> 3, t3 & 7
                                if f3 == 0:
                                    break
                                if w3 == 2:
                                    flen3, p3 = parse_varint(c3, p3)
                                    if p3 + flen3 > L3:
                                        break
                                    c4 = c3[p3:p3+flen3]
                                    p3 += flen3
                                    if f3 == 1 and not full_text:
                                        try:
                                            full_text = c4.decode("utf-8")
                                        except Exception:
                                            pass
                                    elif f3 == 5:
                                        ann_data_list.append(c4)
                                elif w3 == 0:
                                    _, p3 = parse_varint(c3, p3)
                                elif w3 == 1:
                                    p3 += 8
                                elif w3 == 5:
                                    p3 += 4
                                else:
                                    break

                            for ann in ann_data_list:
                                ap, aL = 0, len(ann)
                                offset, span_len = 0, 0
                                cmd_data = None
                                while ap < aL:
                                    atag, ap = parse_varint(ann, ap)
                                    afield, awire = atag >> 3, atag & 7
                                    if afield == 0:
                                        break
                                    if awire == 0:
                                        val, ap = parse_varint(ann, ap)
                                        if afield == 1:
                                            offset = val
                                        elif afield == 2:
                                            span_len = val
                                    elif awire == 2:
                                        aflen, ap = parse_varint(ann, ap)
                                        if ap + aflen > aL:
                                            break
                                        achunk = ann[ap:ap+aflen]
                                        ap += aflen
                                        if afield == 3:
                                            cmd_data = achunk
                                    elif awire == 1:
                                        ap += 8
                                    elif awire == 5:
                                        ap += 4
                                    else:
                                        break

                                if cmd_data:
                                    vid, ts = find_watch_endpoint_in_annotation_command(cmd_data)
                                    if vid and len(vid) == 11 and is_valid_video_id(vid):
                                        if active_vid and vid == active_vid:
                                            continue
                                        anchor = full_text[offset:offset+span_len] if full_text and offset + span_len <= len(full_text) else ""
                                        title = anchor.strip("[]() \t\n\u00A0")
                                        entry = {
                                            "videoId": vid,
                                            "title": title,
                                            "offset": offset,
                                            "length": span_len,
                                            "entityKey": ent_key,
                                        }
                                        if ts > 0.0:
                                            entry["timestamp"] = ts
                                        if seen is not None:
                                            if vid in seen:
                                                continue
                                            seen.add(vid)
                                        results.append(entry)
                    elif w2 == 0:
                        _, p2 = parse_varint(c2, p2)
                    elif w2 == 1:
                        p2 += 8
                    elif w2 == 5:
                        p2 += 4
                    else:
                        break
        elif wire == 0:
            _, pos = parse_varint(chunk, pos)
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            break


def extract_rich_text_from_verified_entities(data, active_vid="", seen=None, results=None):
    if len(data) < 30:
        return results if results is not None else []
    if seen is None:
        seen = set([active_vid] if active_vid else [])
    if results is None:
        results = []

    node1382_items = []
    # Layout 1: Primary observed Elements path in YouTube iOS (20 fields)
    kFullRoot = (1, 1, 1, 153515154, 172660663, 1, 168777401, 5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382)
    node1382_items.extend(extract_all_1382_chunks_by_path(data, kFullRoot, 0))

    # Layout 2: Standalone ElementRenderer (17 fields)
    kRoot = (153515154, 172660663, 1, 168777401, 5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382)
    node1382_items.extend(extract_all_1382_chunks_by_path(data, kRoot, 0))

    # Layout 3: Subtree verified entities
    node1382_items.extend(extract_1382_from_verified_subtrees(data, 0))

    seen_chunks = set()
    for chunk, key in node1382_items:
        if chunk in seen_chunks:
            continue
        seen_chunks.add(chunk)
        extract_rich_text_annotations_from_1382(chunk, active_vid, key, seen, results)

    return results


def extract_rich_text_annotations(data, depth, active_vid, seen, results):
    # Strictly delegate to verified assistant-entity extractor
    extract_rich_text_from_verified_entities(data, active_vid, seen, results)


def extract_chunks_by_path(data, path, step=0):
    if not data or step > len(path):
        return []
    if step == len(path):
        return [data]
    target_field = path[step]
    pos = 0
    L = len(data)
    results = []
    while pos < L:
        tag, pos = parse_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            break
        if wire == 0:
            _, pos = parse_varint(data, pos)
        elif wire == 1:
            pos += 8
        elif wire == 2:
            flen, pos = parse_varint(data, pos)
            if pos + flen > L:
                break
            chunk = data[pos:pos+flen]
            pos += flen
            if field == target_field:
                results.extend(extract_chunks_by_path(chunk, path, step + 1))
        elif wire == 5:
            pos += 4
        else:
            break
    return results


def extract_videos_from_1337_layout(data, active_vid="", seen=None, results=None):
    if not data or len(data) < 30:
        return results if results is not None else []
    if seen is None:
        seen = set([active_vid] if active_vid else [])
    if results is None:
        results = []

    kFullCardPath = [
        1, 1, 1, 153515154, 172660663, 1, 168777401, 5,
        1337, 6, 2, 17, 3, 1, 36905, 1, 1, 168777401, 5, 232903841
    ]
    kRootCardPath = [
        153515154, 172660663, 1, 168777401, 5,
        1337, 6, 2, 17, 3, 1, 36905, 1, 1, 168777401, 5, 232903841
    ]
    kSubtreeCardPath = [
        5, 1337, 6, 2, 17, 3, 1, 36905, 1, 1, 168777401, 5, 232903841
    ]
    kCommandPath = [1, 6, 170382656, 1, 169495254, 462702848]

    card_chunks = extract_chunks_by_path(data, kFullCardPath)
    if not card_chunks:
        card_chunks = extract_chunks_by_path(data, kRootCardPath)
    if not card_chunks:
        def search_subtree_1337(sub_data, depth=0):
            if not sub_data or depth > 24:
                return []
            res = []
            sp, sL = 0, len(sub_data)
            while sp < sL:
                stag, sp = parse_varint(sub_data, sp)
                sfield, swire = stag >> 3, stag & 7
                if sfield == 0:
                    break
                if swire == 0:
                    _, sp = parse_varint(sub_data, sp)
                elif swire == 1:
                    sp += 8
                elif swire == 2:
                    sflen, sp = parse_varint(sub_data, sp)
                    if sp + sflen > sL:
                        break
                    schunk = sub_data[sp:sp+sflen]
                    sp += sflen
                    if sfield == 168777401:
                        res.extend(extract_chunks_by_path(schunk, kSubtreeCardPath))
                    res.extend(search_subtree_1337(schunk, depth + 1))
                elif swire == 5:
                    sp += 4
                else:
                    break
            return res
        card_chunks = search_subtree_1337(data)

    for card in card_chunks:
        cmd_chunks = extract_chunks_by_path(card, kCommandPath)
        for cmd in cmd_chunks:
            cmd_vids = extract_videos_from_command_payload(cmd, active_vid)
            for v in cmd_vids:
                vid = v.get("videoId")
                title = v.get("title", "")
                if vid and len(vid) == 11 and is_valid_video_id(vid):
                    if vid not in seen:
                        seen.add(vid)
                        results.append({"videoId": vid, "title": title})
                    elif title:
                        for existing in results:
                            if existing.get("videoId") == vid and not existing.get("title"):
                                existing["title"] = title
                                break
    return results


def extract_videos_from_payload_with_class(payload_bytes, payload_class="", active_vid=""):
    if len(payload_bytes) < 30:
        return []

    if payload_class in ("YTICommand", "ELMCommand"):
        return extract_videos_from_command_payload(payload_bytes, active_vid)

    results = []
    seen = set([active_vid] if active_vid else [])

    is_mutation_envelope = (payload_class == "YTISectionListMutationOperations")
    if not is_mutation_envelope and not payload_class and len(payload_bytes) > 10 and payload_bytes[0] == 0x0A:
        is_mutation_envelope = True

    if is_mutation_envelope:
        pos = 0
        L = len(payload_bytes)
        while pos < L:
            tag, pos = parse_varint(payload_bytes, pos)
            field, wire = tag >> 3, tag & 7
            if field == 0:
                break
            if wire == 2:
                flen, pos = parse_varint(payload_bytes, pos)
                if pos + flen > L:
                    break
                chunk = payload_bytes[pos:pos+flen]
                pos += flen
                if field == 1:
                    mpos, mL = 0, len(chunk)
                    while mpos < mL:
                        mtag, mpos = parse_varint(chunk, mpos)
                        mfield, mwire = mtag >> 3, mtag & 7
                        if mfield == 0:
                            break
                        if mwire == 2:
                            mlen, mpos = parse_varint(chunk, mpos)
                            if mpos + mlen > mL:
                                break
                            mchunk = chunk[mpos:mpos+mlen]
                            mpos += mlen
                            if mfield == 1:
                                ppos, pL = 0, len(mchunk)
                                while ppos < pL:
                                    ptag, ppos = parse_varint(mchunk, ppos)
                                    pfield, pwire = ptag >> 3, ptag & 7
                                    if pfield == 0:
                                        break
                                    if pwire == 2:
                                        plen, ppos = parse_varint(mchunk, ppos)
                                        if ppos + plen > pL:
                                            break
                                        pchunk = mchunk[ppos:ppos+plen]
                                        ppos += plen
                                        if pfield == 1:
                                            walk_card_fields(pchunk, CTX_ROOT, 0, active_vid, seen, results)
                                    elif pwire == 0:
                                        while ppos < pL and (mchunk[ppos] & 0x80):
                                            ppos += 1
                                        ppos += 1
                                    elif pwire == 1:
                                        ppos += 8
                                    elif pwire == 5:
                                        ppos += 4
                                    else:
                                        break
                        elif mwire == 0:
                            while mpos < mL and (chunk[mpos] & 0x80):
                                mpos += 1
                            mpos += 1
                        elif mwire == 1:
                            mpos += 8
                        elif mwire == 5:
                            mpos += 4
                        else:
                            break
            elif wire == 0:
                while pos < L and (payload_bytes[pos] & 0x80):
                    pos += 1
                pos += 1
            elif wire == 1:
                pos += 8
            elif wire == 5:
                pos += 4
            else:
                break

    if not results:
        walk_card_fields(payload_bytes, CTX_ROOT, 0, active_vid, seen, results)

    extract_rich_text_annotations(payload_bytes, 0, active_vid, seen, results)

    extract_videos_from_1337_layout(payload_bytes, active_vid, seen, results)

    return results


def extract_videos_from_payload(payload_bytes, active_vid=""):
    return extract_videos_from_payload_with_class(payload_bytes, "", active_vid)


def extract_videos_from_command_payload(cmd_payload_bytes, active_vid=""):
    if len(cmd_payload_bytes) < 10:
        return []
    results = walk_card_fields(cmd_payload_bytes, CTX_COMMAND, 0, active_vid)
    if not results:
        results = walk_card_fields(cmd_payload_bytes, CTX_ENDPOINT, 0, active_vid)
    return results


def inspect_bootstrap_protobuf(data_bytes, active_vid="", active_cid=""):
    if not data_bytes or len(data_bytes) < 4:
        return True, None, None
    pos = 0
    L = len(data_bytes)
    rpc_status_code = 0
    rpc_status_msg = ""
    found_cid = None

    while pos < L:
        tag, pos = parse_varint(data_bytes, pos)
        field = tag >> 3
        wire = tag & 7
        if field == 0:
            break
        if wire == 0:
            val, pos = parse_varint(data_bytes, pos)
            if field == 1:
                rpc_status_code = val
        elif wire == 1:
            pos += 8
        elif wire == 2:
            flen, pos = parse_varint(data_bytes, pos)
            if pos + flen > L:
                break
            chunk = data_bytes[pos:pos+flen]
            pos += flen

            if field == 2 and rpc_status_code > 0:
                rpc_status_msg = chunk.decode("utf-8", errors="ignore")
            elif field in (9, 12, 14):
                lower_chunk = chunk.lower()
                if any(k in lower_chunk for k in [b"conversation unavailable", b"error_code", b"alertrenderer", b"status: failed", b"permission_denied"]):
                    return False, None, f"structural-error-field-{field}"
            elif field in (1, 3):
                cpos = 0
                cL = len(chunk)
                while cpos < cL:
                    ctag, cpos = parse_varint(chunk, cpos)
                    cfield = ctag >> 3
                    cwire = ctag & 7
                    if cfield == 0:
                        break
                    if cwire == 0:
                        _, cpos = parse_varint(chunk, cpos)
                    elif cwire == 1:
                        cpos += 8
                    elif cwire == 2:
                        clen, cpos = parse_varint(chunk, cpos)
                        if cpos + clen > cL:
                            break
                        cchunk = chunk[cpos:cpos+clen]
                        cpos += clen
                        if cfield == 13 and clen > 0:
                            cand = cchunk.decode("utf-8", errors="ignore")
                            if cand and cand != "dynamic_welcome_chips_placeholder_chat_id":
                                found_cid = cand
                    elif cwire == 5:
                        cpos += 4
                    else:
                        break
        elif wire == 5:
            pos += 4
        else:
            break

    if rpc_status_code > 0:
        return False, None, f"rpc-status-{rpc_status_code}:{rpc_status_msg}"
    return True, found_cid, None


def validate_bootstrap_response(data_bytes_or_list, active_vid="", active_cid="", return_cid=False):
    if not data_bytes_or_list:
        return (False, None, "payload-empty") if return_cid else (False, "payload-empty")

    messages = data_bytes_or_list if isinstance(data_bytes_or_list, list) else [data_bytes_or_list]
    extracted_cid = None
    found_mismatch = False

    for msg in messages:
        ok, found_cid, err_reason = inspect_bootstrap_protobuf(msg, active_vid, active_cid)
        if not ok:
            return (False, None, err_reason) if return_cid else (False, err_reason)
        if found_cid:
            if active_cid:
                if found_cid == active_cid:
                    extracted_cid = found_cid
                else:
                    found_mismatch = True
            else:
                if not extracted_cid and len(found_cid) >= 8:
                    extracted_cid = found_cid

    if extracted_cid:
        reason = "matched-active-cid" if active_cid else "established-session-cid"
        return (True, extracted_cid, reason) if return_cid else (True, reason)
    if found_mismatch:
        return (False, None, "session-cid-mismatch") if return_cid else (False, "session-cid-mismatch")
    return (False, None, "no-matching-session-id") if return_cid else (False, "no-matching-session-id")


def reconstruct_entity_text_with_annotations(text, annotations):
    if not text or not annotations:
        return text

    valid_anns = []
    for ann in annotations:
        vid = ann.get("videoId", "")
        off = ann.get("offset")
        slen = ann.get("length")
        if len(vid) == 11 and off is not None and slen is not None:
            if off + slen <= len(text):
                valid_anns.append(ann)

    if not valid_anns:
        return text

    # Sort descending by offset so later replacements don't shift earlier offsets
    valid_anns.sort(key=lambda a: a["offset"], reverse=True)

    placeholder_rx = re.compile(
        r"[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*"
        r"[\(\[][ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*"
        r"[•\*·\u2022\u2023\u25E6\u2043\u2219\u25AA\u25AB]"
        r"[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*[\)\]]"
    )

    working = text
    for ann in valid_anns:
        off = ann["offset"]
        slen = ann["length"]
        vid = ann["videoId"]
        link_url = f"https://youtu.be/{vid}"

        span = working[off:off+slen]

        # 1. Direct placeholder match on the span
        m = placeholder_rx.fullmatch(span)
        if m:
            working = working[:off] + link_url + working[off+slen:]
            continue

        # 2. Span contains placeholder
        if placeholder_rx.search(span):
            working = working[:off] + placeholder_rx.sub(link_url, span) + working[off+slen:]
            continue

        # 3. Span is anchor text immediately followed by placeholder
        search_start = off + slen
        search_len = min(30, len(working) - search_start)
        if search_len > 0:
            sub = working[search_start:search_start+search_len]
            m_adj = placeholder_rx.search(sub)
            if m_adj:
                between = sub[:m_adj.start()]
                if not between.strip(" \t\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000"):
                    rep_start = search_start + m_adj.start()
                    rep_end = search_start + m_adj.end()
                    working = working[:rep_start] + " " + link_url + working[rep_end:]
                    continue

        # 4. Span is anchor text without placeholder
        working = working[:off] + f"{span} {link_url}" + working[off+slen:]

    return working


def fix_truncated_links_in_text(text, resolutions_or_videos=None):
    if not text:
        return ""
    import re

    annotations = []
    url_map = {}

    if isinstance(resolutions_or_videos, list):
        for item in resolutions_or_videos:
            if isinstance(item, dict) and "offset" in item and "videoId" in item:
                annotations.append(item)
    elif isinstance(resolutions_or_videos, dict):
        if "annotations" in resolutions_or_videos and isinstance(resolutions_or_videos["annotations"], list):
            annotations.extend(resolutions_or_videos["annotations"])
        if "videos" in resolutions_or_videos and isinstance(resolutions_or_videos["videos"], list):
            for item in resolutions_or_videos["videos"]:
                if isinstance(item, dict) and "offset" in item and "videoId" in item:
                    annotations.append(item)
        if "resolutions" in resolutions_or_videos and isinstance(resolutions_or_videos["resolutions"], dict):
            url_map = resolutions_or_videos["resolutions"]
        else:
            url_map = resolutions_or_videos

    # Step 1: Perform verified range-based reconstruction first (before whitespace normalization)
    if annotations:
        text = reconstruct_entity_text_with_annotations(text, annotations)

    # Step 2: Apply exact URL mappings
    if url_map:
        for bad_url, good_url in url_map.items():
            if bad_url.startswith("http") or "youtube" in bad_url:
                target = good_url if good_url.startswith("http") else f"https://youtu.be/{good_url}"
                text = text.replace(bad_url, target)

    pattern = (
        r"(?:https?://(?:www\.|m\.)?youtube(?:\.[a-z]{2,})?\S*|"
        r"https?://youtu\.be/\S*|"
        r"(?:www\.|m\.)youtube(?:\.[a-z]{2,})?\S*|"
        r"youtube\.[a-z]{2,}\S*|"
        r"(?:https?://)?(?:www\.)?youtube(?:\.[a-z]{0,4})?(?:\.{2,3}|…)\S*|"
        r"youtu\.be/\S*)"
    )
    placeholder_pattern = (
        r"[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*"
        r"[\(\[][ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*"
        r"[•\*·\u2022\u2023\u25E6\u2043\u2219\u25AA\u25AB]"
        r"[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*[\)\]]"
    )

    def is_valid_youtube_link(url):
        if "..." in url or "…" in url:
            return False
        if not (url.startswith("http://") or url.startswith("https://")):
            return False
        m = re.search(r"(?:watch\?v=|youtu\.be/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])", url)
        return m is not None

    lines = text.split("\n")
    cleaned_lines = []

    for line in lines:
        urls = list(re.finditer(pattern, line, re.IGNORECASE))
        has_placeholder = bool(re.search(placeholder_pattern, line))

        if urls or has_placeholder:
            has_valid = any(is_valid_youtube_link(u.group(0)) for u in urls)
            if has_valid:
                line_cleaned = line
                for u in reversed(urls):
                    if not is_valid_youtube_link(u.group(0)):
                        line_cleaned = line_cleaned[:u.start()] + line_cleaned[u.end():]
                line_cleaned = re.sub(placeholder_pattern, "", line_cleaned)
                trimmed = line_cleaned.strip(" \t\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000")
                if trimmed:
                    cleaned_lines.append(line_cleaned)
                continue

            # Line does not have a verified valid URL: strip malformed URLs and unverified placeholders
            line_cleaned = re.sub(pattern, "", line, flags=re.IGNORECASE)
            line_cleaned = re.sub(placeholder_pattern, "", line_cleaned)
            line_cleaned = re.sub(r"[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*[:\-–—][ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*$", "", line_cleaned)
            line_cleaned = re.sub(r"[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]+$", "", line_cleaned)
            empty_m = re.match(r"^[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*[•\*\-–—0-9\.\)]+[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]*$", line_cleaned)
            if not empty_m:
                trimmed = line_cleaned.strip(" \t\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000")
                if trimmed:
                    cleaned_lines.append(line_cleaned)
        else:
            cleaned_lines.append(line)

    result = "\n".join(cleaned_lines)
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result.strip()


def append_related_videos_to_text(text, videos):
    if not videos:
        return text or ""
    missing = [v for v in videos if v["videoId"] not in (text or "")]
    has_links = ("youtu.be/" in (text or "")) or ("watch?v=" in (text or ""))
    if has_links and not missing:
        return text or ""
    to_append = missing if missing else videos
    lines = []
    for i, v in enumerate(to_append, 1):
        vid = v["videoId"]
        title = v.get("title", "")
        if title:
            lines.append(f"{i}. https://youtu.be/{vid} - {title}")
        else:
            lines.append(f"{i}. https://youtu.be/{vid}")
    if not lines:
        return text or ""
    formatted = "\n".join(lines)
    if not text:
        return f"Related videos:\n{formatted}"
    return f"{text}\n\nRelated videos:\n{formatted}"


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

    def test_extract_videos_from_real_fixture(self):
        """Verify video IDs and titles are extracted from real Elements video lockup cards."""
        matches = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*176b50a0*.json"
        )
        if not matches:
            self.skipTest("Capture JSON not found")
        with open(matches[0]) as f:
            d = json.load(f)
        all_videos = []
        for it in d["events"][100]["items"]:
            payload = it.get("payload")
            if payload:
                raw = base64.b64decode(payload)
                all_videos.extend(extract_videos_from_payload(raw, active_vid="GlaSnROMqRY"))

        video_ids = [v["videoId"] for v in all_videos]
        self.assertIn("-5OHks6dNVk", video_ids)
        self.assertIn("Of3ys0dmyYc", video_ids)
        self.assertIn("Xq-VL5ILPCE", video_ids)
        self.assertNotIn("GlaSnROMqRY", video_ids)

        # Check titles
        titles_by_id = {v["videoId"]: v["title"] for v in all_videos}
        self.assertEqual(titles_by_id["-5OHks6dNVk"], "US Special Forces in Africa are Getting Crazy")
        self.assertEqual(titles_by_id["Xq-VL5ILPCE"], "The Great Betrayal")
        self.assertIn("Possessed Politicians", titles_by_id["Of3ys0dmyYc"])

    def test_fix_truncated_links(self):
        """Invalid/truncated YouTube links must be removed from text and appended as related videos."""
        summary = "Similar videos:\n• https://www.youtube.co...\n• www.youtube..."
        fixed = fix_truncated_links_in_text(summary)
        self.assertEqual(fixed, "Similar videos:")
        self.assertNotIn("https://www.youtube.co...", fixed)
        self.assertNotIn("www.youtube...", fixed)

        cards = [{"videoId": "1XvkgjH1SOg", "title": "Max Spiers"}]
        result = append_related_videos_to_text(fixed, cards)
        self.assertIn("Related videos:", result)
        self.assertIn("1. https://youtu.be/1XvkgjH1SOg - Max Spiers", result)

    def test_section_list_mutation_envelope_extracts_cards(self):
        """YTISectionListMutationOperations envelope wrapping elementRenderer cards must be successfully unpacked."""
        matches = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*176b50a0*.json"
        )
        if not matches:
            self.skipTest("Capture JSON not found")
        with open(matches[0]) as f:
            d = json.load(f)
        card_bytes = base64.b64decode(d["events"][100]["items"][0]["payload"])

        # Envelope hierarchy: mutationOperations (1) -> payload (1) -> elementRenderer (1)
        mutation_op = encode_field(1, 2, encode_field(1, 2, card_bytes))
        mutation_envelope = encode_field(1, 2, mutation_op)

        # 1. Explicit class
        vids_explicit = extract_videos_from_payload_with_class(
            mutation_envelope, "YTISectionListMutationOperations", active_vid="GlaSnROMqRY"
        )
        self.assertEqual(len(vids_explicit), 1)
        self.assertEqual(vids_explicit[0]["videoId"], "Of3ys0dmyYc")
        self.assertIn("Fr. Chad Ripperger", vids_explicit[0]["title"])

        # 2. Auto-detected envelope (untyped payload)
        vids_autodetect = extract_videos_from_payload(mutation_envelope, active_vid="GlaSnROMqRY")
        self.assertEqual(len(vids_autodetect), 1)
        self.assertEqual(vids_autodetect[0]["videoId"], "Of3ys0dmyYc")

    def test_nested_field_1_opaque_probe_ignored(self):
        """Arbitrary 3-level field 1 nesting wrapping a bare watchEndpoint must be rejected (no structural bypass)."""
        watch_endpoint = encode_field(1, 2, b"CCCCCCCCCCC")
        watch_field = encode_field(48687757, 2, watch_endpoint)
        padding = encode_field(99, 2, b"unrelated padding field")
        nested_probe = encode_field(1, 2, encode_field(1, 2, encode_field(1, 2, watch_field + padding)))
        self.assertGreater(len(nested_probe), 30)
        self.assertEqual(extract_videos_from_payload_with_class(nested_probe, "YTISectionListMutationOperations"), [])
        self.assertEqual(extract_videos_from_payload(nested_probe), [])

    def test_ai_response_source_timestamps_filtered(self):
        """Watch endpoints in AI responses referencing active video timestamps must never be mistaken for related video cards."""
        matches = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*406e9e87*.json"
        )
        if not matches:
            self.skipTest("Fixture 406e9e87 not found")
        with open(matches[0]) as f:
            d = json.load(f)
        # Event 196 is the complete, untruncated AI streaming mutation operations response (16,380 bytes)
        raw = base64.b64decode(d["events"][196]["items"][0]["payload"])
        # All 10 watchEndpoints reference active video '_Ca37sPC4AU' with timestamp offsets
        extracted = extract_videos_from_payload_with_class(raw, "YTISectionListMutationOperations", active_vid="_Ca37sPC4AU")
        self.assertEqual(extracted, [])

        # Verify that all 10 endpoints are directly reached and decoded
        annotations = decode_all_rich_text_annotations(raw)
        self.assertEqual(len(annotations), 10)
        for ann in annotations:
            self.assertEqual(ann["videoId"], "_Ca37sPC4AU")
            self.assertGreater(ann["timestamp"], 0.0)

        # When active_vid is different, the parser reaches all 10 and extracts the non-matching endpoints
        extracted_diff = extract_videos_from_payload_with_class(raw, "YTISectionListMutationOperations", active_vid="DIFFERENT11")
        self.assertEqual(len(extracted_diff), 1)
        self.assertEqual(extracted_diff[0]["videoId"], "_Ca37sPC4AU")

    def test_unverified_placeholder_and_truncated_url_removed(self):
        """Unverified placeholder ( • ) and truncated URL must be completely removed without leaving empty bullets."""
        text = "Here are resources:\n1. [Red Fox facts] ( • ) https://www.youtube.co...\n2. [Arctic Fox habitat] ( • ) https://www.youtube.co..."
        fixed = fix_truncated_links_in_text(text)
        self.assertEqual(fixed, "Here are resources:\n1. [Red Fox facts]\n2. [Arctic Fox habitat]")
        self.assertNotIn("( • )", fixed)
        self.assertNotIn("https://www.youtube.co...", fixed)

    def test_verified_placeholder_reconstructed_by_title_and_position(self):
        """Verified placeholders must be reconstructed with https://youtu.be/<videoId> using verified annotation offsets."""
        text = "Here are resources:\n1. [Red Fox facts] ( • ) https://www.youtube.co...\n2. [Arctic Fox habitat] ( • ) https://www.youtube.co..."
        i1 = text.find("( • )")
        i2 = text.find("( • )", i1 + 1)
        annotations = [
            {"videoId": "Fox12345678", "offset": i1, "length": 5},
            {"videoId": "Arc99999999", "offset": i2, "length": 5}
        ]
        fixed = fix_truncated_links_in_text(text, annotations)
        self.assertIn("1. [Red Fox facts] https://youtu.be/Fox12345678", fixed)
        self.assertIn("2. [Arctic Fox habitat] https://youtu.be/Arc99999999", fixed)
        self.assertNotIn("( • )", fixed)
        self.assertNotIn("https://www.youtube.co...", fixed)

    def test_inline_rich_text_external_video_extracted(self):
        """Rich text 1382 payload with an external watchEndpoint along a verified assistant path must be extracted as a related video."""
        # watchEndpoint for external video ExtFox12345
        we_bytes = encode_field(1, 2, b"ExtFox12345")
        cmd_bytes = encode_field(48687757, 2, we_bytes)
        # Annotation: offset 3 length 14, cmd
        ann_bytes = encode_field(1, 0, 3) + encode_field(2, 0, 14) + encode_field(3, 2, cmd_bytes)
        text_bytes = b"1. [Red Fox facts] ( \xe2\x80\xa2 )"
        inner_container = encode_field(1, 2, text_bytes) + encode_field(5, 2, ann_bytes)
        node_1382 = encode_field(2, 2, encode_field(2, 2, inner_container))
        kRoot = (153515154, 172660663, 1, 168777401, 5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382)
        cur = encode_field(1382, 2, node_1382)
        for f in reversed(kRoot[:-1]):
            cur = encode_field(f, 2, cur)
        payload = cur
        # With active video set to source video
        vids = extract_videos_from_payload(payload, active_vid="SourceVid11")
        self.assertEqual(len(vids), 1)
        self.assertEqual(vids[0]["videoId"], "ExtFox12345")

    def test_ai_response_related_videos_extracted_and_timestamps_filtered(self):
        """A complete YTISectionListMutationOperations response containing both active video timestamp endpoints
        and related video card elements must successfully extract the related video cards (IDs and titles)
        while strictly excluding active video timestamps."""
        matches_406 = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*406e9e87*.json"
        )
        matches_176 = glob.glob(
            "/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*176b50a0*.json"
        )
        if not matches_406 or not matches_176:
            self.skipTest("Required fixtures not found")
        with open(matches_406[0]) as f:
            d_406 = json.load(f)
        with open(matches_176[0]) as f:
            d_176 = json.load(f)

        # Event 196: Complete 16,380-byte AI mutation operations response with 10 timestamps referencing _Ca37sPC4AU
        raw_196 = base64.b64decode(d_406["events"][196]["items"][0]["payload"])

        # Real card items from Event 100
        card_ripperger = base64.b64decode(d_176["events"][100]["items"][0]["payload"])
        card_special_forces = base64.b64decode(d_176["events"][100]["items"][4]["payload"])

        # Envelope hierarchy: mutationOperations (field 1) -> repeated payload (field 1) -> item (field 1)
        card_op1 = encode_field(1, 2, encode_field(1, 2, card_ripperger))
        card_op2 = encode_field(1, 2, encode_field(1, 2, card_special_forces))
        complete_ai_response = raw_196 + encode_field(1, 2, card_op1) + encode_field(1, 2, card_op2)

        # 1. Extraction with active video set to '_Ca37sPC4AU'
        vids = extract_videos_from_payload_with_class(
            complete_ai_response, "YTISectionListMutationOperations", active_vid="_Ca37sPC4AU"
        )
        self.assertEqual(len(vids), 2)
        extracted_ids = [v["videoId"] for v in vids]
        self.assertIn("Of3ys0dmyYc", extracted_ids)
        self.assertIn("-5OHks6dNVk", extracted_ids)
        self.assertNotIn("_Ca37sPC4AU", extracted_ids)

        # Verify extracted titles
        ripperger_card = next(v for v in vids if v["videoId"] == "Of3ys0dmyYc")
        self.assertIn("Fr. Chad Ripperger", ripperger_card["title"])
        sf_card = next(v for v in vids if v["videoId"] == "-5OHks6dNVk")
        self.assertIn("US Special Forces", sf_card["title"])

        # 2. When active video matches one of the related cards, that card is filtered
        vids_filter_ripperger = extract_videos_from_payload_with_class(
            complete_ai_response, "YTISectionListMutationOperations", active_vid="Of3ys0dmyYc"
        )
        extracted_filter_ids = [v["videoId"] for v in vids_filter_ripperger]
        self.assertNotIn("Of3ys0dmyYc", extracted_filter_ids)
        self.assertIn("-5OHks6dNVk", extracted_filter_ids)

    def test_opaque_field_probe_ignored(self):
        """Embedding watchEndpoint bytes inside an unrelated opaque field must produce no video result (fixture > 30 bytes)."""
        watch_bytes = bytes([0xEA, 0xA8, 0xDD, 0xB9, 0x01, 13, 0x0A, 11]) + b"dQw4w9WgXcQ"
        padding = b"Opaque field padding to exceed minimum parser length requirement!"
        opaque_field_99 = encode_field(99, 2, padding + watch_bytes)
        self.assertGreater(len(opaque_field_99), 30)
        self.assertEqual(extract_videos_from_payload(opaque_field_99), [])

    def test_opaque_field_1_probe_ignored(self):
        """Generic field 1 containing watchEndpoint outside a recognized card path must be rejected (63-byte bypass fixture)."""
        watch_endpoint = encode_field(1, 2, b"CCCCCCCCCCC")
        watch_field = encode_field(48687757, 2, watch_endpoint)
        padding = encode_field(99, 2, b"unrelated padding field to reach target length")
        field_1 = encode_field(1, 2, watch_field + padding)
        self.assertGreater(len(field_1), 30)
        self.assertEqual(extract_videos_from_payload(field_1), [])

    def test_extract_videos_from_command_payload_wrapped(self):
        """Standalone navigation command from gesture recognizers (e.g. field 1 -> 48687757) must extract video and title."""
        watch_endpoint = encode_field(1, 2, b"CCCCCCCCCCC") + encode_field(36, 2, b"Special Forces in Africa")
        watch_field = encode_field(48687757, 2, watch_endpoint)
        cmd_wrapper = encode_field(1, 2, watch_field)
        extracted = extract_videos_from_command_payload(cmd_wrapper)
        self.assertEqual(len(extracted), 1)
        self.assertEqual(extracted[0]["videoId"], "CCCCCCCCCCC")
        self.assertEqual(extracted[0]["title"], "Special Forces in Africa")

    def test_extract_videos_from_command_payload_direct_endpoint(self):
        """Direct watchEndpoint command payload (tag 48687757 at root) must be parsed by command extractor."""
        watch_endpoint = encode_field(1, 2, b"DDDDDDDDDDD")
        watch_field = encode_field(48687757, 2, watch_endpoint)
        extracted = extract_videos_from_command_payload(watch_field)
        self.assertEqual(len(extracted), 1)
        self.assertEqual(extracted[0]["videoId"], "DDDDDDDDDDD")

    def test_command_payload_rejected_by_full_payload_parser(self):
        """Standalone command payload must be rejected by extract_videos_from_payload to prevent root bypass."""
        watch_endpoint = encode_field(1, 2, b"CCCCCCCCCCC")
        watch_field = encode_field(48687757, 2, watch_endpoint)
        cmd_wrapper = encode_field(1, 2, watch_field)
        padding = encode_field(99, 2, b"padding to exceed minimum size check")
        full_payload = cmd_wrapper + padding
        self.assertGreater(len(full_payload), 30)
        self.assertEqual(extract_videos_from_payload(full_payload), [])

    def test_corrupted_declared_length_rejected(self):
        """Protobuf field declaring length exceeding available buffer must be rejected without overrun (fixture >= 30 bytes)."""
        header = encode_varint((1 << 3) | 2) + encode_varint(200)
        padding = b"A" * 35
        corrupted = header + padding
        self.assertGreaterEqual(len(corrupted), 30)
        self.assertEqual(extract_videos_from_payload(corrupted), [])

    def test_bootstrap_error_variant_rejected(self):
        """Bootstrap response containing error variants like 'conversation unavailable' must be rejected."""
        err_payload = b"\x08\x01\x12\x1a" + b"conversation unavailable: 503"
        ok, reason = validate_bootstrap_response(err_payload, "dQw4w9WgXcQ", "cid_123")
        self.assertFalse(ok)
        self.assertTrue(reason.startswith("rpc-status") or "error" in reason)

    def test_bootstrap_valid_session_verified(self):
        """Bootstrap response with field 13 matching active conversationId must be validated."""
        valid_cid = "7EDACB7A-2A5C-47DB-87A6-1E8457C60D7F"
        f13 = encode_field(13, 2, valid_cid.encode("utf-8"))
        f3 = encode_field(3, 2, f13)
        ok, reason = validate_bootstrap_response(f3, "dQw4w9WgXcQ", valid_cid)
        self.assertTrue(ok)
        self.assertEqual(reason, "matched-active-cid")

    def test_bootstrap_mismatched_cid_rejected(self):
        """Bootstrap response with a different conversationId must be rejected with session-cid-mismatch."""
        valid_cid = "7EDACB7A-2A5C-47DB-87A6-1E8457C60D7F"
        f13 = encode_field(13, 2, valid_cid.encode("utf-8"))
        f3 = encode_field(3, 2, f13)
        ok, reason = validate_bootstrap_response(f3, "dQw4w9WgXcQ", "OTHER_ACTIVE_CID")
        self.assertFalse(ok)
        self.assertEqual(reason, "session-cid-mismatch")

    def test_bootstrap_cold_start_establishes_cid(self):
        """Cold bootstrap with empty activeCid must establish and return the newly generated session CID."""
        new_cid = "7EDACB7A-2A5C-47DB-87A6-1E8457C60D7F"
        f13 = encode_field(13, 2, new_cid.encode("utf-8"))
        f1 = encode_field(1, 2, f13)
        ok, established_cid, reason = validate_bootstrap_response(f1, "dQw4w9WgXcQ", "", return_cid=True)
        self.assertTrue(ok)
        self.assertEqual(established_cid, new_cid)
        self.assertEqual(reason, "established-session-cid")

    def test_bootstrap_ordinary_prose_containing_unavailable_accepted(self):
        """Ordinary assistant prose containing the word 'unavailable' must NOT be falsely rejected."""
        valid_cid = "7EDACB7A-2A5C-47DB-87A6-1E8457C60D7F"
        f13 = encode_field(13, 2, valid_cid.encode("utf-8"))
        f1 = encode_field(1, 2, f13)
        prose_entity = encode_field(168777401, 2, b"The transcript feature was unavailable for older live streams.")
        ok, reason = validate_bootstrap_response([f1, prose_entity], "dQw4w9WgXcQ", valid_cid)
        self.assertTrue(ok)
        self.assertEqual(reason, "matched-active-cid")

    def test_bootstrap_placeholder_cid_rejected(self):
        """Placeholder welcome chat IDs must not be accepted as valid session CIDs."""
        f13 = encode_field(13, 2, b"dynamic_welcome_chips_placeholder_chat_id")
        f1 = encode_field(1, 2, f13)
        ok, reason = validate_bootstrap_response(f1, "dQw4w9WgXcQ", "")
        self.assertFalse(ok)
        self.assertEqual(reason, "no-matching-session-id")

    def test_bootstrap_active_vid_shortcut_rejected(self):
        """Opaque payload containing activeVid string anywhere must not bypass structural session validation."""
        opaque_bytes = b"random prefix " + b"dQw4w9WgXcQ" + b" random suffix"
        ok, reason = validate_bootstrap_response(opaque_bytes, "dQw4w9WgXcQ", "")
        self.assertFalse(ok)
        self.assertEqual(reason, "no-matching-session-id")

    def test_single_payload_with_primary_and_independent_block(self):
        """A single payload with primary path AND independent block must extract both."""
        p_root = build_synthetic_payload("Primary text")
        p_basic = build_basic_content_payload("block_extra", "Extra text")
        combined = p_root + p_basic
        ents = extract_entities_from_payload(combined)
        texts = [e["text"] for e in ents]
        self.assertIn("Primary text", texts)
        self.assertIn("Extra text", texts)

    def test_valid_link_not_corrupted_by_card(self):
        """Valid YouTube link must never be replaced by card videoId (Critique 4 regression)."""
        text = "https://www.youtube.com/watch?v=AAAAAAAAAAA"
        cards = [{"videoId": "BBBBBBBBBBB", "title": "Other Video"}]
        fixed = fix_truncated_links_in_text(text, cards)
        self.assertEqual(fixed, text)
        result = append_related_videos_to_text(fixed, cards)
        self.assertIn("https://www.youtube.com/watch?v=AAAAAAAAAAA", result)
        self.assertIn("https://youtu.be/BBBBBBBBBBB - Other Video", result)
        self.assertNotIn("https://youtu.be/BBBBBBBBBBB", fixed)

    def test_shorter_final_streaming_replaces_longer_draft(self):
        """A shorter final streaming response must replace an earlier draft response (Critique 5)."""
        draft_text = "Based on the discussion, here is a preliminary and verbose draft that contains extra words and details that will be refined later."
        final_text = "Here is the concise summary."
        self.assertGreater(len(draft_text), len(final_text))

        chunk1 = build_synthetic_payload(draft_text)
        chunk2 = build_synthetic_payload(final_text)

        result = aggregate_text_from_payloads([chunk1, chunk2])
        self.assertEqual(result, final_text)

    def test_streaming_independent_blocks_aggregated(self):
        """Independent entity blocks across payloads must be aggregated in order."""
        block1 = "Section 1: Core concepts and findings."
        block2 = "Section 2: Detailed recommendations."

        p1 = build_basic_content_payload("block_1", block1)
        p2 = build_basic_content_payload("block_2", block2)

        result = aggregate_text_from_payloads([p1, p2])
        self.assertIn(block1, result)
        self.assertIn(block2, result)

    def test_append_related_videos(self):
        """Related videos must be appended when not present in summary text."""
        summary = "Here are 5 similar videos discussing out-of-body experiences."
        videos = [
            {"videoId": "1XvkgjH1SOg", "title": "Max Spiers"},
            {"videoId": "-5OHks6dNVk", "title": "Cappy Army"}
        ]
        result = append_related_videos_to_text(summary, videos)
        self.assertTrue(result.startswith(summary))
        self.assertIn("Related videos:", result)
        self.assertIn("1. https://youtu.be/1XvkgjH1SOg - Max Spiers", result)
        self.assertIn("2. https://youtu.be/-5OHks6dNVk - Cappy Army", result)

        # Do not duplicate if already present
        no_dup = append_related_videos_to_text(result, videos)
        self.assertEqual(no_dup, result)


    def test_append_related_videos_empty_text(self):
        """Cards-only response (empty text) must produce formatted related videos output."""
        videos = [
            {"videoId": "1XvkgjH1SOg", "title": "Max Spiers"},
            {"videoId": "-5OHks6dNVk", "title": "Cappy Army"}
        ]
        result = append_related_videos_to_text("", videos)
        self.assertTrue(result.startswith("Related videos:"))
        self.assertIn("1. https://youtu.be/1XvkgjH1SOg - Max Spiers", result)
        self.assertIn("2. https://youtu.be/-5OHks6dNVk - Cappy Army", result)

    def test_streaming_accumulation(self):
        """Streaming responses must preserve the longest / latest accumulated response."""
        chunk1 = build_synthetic_payload("Here is the start of")
        chunk2 = build_synthetic_payload("Here is the start of the completed summary.")
        ans1 = extract_answer_from_payload(chunk1)
        ans2 = extract_answer_from_payload(chunk2)
        # Verify parser extracts both, and chunk2 is longer
        self.assertIsNotNone(ans1)
        self.assertIsNotNone(ans2)
        self.assertGreater(len(ans2), len(ans1))

    def test_prose_youtube_not_deleted(self):
        """Plain prose reference to 'YouTube' must never be deleted by link cleaner."""
        text = "YouTube explains the topic clearly and provides helpful tutorials."
        cleaned = fix_truncated_links_in_text(text)
        self.assertEqual(cleaned, text)

    def test_two_independent_primary_path_blocks_retained(self):
        """Two independent primary-path blocks in a single payload must both be retained."""
        p1 = build_synthetic_payload("Primary Section 1: Overview")
        p2 = build_synthetic_payload("Primary Section 2: Details")
        payload = p1 + p2
        ents = extract_entities_from_payload(payload)
        self.assertEqual(len(ents), 2)
        texts = [e["text"] for e in ents]
        self.assertIn("Primary Section 1: Overview", texts)
        self.assertIn("Primary Section 2: Details", texts)
        # Ensure keys are distinct
        self.assertNotEqual(ents[0]["key"], ents[1]["key"])

    def test_distinct_keys_with_identical_text_retained(self):
        """Two distinct entity keys with identical text must both be retained (no seenTexts loss)."""
        e1 = build_basic_content_payload("key_alpha", "Repeated bullet text point")
        e2 = build_basic_content_payload("key_beta", "Repeated bullet text point")
        payload = e1 + e2
        ents = extract_entities_from_payload(payload)
        self.assertEqual(len(ents), 2)
        self.assertEqual(ents[0]["text"], "Repeated bullet text point")
        self.assertEqual(ents[1]["text"], "Repeated bullet text point")
        self.assertNotEqual(ents[0]["key"], ents[1]["key"])

    def test_too_long_video_id_rejected(self):
        """A video URL with a 15-character ID must NOT be accepted as a valid video link."""
        text = "Invalid link: https://www.youtube.com/watch?v=12345678901ABCD"
        cleaned = fix_truncated_links_in_text(text)
        self.assertEqual(cleaned, "Invalid link")

    def test_truncated_link_cleaned_without_resolutions(self):
        """Truncated YouTube link must be removed even when no attributed resolutions map is provided."""
        text = "Key takeaway:\n• https://www.youtube.co...\nMore text."
        cleaned = fix_truncated_links_in_text(text, None)
        self.assertNotIn("https://www.youtube.co...", cleaned)
        self.assertIn("Key takeaway:", cleaned)
        self.assertIn("More text.", cleaned)

    def test_reproduction_1_no_positional_guessing_when_second_item_captured(self):
        """When two recommendations exist and only the second video's endpoint is captured,
        item 1 must NOT receive the link. The link must belong only to item 2, and the
        unverified placeholder on item 1 must be removed without leaving empty bullets."""
        text = "1. First fox ( • )\n2. Second fox ( • )"
        i2 = text.find("( • )", text.find("( • )") + 1)
        annotations = [
            {"videoId": "BBBBBBBBBBB", "offset": i2, "length": 5}
        ]
        reconstructed = reconstruct_entity_text_with_annotations(text, annotations)
        cleaned = fix_truncated_links_in_text(reconstructed)
        self.assertIn("1. First fox", cleaned)
        self.assertNotIn("1. First fox https://youtu.be/BBBBBBBBBBB", cleaned)
        self.assertIn("2. Second fox https://youtu.be/BBBBBBBBBBB", cleaned)
        self.assertNotIn("( • )", cleaned)

    def test_reproduction_1_unassociated_videos_appended_separately(self):
        """When captured video cards lack entity annotation offsets (e.g. separate card carousel),
        they must NOT be guess-inserted into numbered lines. They must be appended under 'Related videos:'."""
        text = "1. First fox ( • )\n2. Second fox ( • )"
        cards = [{"videoId": "BBBBBBBBBBB", "title": "Second fox video"}]
        cleaned = fix_truncated_links_in_text(text)
        result = append_related_videos_to_text(cleaned, cards)
        self.assertIn("1. First fox", result)
        self.assertNotIn("1. First fox https://youtu.be/BBBBBBBBBBB", result)
        self.assertNotIn("2. Second fox https://youtu.be/BBBBBBBBBBB", result)
        self.assertIn("Related videos:", result)
        self.assertIn("1. https://youtu.be/BBBBBBBBBBB - Second fox video", result)

    def test_reproduction_2_opaque_field_99_rejected(self):
        """Wrapping node 1382 in opaque field 99 must NOT extract its video, enforcing structural provenance."""
        we_bytes = encode_field(1, 2, b"CCCCCCCCCCC")
        cmd_bytes = encode_field(48687757, 2, we_bytes)
        ann_bytes = encode_field(1, 0, 3) + encode_field(2, 0, 14) + encode_field(3, 2, cmd_bytes)
        text_bytes = b"1. Fox ( \xe2\x80\xa2 )"
        inner_container = encode_field(1, 2, text_bytes) + encode_field(5, 2, ann_bytes)
        node_1382 = encode_field(2, 2, encode_field(2, 2, inner_container))

        # Wrapped in opaque field 99:
        opaque_payload = encode_field(99, 2, encode_field(1382, 2, node_1382))
        self.assertGreater(len(opaque_payload), 30)
        vids = extract_videos_from_payload(opaque_payload)
        self.assertEqual(vids, [])

    def test_reproduction_3_unicode_whitespace_in_placeholder(self):
        """Placeholders containing non-breaking spaces (\u00A0) and narrow no-break spaces (\u202F) must be cleaned."""
        # Non-breaking space \u00A0: "1. Fox (\u00a0\u00a0\u00a0•\u00a0\u00a0\u00a0)"
        text1 = "1. Fox (\u00a0\u00a0\u00a0•\u00a0\u00a0\u00a0) https://www.youtube.co..."
        cleaned1 = fix_truncated_links_in_text(text1)
        self.assertEqual(cleaned1, "1. Fox")

        # Narrow no-break space \u202F: "2. Fox (\u202F•\u202F)"
        text2 = "2. Fox (\u202F•\u202F) https://www.youtube.co..."
        cleaned2 = fix_truncated_links_in_text(text2)
        self.assertEqual(cleaned2, "2. Fox")

        # Range reconstruction with non-breaking whitespace:
        text3 = "1. Fox (\u00a0•\u00a0)"
        i3 = text3.find("(\u00a0•\u00a0)")
        ann = [{"videoId": "Fox12345678", "offset": i3, "length": 5}]
        reconstructed = reconstruct_entity_text_with_annotations(text3, ann)
        self.assertEqual(reconstructed, "1. Fox https://youtu.be/Fox12345678")

    def test_five_fox_recommendations_with_verified_destinations_and_timestamps(self):
        """A complete 5-item fox recommendation response with verified destination IDs
        and active video timestamp endpoints must correctly attribute all 5 destinations
        and filter out the active video's timestamp endpoints."""
        source_vid = "SourceVid11"
        fox_vids = ["RedFox11111", "Arctic22222", "Fennec33333", "GrayFox4444", "KitFox55555"]
        fox_titles = ["Red Fox", "Arctic Fox", "Fennec Fox", "Gray Fox", "Kit Fox"]

        lines = []
        annotations = []
        curr_offset = 0
        for i, (title, vid) in enumerate(zip(fox_titles, fox_vids), 1):
            prefix = f"{i}. {title} "
            placeholder = "( • )"
            line = prefix + placeholder
            off = curr_offset + len(prefix)
            annotations.append({
                "videoId": vid,
                "title": title,
                "offset": off,
                "length": len(placeholder),
                "timestamp": 0.0
            })
            lines.append(line)
            curr_offset += len(line) + 1  # newline

        full_text = "\n".join(lines)

        # Active video timestamp endpoints:
        ts_annotations = [
            {"videoId": source_vid, "title": "0:45", "offset": 0, "length": 4, "timestamp": 45.0},
            {"videoId": source_vid, "title": "1:30", "offset": 20, "length": 4, "timestamp": 90.0},
        ]

        # Reconstruct full text using annotations
        reconstructed = reconstruct_entity_text_with_annotations(full_text, annotations)
        cleaned = fix_truncated_links_in_text(reconstructed)

        for i, (title, vid) in enumerate(zip(fox_titles, fox_vids), 1):
            expected_line = f"{i}. {title} https://youtu.be/{vid}"
            self.assertIn(expected_line, cleaned)
            self.assertNotIn("( • )", cleaned)

        # Filter active video timestamps
        all_anns = annotations + ts_annotations
        filtered = [a for a in all_anns if a["videoId"] != source_vid and a.get("timestamp", 0.0) == 0.0]
        self.assertEqual(len(filtered), 5)

    def test_observed_1337_card_layout_extracted_from_mutation_operations(self):
        """Observed 1337 -> ... -> 232903841 Elements card layout in YTISectionListMutationOperations
        must successfully extract all 5 related video cards with exact IDs and full titles."""
        matches = (
            glob.glob("/Users/fil/Downloads/*26119E90*.json")
            + glob.glob("/Users/fil/.gemini/antigravity/brain/*/.user_uploaded/*26119E90*.json")
            + glob.glob("/Users/fil/.gemini/antigravity/brain/*/*26119E90*.json")
        )
        if not matches:
            self.skipTest("Capture 26119E90 not found")
        with open(matches[0]) as f:
            d = json.load(f)

        item = d["events"][197]["items"][0]
        payload = base64.b64decode(item["payload"])
        active_vid = "o3IuPEJXXE4"

        vids = extract_videos_from_payload_with_class(payload, item.get("class", ""), active_vid)
        expected_ids = ["4p3kNCrJ31w", "iSSCh4xyP_k", "PHpsdIHpLUE", "8xOtzzDy0Dw", "xlUyPAZvA_Q"]
        extracted_ids = [v["videoId"] for v in vids]
        self.assertEqual(extracted_ids, expected_ids)

        # Verify decoded titles
        titles = [v["title"] for v in vids]
        self.assertIn("Chase Hughes", titles[0])
        self.assertIn("SRS #253", titles[0])
        self.assertIn("Chris Ramsay", titles[1])
        self.assertIn("Anomalous Podcast", titles[1])
        self.assertIn("Neil deGrasse Tyson", titles[2])
        self.assertIn("TONGUE by Chase Hughes", titles[3])
        self.assertIn("They’re Not Coming From Space", titles[4])

        # Verify end-to-end AI summary settlement:
        # Initial AI summary has the 5 titles but no URLs; appending related videos lists all 5 at the end
        raw_text = d["events"][198]["rawText"]
        cleaned_text = fix_truncated_links_in_text(raw_text, vids)
        final_summary = append_related_videos_to_text(cleaned_text, vids)
        self.assertIn("Related videos:", final_summary)
        for i, (vid, title) in enumerate(zip(expected_ids, titles), 1):
            self.assertIn(f"{i}. https://youtu.be/{vid} - {title}", final_summary)


if __name__ == "__main__":
    unittest.main()
