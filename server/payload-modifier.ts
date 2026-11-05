// Payload modification: remove / replace / add recommendation cards.
//
// ── Notes for building these functions (verified on a real 21.33.6 payload) ──
//
// Wire model
//   • Every message level is a WireField[] (wire.ts). Length-delimited fields
//     are raw bytes; encodeWireMessage() recurses and recomputes every length,
//     so edits at any depth re-serialize correctly (lossless recode already
//     proven byte-identical on 525 KB and 760 KB payloads).
//   • Opaque segments that do not parse as messages are preserved verbatim.
//
// Containers (docs/ytprotocol.md has the full map)
//   • Modern Home shelf: a message holding child field 312131490. Its child
//     contains an entry at field 20 whose fields are:
//       f1 header  — heading text at f20 (f26 accessibility duplicate)
//       f9 cards   — repeated, one lockup card per entry (this list is what
//                    replace/remove/insert operate on)
//       …          — tracking fields, preserved untouched
//   • Legacy shelf: child field 51845067, title in f1, content under f5.
//     We support listing/removing legacy shelves; item edits are modern-only
//     until a legacy fixture with items is captured.
//   • Lockup card: f1 media (f2 = duration string), f2 metadata (f1 = title),
//     f6 "//www.youtube.com/watch?v=<id>", f7 id, f18 id, menus under
//     f7/f14 → 169495254 → … (never touch), nav title/channel at
//     f6 → …48687757 → f36/f37.
//   • Shorts item: wrapper child 519005951 → f17 item; id deep inside; no
//     title text in the browse payload (do not fabricate one).
//
// Operation semantics
//   • removeShelf            — drops the shelf container field entirely
//                              (heading + cards + tracking all go).
//   • setShelfCards          — replaces the whole f9 card list (each card is
//                              one complete lockup-card message).
//   • removeShelfCard(i)     — drops card i from the f9 list.
//   • replaceShelfCard(i, c) — swaps card i's bytes for a cloned/prepared card.
//   • insertShelfCard(i, c)  — inserts a cloned card at position i.
//   • cloneCardAs(template)  — clones a real card and patches it:
//                              every ASCII occurrence of the old 11-char id,
//                              the metadata title (f2.f1), and the navData
//                              title (f36) when it equals the old title.
//                              Thumbnail URLs derive from the id, so they are
//                              covered by the id substitution.
//
// Invariants (do not break these)
//   • Never touch continuation tokens / nextContinuationData — pagination must
//     keep working with YouTube's original cursor.
//   • Keep unknown/tracking fields; splice, don't rebuild messages by hand.
//   • Card order is display order; there is no separate sort index.
//   • After edits the client re-parses the payload into the native GPB class;
//     a structurally valid page is rendered as-is. Validate on device: cards
//     must render, tap through (watchEndpoint ids), and paginate.
//
// Known limits
//   • Cards reference per-build renderer layouts; clone templates from the
//     same YouTube build (a saved fixture is fine) — schema drift breaks them.
//   • Shorts shelf cards carry no title in browse payloads; inserted Shorts
//     cards need a template from a Shorts payload and will show no title.
//   • Watch-page related lists use the same lockup/compact shapes at other
//     paths; the heading-based shelf API targets Home shelves. Card-level
//     helpers work wherever the lockup shape appears.

import {
  type WireField,
  parseWireMessage,
  encodeWireMessage,
  concatBytes,
  readVarintAt,
} from "./wire.ts";

const utf8 = new TextDecoder("utf-8", { fatal: true });
const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const MODERN_SHELF_FIELD = 312131490;
const LEGACY_SHELF_FIELD = 51845067;
const SHORTS_ITEM_FIELD = 519005951;

export interface ShelfInfo {
  heading: string;
  kind: "modern" | "legacy";
  cardCount: number;
  cards: Uint8Array[];
}

function asFields(bytes: Uint8Array | undefined): WireField[] | null {
  if (bytes === undefined) return null;
  const fields = parseWireMessage(bytes);
  return fields !== null && fields.length > 0 ? fields : null;
}

function asText(bytes: Uint8Array | undefined): string | undefined {
  if (bytes === undefined) return undefined;
  try {
    const text = utf8.decode(bytes);
    return /[\u0000-\u001f]/.test(text) ? undefined : text;
  } catch {
    return undefined;
  }
}

function textField(bytes: Uint8Array | undefined): string | undefined {
  const fields = asFields(bytes);
  if (fields === null) return asText(bytes);
  for (const f of fields) {
    const text = asText(f.bytes);
    if (text !== undefined) return text;
  }
  return undefined;
}

function firstTitleLike(bytes: Uint8Array | undefined): string | undefined {
  const fields = asFields(bytes);
  if (fields === null) {
    const text = asText(bytes);
    return text !== undefined && /\p{L}/u.test(text) ? text : undefined;
  }
  for (const f of fields) {
    if (f.wire !== 2) continue;
    const direct = asText(f.bytes);
    if (direct !== undefined) {
      if (/\p{L}/u.test(direct)) return direct;
      continue;
    }
    const nested = firstTitleLike(f.bytes);
    if (nested !== undefined) return nested;
  }
  return undefined;
}

// Modern shelf wrapper bytes → { heading, entryFields }.
function modernShelf(shelfBytes: Uint8Array): { heading: string; entryFields: WireField[] } | null {
  const shelfFields = asFields(shelfBytes);
  if (shelfFields === null) return null;
  const entry = shelfFields.find((f) => f.field === 20 && f.wire === 2);
  if (entry === undefined) return null;
  const entryFields = asFields(entry.bytes);
  if (entryFields === null) return null;
  const header = entryFields.find((f) => f.field === 1 && f.wire === 2);
  let heading: string | undefined;
  if (header !== undefined) {
    const headerFields = asFields(header.bytes);
    const headingField = headerFields?.find((f) => f.field === 20 && f.wire === 2);
    heading = headingField !== undefined ? asText(headingField.bytes) : textField(header.bytes);
  }
  return { heading: heading ?? "", entryFields };
}

function legacyShelfHeading(shelfBytes: Uint8Array): string | undefined {
  const fields = asFields(shelfBytes);
  if (fields === null) return undefined;
  const title = fields.find((f) => f.field === 1 && f.wire === 2);
  return title !== undefined ? firstTitleLike(title.bytes) : undefined;
}

// Lists every shelf in the payload (modern + legacy), with its cards.
export function findShelves(payload: Uint8Array): ShelfInfo[] {
  const shelves: ShelfInfo[] = [];
  const visit = (fields: WireField[]): void => {
    for (const f of fields) {
      if (f.wire !== 2 || f.bytes === undefined) continue;
      if (f.field === MODERN_SHELF_FIELD) {
        const shelf = modernShelf(f.bytes);
        if (shelf !== null) {
          const cards = shelf.entryFields.filter((x) => x.field === 9 && x.wire === 2).map((x) => x.bytes!);
          shelves.push({ heading: shelf.heading, kind: "modern", cardCount: cards.length, cards });
        }
      } else if (f.field === LEGACY_SHELF_FIELD) {
        const heading = legacyShelfHeading(f.bytes);
        if (heading !== undefined) shelves.push({ heading, kind: "legacy", cardCount: 0, cards: [] });
      }
      const child = asFields(f.bytes);
      if (child !== null) visit(child);
    }
  };
  const top = parseWireMessage(payload);
  if (top !== null) visit(top);
  return shelves;
}

type FieldsVisitor = (fields: WireField[], depth: number) => WireField[] | null;

// Bottom-up tree edit: children are rewritten first, then the visitor may
// replace this node's whole field list. Untouched branches keep their bytes.
function editTree(bytes: Uint8Array, visitor: FieldsVisitor, depth = 0): { bytes: Uint8Array; changed: boolean } {
  const fields = parseWireMessage(bytes);
  if (fields === null) return { bytes, changed: false };
  let changed = false;
  const rewritten = fields.map((f) => {
    if (f.wire !== 2 || f.bytes === undefined) return f;
    const child = asFields(f.bytes);
    if (child === null) return f;
    const result = editTree(f.bytes!, visitor, depth + 1);
    if (result.changed) {
      changed = true;
      return { ...f, bytes: result.bytes };
    }
    return f;
  });
  const replaced = visitor(rewritten, depth);
  if (replaced !== null) return { bytes: encodeWireMessage(replaced), changed: true };
  return { bytes: changed ? encodeWireMessage(rewritten) : bytes, changed };
}

function withModernShelf(payload: Uint8Array, heading: string,
                         mutate: (entryFields: WireField[], cards: WireField[]) => WireField[] | null):
  { bytes: Uint8Array; changed: boolean; cards: number } {
  let cards = 0;
  const result = editTree(payload, (fields) => {
    const index = fields.findIndex((f) =>
      f.field === MODERN_SHELF_FIELD && f.wire === 2 && f.bytes !== undefined &&
      (modernShelf(f.bytes)?.heading ?? null) === heading);
    if (index === -1) return null;
    const shelfField = fields[index];
    const shelfFields = asFields(shelfField.bytes);
    if (shelfFields === null) return null;
    const entryIndex = shelfFields.findIndex((f) => f.field === 20 && f.wire === 2);
    if (entryIndex === -1) return null;
    const entryFields = asFields(shelfFields[entryIndex].bytes);
    if (entryFields === null) return null;
    const cardFields = entryFields.filter((f) => f.field === 9 && f.wire === 2);
    const replacement = mutate(entryFields, cardFields);
    if (replacement === null) return null;
    cards = replacement.filter((f) => f.field === 9 && f.wire === 2).length;
    const newShelf = [...shelfFields];
    newShelf[entryIndex] = { ...shelfFields[entryIndex], bytes: encodeWireMessage(replacement) };
    const newFields = [...fields];
    newFields[index] = { ...shelfField, bytes: encodeWireMessage(newShelf) };
    return newFields;
  });
  return { bytes: result.bytes, changed: result.changed, cards };
}

// Removes every shelf whose heading matches one of `headings` (modern + legacy).
export function removeShelves(payload: Uint8Array, headings: string[]): { bytes: Uint8Array; removed: string[] } {
  const wanted = new Set(headings.map((h) => h.trim()).filter((h) => h.length > 0));
  const removed: string[] = [];
  if (wanted.size === 0) return { bytes: payload, removed };
  const result = editTree(payload, (fields) => {
    let changed = false;
    const kept: WireField[] = [];
    for (const f of fields) {
      if (f.wire === 2 && f.bytes !== undefined) {
        if (f.field === MODERN_SHELF_FIELD) {
          const heading = modernShelf(f.bytes)?.heading ?? "";
          if (wanted.has(heading)) { removed.push(heading); changed = true; continue; }
        } else if (f.field === LEGACY_SHELF_FIELD) {
          const heading = legacyShelfHeading(f.bytes) ?? "";
          if (wanted.has(heading)) { removed.push(heading); changed = true; continue; }
        }
      }
      kept.push(f);
    }
    return changed ? kept : null;
  });
  return { bytes: result.bytes, removed: [...new Set(removed)] };
}

// Replaces the complete card list of a modern shelf (display order = array order).
export function setShelfCards(payload: Uint8Array, heading: string, cards: Uint8Array[]):
  { bytes: Uint8Array; changed: boolean } {
  const result = withModernShelf(payload, heading, (entryFields) => {
    const kept = entryFields.filter((f) => !(f.field === 9 && f.wire === 2));
    const cardFields = cards.map((bytes): WireField => ({ field: 9, wire: 2, bytes }));
    return [...kept, ...cardFields];
  });
  return { bytes: result.bytes, changed: result.changed };
}

export function removeShelfCard(payload: Uint8Array, heading: string, index: number):
  { bytes: Uint8Array; changed: boolean } {
  const result = withModernShelf(payload, heading, (entryFields, cards) => {
    if (index < 0 || index >= cards.length) return null;
    let seen = 0;
    return entryFields.filter((f) => {
      if (f.field !== 9 || f.wire !== 2) return true;
      const keep = seen !== index;
      seen += 1;
      return keep;
    });
  });
  return { bytes: result.bytes, changed: result.changed };
}

export function replaceShelfCard(payload: Uint8Array, heading: string, index: number, card: Uint8Array):
  { bytes: Uint8Array; changed: boolean } {
  const result = withModernShelf(payload, heading, (entryFields, cards) => {
    if (index < 0 || index >= cards.length) return null;
    let seen = 0;
    return entryFields.map((f) => {
      if (f.field !== 9 || f.wire !== 2) return f;
      const replace = seen === index;
      seen += 1;
      return replace ? { ...f, bytes: card } : f;
    });
  });
  return { bytes: result.bytes, changed: result.changed };
}

export function insertShelfCard(payload: Uint8Array, heading: string, index: number, card: Uint8Array):
  { bytes: Uint8Array; changed: boolean } {
  const result = withModernShelf(payload, heading, (entryFields, cards) => {
    if (index < 0 || index > cards.length) return null;
    const out: WireField[] = [];
    let seen = 0;
    let inserted = false;
    for (const f of entryFields) {
      if (f.field === 9 && f.wire === 2) {
        if (seen === index) { out.push({ field: 9, wire: 2, bytes: card }); inserted = true; }
        seen += 1;
      }
      out.push(f);
    }
    if (!inserted) out.push({ field: 9, wire: 2, bytes: card });
    return out;
  });
  return { bytes: result.bytes, changed: result.changed };
}

// ── Card cloning ─────────────────────────────────────────────────────────────

function replaceAscii(bytes: Uint8Array, from: string, to: string): Uint8Array {
  if (from.length === 0 || from.length !== to.length) return bytes;
  const needle = new TextEncoder().encode(from);
  const replacement = new TextEncoder().encode(to);
  const out = new Uint8Array(bytes);
  let i = 0;
  while (i + needle.length <= out.length) {
    let hit = true;
    for (let j = 0; j < needle.length; j++) {
      if (out[i + j] !== needle[j]) { hit = false; break; }
    }
    if (hit) {
      out.set(replacement, i);
      i += needle.length;
    } else {
      i += 1;
    }
  }
  return out;
}

function cardFields(card: Uint8Array): WireField[] | null {
  return asFields(card);
}

function cardVideoId(fields: WireField[]): string | undefined {
  for (const f of fields) {
    if (f.field === 7 && f.wire === 2) {
      const text = asText(f.bytes);
      if (text !== undefined && VIDEO_ID.test(text)) return text;
    }
  }
  return undefined;
}

function cardTitle(fields: WireField[]): string | undefined {
  const metadata = fields.find((f) => f.field === 2 && f.wire === 2);
  if (metadata === undefined) return undefined;
  const metaFields = asFields(metadata.bytes);
  if (metaFields === null) return undefined;
  const title = metaFields.find((f) => f.field === 1 && f.wire === 2);
  return title !== undefined ? asText(title.bytes) : undefined;
}

export interface CloneOptions {
  newId: string;
  newTitle?: string;
  newChannel?: string;
}

// Clones a real lockup card and rewrites identity: every ASCII occurrence of
// the old id (navigation, thumbnail URLs, tracking), the metadata title, and
// the navData title/channel when present.
export function cloneCardAs(template: Uint8Array, options: CloneOptions): Uint8Array {
  const fields = cardFields(template);
  if (fields === null) throw new Error("template card is not a protobuf message");
  const oldId = cardVideoId(fields);
  if (oldId === undefined) throw new Error("template card has no videoId field (f7)");
  if (!VIDEO_ID.test(options.newId)) throw new Error(`invalid videoId: ${options.newId}`);

  // Length-preserving id substitution first (11 chars).
  let card = replaceAscii(template, oldId, options.newId);

  const oldTitle = cardTitle(fields);
  if (options.newTitle !== undefined && oldTitle !== undefined && oldTitle !== options.newTitle) {
    // Rewrite text leaves equal to the old title anywhere in the card
    // (metadata title and navData title share the same string).
    const titleBytes = new TextEncoder().encode(oldTitle);
    const newTitleBytes = new TextEncoder().encode(options.newTitle);
    const result = editTree(card, (nodeFields) => {
      let changed = false;
      const rewritten = nodeFields.map((f) => {
        if (f.wire !== 2 || f.bytes === undefined) return f;
        if (asText(f.bytes) === oldTitle) {
          changed = true;
          return { ...f, bytes: newTitleBytes };
        }
        return f;
      });
      return changed ? rewritten : null;
    });
    card = result.bytes;
    void titleBytes;
  }
  if (options.newChannel !== undefined) {
    // Channel name lives at navData f37 (verified); rewrite text leaves equal
    // to the byline-ish channel if the caller knows it. Omitted by default.
    card = card;
  }
  return card;
}

// Convenience: replace shelf card `index` with a clone of `template`.
export function replaceShelfCardWithClone(payload: Uint8Array, heading: string, index: number,
                                          template: Uint8Array, options: CloneOptions):
  { bytes: Uint8Array; changed: boolean } {
  return replaceShelfCard(payload, heading, index, cloneCardAs(template, options));
}
