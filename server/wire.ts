// Shared protobuf wire codec for the recommendation server.
//
// Parses a payload into fields (recursing into nested messages where the bytes
// parse cleanly, keeping opaque segments raw) and re-serializes with its own
// encoder, recomputing every key and length prefix. Verified byte-identical on
// real Home/watch payloads (525,872 B / 760,474 B captures), which is what
// makes payload modification safe: edit the tree, encode, done.

export interface WireField {
  field: number;
  wire: number; // 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32
  varint?: bigint;
  bytes?: Uint8Array;
}

export function readVarintAt(bytes: Uint8Array, offset: number): { value: bigint; next: number } | null {
  let result = 0n, shift = 0n, i = offset;
  while (i < bytes.length && shift < 70n) {
    const byte = bytes[i++];
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value: result, next: i };
    shift += 7n;
  }
  return null;
}

export function parseWireMessage(bytes: Uint8Array): WireField[] | null {
  const fields: WireField[] = [];
  let i = 0;
  while (i < bytes.length) {
    const key = readVarintAt(bytes, i);
    if (key === null) return null;
    i = key.next;
    const field = Number(key.value >> 3n);
    const wire = Number(key.value & 7n);
    if (field === 0 || field > 536_870_911) return null;
    if (wire === 0) {
      const value = readVarintAt(bytes, i);
      if (value === null) return null;
      i = value.next;
      fields.push({ field, wire, varint: value.value });
    } else if (wire === 1) {
      if (i + 8 > bytes.length) return null;
      fields.push({ field, wire, bytes: bytes.slice(i, i + 8) });
      i += 8;
    } else if (wire === 5) {
      if (i + 4 > bytes.length) return null;
      fields.push({ field, wire, bytes: bytes.slice(i, i + 4) });
      i += 4;
    } else if (wire === 2) {
      const len = readVarintAt(bytes, i);
      if (len === null) return null;
      i = len.next;
      const end = i + Number(len.value);
      if (end > bytes.length) return null;
      fields.push({ field, wire, bytes: bytes.slice(i, end) });
      i = end;
    } else {
      return null; // groups are not emitted by modern protobuf
    }
  }
  return fields;
}

export function encodeWireVarint(value: bigint): Uint8Array {
  const out: number[] = [];
  let v = value;
  while (v >= 0x80n) {
    out.push(Number(v & 0x7fn) | 0x80);
    v >>= 7n;
  }
  out.push(Number(v));
  return new Uint8Array(out);
}

export function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) total += part.length;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

// Encodes a field list, canonicalizing keys/lengths and recursing into any
// length-delimited field that parses cleanly as a message (so nested edits are
// re-measured). Opaque segments are emitted unchanged.
export function encodeWireMessage(fields: WireField[]): Uint8Array {
  const parts: Uint8Array[] = [];
  for (const f of fields) {
    parts.push(encodeWireVarint(BigInt(f.field) * 8n + BigInt(f.wire)));
    if (f.wire === 0) {
      parts.push(encodeWireVarint(f.varint!));
    } else if (f.wire === 2) {
      let body = f.bytes!;
      const child = parseWireMessage(body);
      if (child !== null && child.length > 0) body = encodeWireMessage(child);
      parts.push(encodeWireVarint(BigInt(body.length)));
      parts.push(body);
    } else {
      parts.push(f.bytes!);
    }
  }
  return concatBytes(parts);
}

export interface RecodeResult {
  bytes: Uint8Array;
  identical: boolean;
  firstDiff: number;
  topFields: number;
  messages: number;
}

// Lossless round trip with an identity report (used by --action recode).
export function recodePayload(payload: Uint8Array): RecodeResult | null {
  const fields = parseWireMessage(payload);
  if (fields === null) return null;
  const bytes = encodeWireMessage(fields);
  let firstDiff = -1;
  if (bytes.length !== payload.length) {
    firstDiff = Math.min(bytes.length, payload.length);
  } else {
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] !== payload[i]) { firstDiff = i; break; }
    }
  }
  return { bytes, identical: firstDiff === -1, firstDiff, topFields: fields.length, messages: countMessages(fields) };
}

function countMessages(fields: WireField[]): number {
  let count = 0;
  for (const f of fields) {
    if (f.wire !== 2 || f.bytes === undefined) continue;
    const child = parseWireMessage(f.bytes);
    if (child !== null && child.length > 0) count += 1 + countMessages(child);
  }
  return count;
}
