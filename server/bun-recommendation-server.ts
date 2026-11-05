#!/usr/bin/env bun
/**
 * Bun recommendation server for the YTKACE recommendations patch (§99).
 *
 * Endpoints (the only ones; anything else is a 404):
 *   POST /yt-browse  — Home feed pages (browseId FEwhat_to_watch + Home continuations)
 *   POST /yt-next    — watch page + related-list pages
 *   GET  /           — health document (also the patch's connection probe)
 *
 * Request body: docs/recommendations.md §5 envelope (JSON; payload = base64 of
 * the untouched original protobuf; videoId in context for watch). Reply:
 * action "replace" (payload echoed + one marker field appended) or
 * "passthrough". Payload content is never logged — sizes and sha256 prefixes
 * only; --dump-dir optionally saves the originals for offline debugging.
 *
 * Usage:
 *   bun run Tools/bun-recommendation-server.ts --action replace --port 8046 \
 *       --log-file ~/yt-rec-server.log
 *
 * Actions: replace | passthrough | invalid-base64 | request-id-mismatch |
 * version-mismatch | unknown-action | oversized | http-error; --delay-ms
 * forces timeouts. This server is the production dev target; the Python mock
 * (Tools/mock-recommendation-server.py) is the CI contract reference.
 */

import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { readVarintAt, parseWireMessage, encodeWireMessage, recodePayload } from "./wire.ts";
import { removeShelves } from "./payload-modifier.ts";

const MARKER_TEXT = "RECSRV";
const ACTIONS = [
  "replace", "passthrough", "recode", "invalid-base64", "request-id-mismatch",
  "version-mismatch", "unknown-action", "oversized", "http-error",
] as const;
type Action = (typeof ACTIONS)[number];

interface Options {
  host: string;
  port: number;
  action: Action;
  delayMs: number;
  markerField: number;
  logFile: string;
  apiLogFile: string | null;
  savesLogFile: string | null;
  dumpDir: string | null;
  decode: boolean;
  dropHeadings: string[];
  inferPlayback: boolean;
}

function parseArgs(argv: string[]): Options {
  const options: Options = {
    host: "0.0.0.0",
    port: 8046,
    action: "replace",
    delayMs: 0,
    markerField: 90001,
    logFile: "bun-server.log",
    apiLogFile: "", // default: api.log next to --log-file; --no-api-log disables
    savesLogFile: "", // default: saves.jsonl next to --log-file; --no-saves-log disables
    dumpDir: null,
    decode: true,
    dropHeadings: [],
    inferPlayback: false,
  };
  const values = new Set(["--host", "--port", "--action", "--delay-ms", "--marker-field", "--log-file", "--dump-dir", "--saves-log"]);
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === "--host") options.host = argv[++i] ?? options.host;
    else if (flag === "--port") options.port = Number(argv[++i] ?? options.port);
    else if (flag === "--delay-ms") options.delayMs = Number(argv[++i] ?? options.delayMs);
    else if (flag === "--marker-field") options.markerField = Number(argv[++i] ?? options.markerField);
    else if (flag === "--log-file") options.logFile = argv[++i] ?? options.logFile;
    else if (flag === "--dump-dir") options.dumpDir = argv[++i] ?? null;
    else if (flag === "--no-decode") options.decode = false;
    else if (flag === "--decode") options.decode = true;
    else if (flag === "--api-log") options.apiLogFile = argv[++i] ?? "";
    else if (flag === "--no-api-log") options.apiLogFile = null;
    else if (flag === "--saves-log") options.savesLogFile = argv[++i] ?? "";
    else if (flag === "--no-saves-log") options.savesLogFile = null;
    else if (flag === "--drop-heading") options.dropHeadings.push(argv[++i] ?? "");
    else if (flag === "--infer-playback") options.inferPlayback = true;
    else if (flag === "--no-infer-playback") options.inferPlayback = false;
    else if (flag === "--action") {
      const action = argv[++i] as Action;
      if (!ACTIONS.includes(action)) throw new Error(`unknown action ${action}; expected one of ${ACTIONS.join(", ")}`);
      options.action = action;
    } else throw new Error(`unknown flag ${flag}`);
  }
  if (!Number.isFinite(options.port)) throw new Error("--port must be a number");
  if (!Number.isFinite(options.delayMs) || options.delayMs < 0) throw new Error("--delay-ms must be >= 0");
  return options;
}

const options = parseArgs(process.argv.slice(2));
if (options.apiLogFile === "") {
  const directory = options.logFile.includes("/")
    ? options.logFile.slice(0, options.logFile.lastIndexOf("/"))
    : ".";
  options.apiLogFile = `${directory}/api.log`;
}
if (options.savesLogFile === "") {
  const directory = options.logFile.includes("/")
    ? options.logFile.slice(0, options.logFile.lastIndexOf("/"))
    : ".";
  options.savesLogFile = `${directory}/saves.jsonl`;
}

// ---------- logging ----------

function log(line: string): void {
  const stamped = `${new Date().toISOString()} ${line}`;
  console.log(stamped);
  try {
    appendFileSync(options.logFile, `${stamped}\n`);
  } catch (error) {
    console.error(`log write failed: ${error}`);
  }
}

// ---------- protocol helpers ----------

function encodeVarint(value: number): number[] {
  const out: number[] = [];
  let v = value >>> 0;
  while (v >= 0x80) {
    out.push((v & 0x7f) | 0x80);
    v >>>= 7;
  }
  out.push(v);
  return out;
}

function markerFieldBytes(fieldNumber: number): Uint8Array {
  const tag = encodeVarint((fieldNumber << 3) | 2);
  const text = new TextEncoder().encode(MARKER_TEXT);
  return new Uint8Array([...tag, text.length, ...text]);
}

function sha256Prefix(bytes: Uint8Array): string {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(bytes);
  return hasher.digest("hex").slice(0, 16);
}

// ---------- payload decoding (structure + recommendations) ----------
// Generic protobuf wire inspection: no compiled schema. Lenient walk — any
// segment that is not valid wire format is skipped in place (YouTube payloads
// contain opaque binary blobs, so strict whole-tree parsing dies early).
// Extracts recommendation entries: videoIds paired with the nearest human-text
// title in the same subtree, plus top-level field numbers per page.

interface Item {
  id: string;
  title: string;
  shorts: boolean;
  playlist: boolean;
  structured: boolean; // produced by a recognized card/shelf-item extractor
  section: string;     // nearest shelf heading, when the payload has one
  depth: number;       // pairing depth (generic pairs only; structure wins outright)
}

interface Subtree {
  ids: { id: string; shorts: boolean }[];
  titles: string[];
  items: Item[];
}

// Per-decode field budget (replaces shared mutable state; the server is threaded).
interface Budget {
  count: number;
}

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
// Dictionary-shaped 11-char words ("Downloading", "Unsubscribe") are UI labels,
// not video ids: real ids are base64url noise, never a single camel word.
const WORD_LIKE = /^[A-Z]?[a-z]+$|^[A-Z][a-z]+[A-Z][a-z]+$/;
const BROWSE_ID_LIKE = /^FE[A-Za-z0-9_-]*$/;
const TOKEN_LIKE = /^[A-Za-z0-9+/_=-]{24,}$/;
const IDENTIFIER_LIKE = /^[a-z0-9._-]+$/;
const UI_PHRASE =
  /^(unsubscribe|subscribe|share|download|like|likes|save|save to playlist|play all|expand description|loading…?|description|transcript|more|next|previous|settings|report|not interested|send feedback|don't recommend channel|save to watch later|add to queue|play next in queue|play last in queue|open in browser|action menu|more actions|video removed|undo|dismiss|innertube|up next|audio track|remix|auto-dubbed|transcripts track selection|play on different device|show fewer shorts|got it, we'll show you fewer shorts on home|change video\?|this will change the video for everyone in this call\.|want to start a shareplay of your own\?|get shareplay with youtube premium|you don't have access to shareplay yet|we're testing shareplay with a small group of people\.|learn more\.|got it\. we'll tune your recommendations\.)$/i;
const UI_PREFIX =
  /^(go to channel|stop downloading|like this video|dislike this video|unsubscribe from|save to|share this|add to|removed from|added to|tap to watch live)/i;
const utf8 = new TextDecoder("utf-8", { fatal: true });

function decodeBase64UrlToken(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]{6,}$/.test(text)) return null;
  try {
    const padded = text + "=".repeat((4 - (text.length % 4)) % 4);
    const binary = atob(padded.replace(/-/g, "+").replace(/_/g, "/"));
    const out = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index++) out[index] = binary.charCodeAt(index);
    return out;
  } catch {
    return null;
  }
}

function looksLikeEncodedProtoToken(text: string): boolean {
  const decoded = decodeBase64UrlToken(text);
  if (decoded === null || decoded.length < 2) return false;
  const fields = parseWireMessage(decoded);
  return fields !== null && fields.length > 0;
}

const MAX_DEPTH = 40;
const MAX_FIELDS = 300_000;

function looksLikeTitle(text: string): boolean {
  if (text.length < 3 || text.length > 300) return false;
  if (VIDEO_ID.test(text) || TOKEN_LIKE.test(text)) return false;
  if (BROWSE_ID_LIKE.test(text)) return false; // FEwhat_to_watch and friends
  if (looksLikeEncodedProtoToken(text)) return false; // params/continuation tokens
  if (/^https?:\/\//i.test(text)) return false;
  if (IDENTIFIER_LIKE.test(text)) return false; // context keys, client labels
  if (UI_PHRASE.test(text.trim())) return false;
  if (UI_PREFIX.test(text)) return false; // button/accessibility sentences
  // Metadata/byline rows ("CTV News 3.9K 48 min ago", "... views ... ago").
  if (/\b\d+(?:\.\d+)?\s*[KMB]?\s*views?\b/i.test(text)) return false;
  if (/\b\d+\s*(?:s|sec(?:ond)?s?|m|min(?:ute)?s?|h|hrs?|hours?|d|days?|w|weeks?|mo|months?|y|years?)\s+ago\b/i.test(text)) return false;
  // Long mixed-case+digit base64ish tokens ("YADIAQCQAgG6BQQSAmVu") are ids,
  // not titles; real single-word titles carry no digits/underscore mix.
  if (text.length >= 16 && !/ /.test(text) && /[A-Z]/.test(text) && /[a-z]/.test(text) && /[0-9_-]/.test(text))
    return false;
  if (!/\p{L}/u.test(text)) return false;
  // Numeric-looking strings: reject actual stat/duration shapes, not titles
  // that legitimately start with a number ("4 Signs The Monad…").
  if (/^\d{1,2}:\d{2}(?::\d{2})?$/.test(text)) return false; // "23:04"
  // Duration phrases only when they make up the whole string ("23 minutes, 4
  // seconds" / "42 minutes"), not titles beginning with a number ("1 Hour ASMR…").
  if (/^\d+\s*(?:minutes?|seconds?|hours?|mins?|secs?)\s*(?:,|$)/i.test(text)) return false;
  if (/^\d+\s*(?:minutes?|seconds?|hours?)\s+\d+\s*(?:minutes?|seconds?)$/i.test(text)) return false;
  if (/^\d+(?:\.\d+)?\s*[KMB]?\s*(?:views?|subscribers?|likes?)\b/i.test(text)) return false;
  if (/^\d+\s*(?:s|sec(?:ond)?s?|m|min(?:ute)?s?|h|hrs?|hours?|d|days?|w|weeks?|mo|months?|y|years?)\s+ago\b/i.test(text)) return false;
  if (!/ /.test(text)) {
    // Single-token titles must look like words: no URL/scheme punctuation,
    // not tiny, first letter uppercase.
    if (text.length <= 4) return false;
    if (/[.|/%:=<>#~^]/.test(text)) return false;
    if (!/^\p{Lu}/u.test(text)) return false;
  }
  return true;
}

// Renderer names that identify Shorts cards (they appear as feature markers in
// the payload bytes; protobuf itself encodes renderers as field numbers).
const SHORTS_MARKER_NAMES = [
  "shortsLockupViewModel",
  "reelItemRenderer",
  "shortsShelfRenderer",
  "shortsLockupRenderer",
  "reelWatchEndpoint",
];

// Cheap pre-filter needles so the full marker list only runs on plausible
// segments (a payload has tens of thousands of messages).
const SHORTS_PREFILTERS = [new TextEncoder().encode("horts"), new TextEncoder().encode("eel")];

function indexOfBytes(haystack: Uint8Array, needle: Uint8Array, from: number): number {
  if (needle.length === 0) return -1;
  const limit = haystack.length - needle.length;
  outer: for (let i = Math.max(0, from); i <= limit; i++) {
    for (let j = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

function segmentHasShortsMarker(segment: Uint8Array): boolean {
  let plausible = false;
  for (const needle of SHORTS_PREFILTERS) {
    if (indexOfBytes(segment, needle, 0) !== -1) { plausible = true; break; }
  }
  if (!plausible) return false;
  for (const name of SHORTS_MARKER_NAMES) {
    if (indexOfBytes(segment, new TextEncoder().encode(name), 0) !== -1) return true;
  }
  return false;
}

// Classify a printable segment as a leaf string. VideoIds inherit the Shorts
// flag of their enclosing subtree: the marker names live inside the Shorts
// card message, so anything found within that card is Shorts content.
function classifyLeaf(text: string, out: Subtree, shorts: boolean): void {
  if (VIDEO_ID.test(text) && !WORD_LIKE.test(text)) out.ids.push({ id: text, shorts });
  else if (looksLikeTitle(text)) out.titles.push(text);
}

// Pair leftover ids with the best remaining title at this level. Within one
// renderer subtree the videoId and its title text are siblings, so pairing
// per-subtree (instead of positionally across the whole page) is what keeps
// titles attached to the right video; longest title wins when several
// candidates share a subtree.
function pairLocal(subtree: Subtree, depth: number): void {
  // The same id can appear twice inside one renderer (nav data + playback
  // metadata); keeping both makes the extra copy bubble to an ancestor and
  // pair with unrelated UI labels ("Latest", "Popular").
  const seen = new Set<string>();
  subtree.ids = subtree.ids.filter((entry) => {
    if (seen.has(entry.id)) return false;
    seen.add(entry.id);
    return true;
  });
  while (subtree.ids.length > 0 && subtree.titles.length > 0) {
    const entry = subtree.ids.shift()!;
    // First title wins at this level: inside a renderer subtree the title
    // field precedes channel names and metadata labels, so the earliest
    // candidate is the most likely to be the video's own title. Pairing depth
    // is recorded so the final dedupe can prefer shallower (card-level) pairs
    // over accidental pairs formed deep inside navigation/menu subtrees.
    const title = subtree.titles.shift()!;
    subtree.items.push({ id: entry.id, title, shorts: entry.shorts, playlist: false, structured: false, section: "", depth });
  }
}

function emptySubtree(): Subtree {
  return { ids: [], titles: [], items: [] };
}

function mergeChild(local: Subtree, child: Subtree): void {
  local.items.push(...child.items);
  local.ids.push(...child.ids);
  local.titles.push(...child.titles);
}

// Walks one buffer as a protobuf message; returns this subtree's ids, titles,
// and paired items. Lenient: any malformation stops that segment's walk, so a
// bad segment never poisons its siblings (YouTube payloads contain opaque
// binary blobs that merely look like fields).
const STRUCTURE_FIELDS = new Set([1, 2, 3, 5, 6, 7, 17, 519005951, 79857908]);

// Structural metadata containers (verified): byline rows ("Channel 70K 6d ago"
// / "Canal 70 mil vistas hace 6 días"), view/post-time rows, menu text. Titles
// never live inside them, in any locale, so their strings are never candidates.
const METADATA_CONTAINER_FIELDS = new Set([514549827, 75730170, 78882851]); // byline rows, menus/stats, player overlays

function walkMessage(bytes: Uint8Array, depth: number, budget: Budget,
                     shorts: boolean, section: string, metadata: boolean,
                     parentField: number, contextPath: number[],
                     page: PageContextAccumulator): Subtree {
  const local = emptySubtree();
  if (depth > MAX_DEPTH) return local;
  const directStrings = new Map<number, string>();
  const childSegments = new Map<number, Uint8Array[]>();
  let pendingSection = section;
  let i = 0;
  while (i < bytes.length) {
    if (++budget.count > MAX_FIELDS) { pairLocal(local, depth); return local; }
    const key = readVarintAt(bytes, i);
    if (key === null) break;
    i = key.next;
    const field = Number(key.value >> 3n);
    const wire = Number(key.value & 7n);
    if (field === 0 || field > 536_870_911) break;
    if (wire === 0) {
      const value = readVarintAt(bytes, i);
      if (value === null) break;
      i = value.next;
    } else if (wire === 1) {
      if (i + 8 > bytes.length) break;
      i += 8;
    } else if (wire === 5) {
      if (i + 4 > bytes.length) break;
      i += 4;
    } else if (wire === 2) {
      const len = readVarintAt(bytes, i);
      if (len === null) break;
      i = len.next;
      const end = i + Number(len.value);
      if (end > bytes.length) break;
      const segment = bytes.slice(i, end);
      i = end;
      const text = tryDecodeText(segment);
      if (text !== undefined) {
        contextPath.push(field);
        collectPageText(page, contextPath, text, metadata);
        contextPath.pop();
        if (metadata) continue; // byline/stat/menu text: never a title candidate
        if (!directStrings.has(field)) directStrings.set(field, text);
        classifyLeaf(text, local, shorts);
        continue;
      }
      if (STRUCTURE_FIELDS.has(field)) {
        const list = childSegments.get(field) ?? [];
        list.push(segment);
        childSegments.set(field, list);
      }
      // The shelf header precedes its cards in wire order; pick up its heading
      // so every card below is stamped with the section it belongs to.
      if (field === 1 && pendingSection.length === 0) {
        const heading = shelfHeading([segment]);
        if (heading !== undefined) pendingSection = heading;
      }
      // Live-preview blocks live at media(f1) -> f23: "Tap to watch live" plus a
      // preview video id that is not a recommendation.
      const suppressed = metadata || METADATA_CONTAINER_FIELDS.has(field) ||
        (field === 23 && parentField === 1);
      contextPath.push(field);
      mergeChild(local, walkMessage(segment, depth + 1, budget,
                                    shorts || segmentHasShortsMarker(segment), pendingSection,
                                    suppressed, field, contextPath, page));
      contextPath.pop();
    } else {
      break; // groups (3/4) are not emitted by modern protobuf
    }
  }
  // Recognized card/shelf-item structures are consumed whole: their menu,
  // accessibility and byline strings must not become title candidates.
  const structure = detectStructure(directStrings, childSegments, depth, pendingSection);
  if (process.env.YTRC_DEBUG_STRUCT && (directStrings.get(7) !== undefined || directStrings.get(1) !== undefined || childSegments.get(519005951) !== undefined)) {
    console.log(`DBG depth=${depth} section=${JSON.stringify(pendingSection)} f1=${JSON.stringify(directStrings.get(1))} f6=${JSON.stringify(directStrings.get(6))} f7=${JSON.stringify(directStrings.get(7))} shortsChild=${childSegments.get(519005951) !== undefined} match=${structure !== null ? "YES" : "no"}`);
  }
  if (structure !== null) {
    const consumed = emptySubtree();
    consumed.items.push(structure.item);
    return consumed;
  }
  // Legacy shelf shape: direct title at field 1 with the item list at field 5
  // (shelfRenderer). Stamp the items it produced with that title.
  if (section.length === 0 && childSegments.get(5) !== undefined && local.items.length > 0) {
    const legacyTitle = directStrings.get(1);
    if (legacyTitle !== undefined && looksLikeTitle(legacyTitle)) {
      for (const item of local.items) {
        if (item.section.length === 0) item.section = legacyTitle;
      }
    }
  }
  pairLocal(local, depth);
  return local;
}

// ---------- recurring structure extractors ----------
// Verified against a real 21.33.6 Home payload (docs/ytprotocol.md):
//   lockup card:  f6 "//www.youtube.com/watch?v=<id>", f7 id, title at f1>f2>f1,
//                 byline/channel at f6>…>48687757>f36/f37, menus elsewhere.
//   shorts item:  wrapper child field 519005951; id deep inside, NO title text
//                 in the browse payload (thumbnails + menus only).
//   compact card: legacy compactVideoRenderer — id=1, title=3.
// When one of these matches, the subtree is consumed as a single item so menu,
// accessibility and byline strings can never be mistaken for titles.

function firstVideoIdIn(segment: Uint8Array, depth = 0): string | undefined {
  if (depth > 12) return undefined;
  const fields = parseWireMessage(segment);
  if (fields === null) return undefined;
  for (const f of fields) {
    if (f.wire !== 2 || f.bytes === undefined) continue;
    const text = tryDecodeText(f.bytes);
    if (text !== undefined) {
      if (VIDEO_ID.test(text) && !WORD_LIKE.test(text)) return text;
      continue;
    }
    const nested = firstVideoIdIn(f.bytes, depth + 1);
    if (nested !== undefined) return nested;
  }
  return undefined;
}

function firstTitleIn(segment: Uint8Array, depth = 0): string | undefined {
  if (depth > 8) return undefined;
  const fields = parseWireMessage(segment);
  if (fields === null) return undefined;
  for (const f of fields) {
    if (f.wire !== 2 || f.bytes === undefined) continue;
    const text = tryDecodeText(f.bytes);
    if (text !== undefined) {
      if (looksLikeTitle(text)) return text;
      continue;
    }
    const nested = firstTitleIn(f.bytes, depth + 1);
    if (nested !== undefined) return nested;
  }
  return undefined;
}

function nestedText(segment: Uint8Array | undefined, path: number[]): string | undefined {
  let current = segment;
  for (const want of path) {
    if (current === undefined) return undefined;
    const fields = parseWireMessage(current);
    if (fields === null) return undefined;
    const next = fields.find((f) => f.field === want && f.wire === 2);
    current = next?.bytes;
  }
  return current !== undefined ? tryDecodeText(current) : undefined;
}

function nestedFirstTitle(segment: Uint8Array | undefined, path: number[]): string | undefined {
  let current = segment;
  for (const want of path) {
    if (current === undefined) return undefined;
    const fields = parseWireMessage(current);
    if (fields === null) return undefined;
    const next = fields.find((f) => f.field === want && f.wire === 2);
    current = next?.bytes;
  }
  if (current === undefined) return undefined;
  const text = tryDecodeText(current);
  // Structural title fields are language-independent: accept any non-empty text.
  return text !== undefined && text.trim().length > 0 ? text : undefined;
}

interface StructureMatch {
  item: Item;
  consumed: boolean;
}

// Inspects the direct fields of one message for the known card patterns.
function detectStructure(directStrings: Map<number, string>,
                         childSegments: Map<number, Uint8Array[]>,
                         depth: number, section: string): StructureMatch | null {
  // Compact Shorts shelf item, used on channel/tab pages (verified: item.f1 =
  // "shorts-shelf-item-<id>", accessibility at f4 =
  // "<title>, <stats> - play Short", inner video id at f6>…>139608561>f1,
  // views at f22>f2>f1). The accessibility string is the only plain-text title
  // in this variant; its trailing play label and stats segment are UI chrome.
  const compactShorts = directStrings.get(1);
  if (compactShorts !== undefined) {
    const marker = /^shorts-shelf-item-([A-Za-z0-9_-]{11})$/.exec(compactShorts);
    if (marker !== null && VIDEO_ID.test(marker[1]) && !WORD_LIKE.test(marker[1])) {
      const a11y = directStrings.get(4) ?? "";
      let title = a11y.trim();
      const dash = title.lastIndexOf(" - ");
      // Localized play labels are short and never contain digits.
      if (dash > 0) {
        const tail = title.slice(dash + 3).trim();
        if (tail.length > 0 && tail.length <= 40 && !/\d/.test(tail)) title = title.slice(0, dash);
      }
      const comma = title.lastIndexOf(",");
      // The accessibility line appends the localized view count; it carries
      // digits plus a unit word (never sentence punctuation). Requiring a
      // letter keeps a title ending in a year ("…, 2024") intact.
      if (comma > 0) {
        const tail = title.slice(comma + 1).trim();
        if (/\d/.test(tail) && /\p{L}/u.test(tail) && !/[.!?]$/.test(tail)) title = title.slice(0, comma);
      }
      return { consumed: true, item: { id: marker[1], title: title.trim(), shorts: true, playlist: false, structured: true, section, depth } };
    }
  }
  // Shorts shelf item wrapper (verified: 519005951 -> f17 item, id deep inside,
  // title at item.f22.f1.f1, accessibility "«title» - play Short" at item.f4).
  const shorts = childSegments.get(519005951);
  if (shorts !== undefined && shorts.length > 0) {
    const wrapper = shorts[shorts.length - 1];
    const id = firstVideoIdIn(wrapper);
    if (id !== undefined) {
      const wrapperFields = parseWireMessage(wrapper);
      const itemSegment = wrapperFields?.find((f) => f.field === 17 && f.wire === 2)?.bytes;
      let title = nestedText(itemSegment, [22, 1, 1]) ?? "";
      if (title.length === 0) {
        const a11y = nestedText(itemSegment, [4]) ?? "";
        title = a11y.replace(/\s*-\s*play Short$/i, "").trim();
      }
      return { consumed: true, item: { id, title, shorts: true, playlist: false, structured: true, section, depth } };
    }
  }
  // Modern lockup card: id at f7 with the canonical watch URL at f6.
  const id = directStrings.get(7);
  const url = directStrings.get(6);
  if (id !== undefined && VIDEO_ID.test(id) && !WORD_LIKE.test(id) &&
      url !== undefined && url.endsWith(`watch?v=${id}`)) {
    // Lockup title: card.f2 (metadata).f1 (title text). Verified on the real
    // payload; card.f1 is the media block whose f2 is the duration string.
    const metadata = childSegments.get(2)?.[0];
    let title = nestedFirstTitle(metadata, [1]) ?? "";
    if (title.length === 0 && metadata !== undefined) title = firstTitleIn(metadata) ?? "";
    return { consumed: true, item: { id, title, shorts: false, playlist: false, structured: true, section, depth } };
  }
  // Playlist card (verified): direct f6 = "…/playlist?list=…"; title inside the
  // media block at f21 -> 8178 -> f1 -> f1; the "8 videos" count at media.f1.f6
  // is metadata, never a title.
  const mediaForPlaylist = childSegments.get(1)?.[0];
  const mediaFields = mediaForPlaylist !== undefined ? parseWireMessage(mediaForPlaylist) : null;
  const playlistLink = mediaFields?.find((f) => f.field === 6 && f.wire === 2)?.bytes;
  const playlistUrl = playlistLink !== undefined ? tryDecodeText(playlistLink) : undefined;
  if (playlistUrl !== undefined && playlistUrl.includes("/playlist?list=")) {
    const media = mediaForPlaylist;
    const id = firstVideoIdIn(media ?? directStrings.get(6) ?? new Uint8Array());
    if (id !== undefined) {
      const title = nestedText(media, [21, 8178, 1, 1]) ??
        nestedText(media, [21, 8178, 1]) ?? "";
      return { consumed: true, item: { id, title: title.trim(), shorts: false, playlist: true, structured: true, section, depth } };
    }
  }
  // Watch-related card variant (verified: 232954548 -> 18 entries): the id,
  // title and channel sit together in the navData node — field 1 id,
  // field 36 title, field 37 channel. Recognize it as a unit so the channel
  // can never be mistaken for the title.
  // Structural title field: trusted as-is in any language/locale (only empty
  // strings and encoded protobuf params are excluded).
  const navId = directStrings.get(1);
  const navTitle = directStrings.get(36);
  if (navId !== undefined && VIDEO_ID.test(navId) && !WORD_LIKE.test(navId) &&
      navTitle !== undefined && navTitle.trim().length > 0 &&
      !looksLikeEncodedProtoToken(navTitle)) {
    return { consumed: true, item: { id: navId, title: navTitle, shorts: false, playlist: false, structured: true, section, depth } };
  }
  // Legacy compactVideoRenderer: id=1, title=3.
  const compactId = directStrings.get(1);
  if (compactId !== undefined && VIDEO_ID.test(compactId) && !WORD_LIKE.test(compactId) &&
      childSegments.get(2) !== undefined && childSegments.get(3) !== undefined) {
    const title = firstTitleIn(childSegments.get(3)![0]) ?? "";
    return { consumed: true, item: { id: compactId, title, shorts: false, playlist: false, structured: true, section, depth } };
  }
  // Shorts reel sequence item (verified on /yt-reels): f1 is the video id and
  // f53 is a playback UUID; the payload carries NO plain-text titles anywhere,
  // so the item is still surfaced by id. Titles for these arrive with the
  // per-item reel watch response, not the sequence batch.
  const reelId = directStrings.get(1);
  const reelUuid = directStrings.get(53);
  if (reelId !== undefined && VIDEO_ID.test(reelId) && !WORD_LIKE.test(reelId) &&
      reelUuid !== undefined && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(reelUuid) &&
      childSegments.get(79857908) !== undefined) {
    return { consumed: true, item: { id: reelId, title: "", shorts: true, playlist: false, structured: true, section, depth } };
  }
  return null;
}

// Modern shelf header: entry.f1 is the header message whose field 20 is the
// heading text ("Breaking news"). Verified against the real Home payload.
function shelfHeading(segments: Uint8Array[] | undefined): string | undefined {
  const header = segments?.[0];
  if (header === undefined) return undefined;
  const fields = parseWireMessage(header);
  if (fields === null) return undefined;
  const headingField = fields.find((f) => f.field === 20 && f.wire === 2);
  if (headingField === undefined) return undefined;
  const text = tryDecodeText(headingField.bytes!);
  return text !== undefined && looksLikeTitle(text) ? text : undefined;
}

function tryDecodeText(segment: Uint8Array): string | undefined {
  try {
    const decoded = utf8.decode(segment);
    if (!/[\u0000-\u001f]/.test(decoded)) return decoded;
  } catch {
    // not UTF-8
  }
  return undefined;
}

// Category chip bar (Home payloads only): 213380311 -> f1 -> repeated chips
// (91394224), each chip title at f2.f1.f1 and f9 = varint 1 when selected.
function findSelectedChipTitle(fields: WireField[], depth = 0): string | undefined {
  if (depth > MAX_DEPTH) return undefined;
  for (const f of fields) {
    if (f.wire !== 2 || f.bytes === undefined) continue;
    if (f.field === 213380311) {
      const strip = parseWireMessage(f.bytes);
      if (strip !== null) {
        const container = nestedText(f.bytes, [1]); // sanity: container exists
        void container;
        const chips: WireField[] = [];
        for (const sf of strip) {
          if (sf.wire === 2 && sf.bytes !== undefined) {
            const inner = parseWireMessage(sf.bytes);
            if (inner !== null) chips.push(...inner.filter((x) => x.field === 91394224 && x.wire === 2));
          }
        }
        for (const chip of chips) {
          const chipFields = parseWireMessage(chip.bytes!);
          if (chipFields === null) continue;
          const selected = chipFields.some((cf) => cf.field === 9 && cf.wire === 0 && cf.varint === 1n);
          if (!selected) continue;
          // Chip titles are structural (they include short labels like "All"),
          // so no prose heuristics apply here.
          const title = nestedText(chip.bytes, [2, 1, 1]);
          if (title !== undefined && title.trim().length > 0) return title.trim();
        }
      }
    }
    const child = parseWireMessage(f.bytes);
    if (child !== null) {
      const found = findSelectedChipTitle(child, depth + 1);
      if (found !== undefined) return found;
    }
  }
  return undefined;
}

function findSearchQuery(payload: Uint8Array): string | undefined {
  const counts = new Map<string, number>();
  const visit = (bytes: Uint8Array, depth: number): void => {
    if (depth > MAX_DEPTH) return;
    const fields = parseWireMessage(bytes);
    if (fields === null) return;
    for (const f of fields) {
      if (f.wire !== 2 || f.bytes === undefined) continue;
      if (f.field === 48687709) {
        const endpoint = parseWireMessage(f.bytes);
        const candidates = endpoint?.filter((x) =>
          (x.field === 1 || x.field === 14) && x.wire === 2) ?? [];
        for (const candidate of candidates) {
          const text = tryDecodeText(candidate.bytes!);
          if (text !== undefined && text.trim().length > 0 && text.length <= 200) {
            counts.set(text, (counts.get(text) ?? 0) + 1);
          }
        }
      }
      visit(f.bytes, depth + 1);
    }
  };
  visit(payload, 0);
  let best: string | undefined;
  let bestCount = 0;
  for (const [text, count] of counts) {
    if (count > bestCount) { best = text; bestCount = count; }
  }
  return best;
}

function decodePayload(payload: Uint8Array, surface: string): {
  fields: number[]; items: Item[]; page: PageContext; feed?: string; query?: string;
} | null {
  const budget: Budget = { count: 0 };
  const topFields: number[] = [];
  const result = emptySubtree();
  const page = emptyPageContext();
  let i = 0;
  let valid = true;
  while (i < payload.length) {
    if (++budget.count > MAX_FIELDS) { valid = false; break; }
    const key = readVarintAt(payload, i);
    if (key === null) { valid = false; break; }
    i = key.next;
    const field = Number(key.value >> 3n);
    const wire = Number(key.value & 7n);
    if (field === 0) { valid = false; break; }
    topFields.push(field);
    if (wire === 0) {
      const value = readVarintAt(payload, i);
      if (value === null) { valid = false; break; }
      i = value.next;
    } else if (wire === 1) {
      if (i + 8 > payload.length) { valid = false; break; }
      i += 8;
    } else if (wire === 5) {
      if (i + 4 > payload.length) { valid = false; break; }
      i += 4;
    } else if (wire === 2) {
      const len = readVarintAt(payload, i);
      if (len === null) { valid = false; break; }
      i = len.next;
      const end = i + Number(len.value);
      if (end > payload.length) { valid = false; break; }
      const segment = payload.slice(i, end);
      i = end;
      if (field === 777) continue; // frameworkUpdates: entity mutation noise, not recommendations
      const text = tryDecodeText(segment);
      if (text !== undefined) {
        collectPageText(page, [field], text, false);
        classifyLeaf(text, result, false);
        continue;
      }
      // Top-level field 25 = engagement panels (transcript/comments/chapters):
      // UI chrome plus font-style blocks, never recommendations.
      const suppressedTop = METADATA_CONTAINER_FIELDS.has(field) || field === 25;
      mergeChild(result, walkMessage(segment, 1, budget, segmentHasShortsMarker(segment), "",
                                     suppressedTop, field, [field], page));
    } else {
      valid = false;
      break;
    }
  }
  if (!valid && topFields.length === 0) return null;
  pairLocal(result, 0);
  // Dedupe by id: prefer the shallowest (most card-local) pair; ties keep the
  // first seen. Menu/nav subtrees produce deep accidental pairs (e.g. a
  // channel name next to a repeated videoId); card-level pairs win here.
  const seen = new Map<string, Item>();
  for (const item of result.items) {
    if (!item.structured && !item.title) continue;
    const existing = seen.get(item.id);
    if (existing === undefined) {
      seen.set(item.id, item);
      continue;
    }
    // Structure-extracted cards beat generic pairs outright (generic pairs
    // often use a channel name or menu string); between equals the shallower
    // pairing wins.
    const better = item.structured !== existing.structured
      ? item.structured
      : item.depth < existing.depth;
    if (better) {
      item.section = item.section || existing.section;
      item.shorts = item.shorts || existing.shorts;
      item.playlist = item.playlist || existing.playlist;
      seen.set(item.id, item);
    } else {
      existing.section = existing.section || item.section;
      existing.shorts = existing.shorts || item.shorts;
      existing.playlist = existing.playlist || item.playlist;
    }
  }
  const items = [...seen.values()];
  // Shorts shelf cards often carry no title at all (only thumbnails and menu
  // labels). Report those ids explicitly rather than dropping them or pairing
  // them with a menu string.
  for (const entry of result.ids) {
    if (entry.shorts && !seen.has(entry.id)) {
      items.push({ id: entry.id, title: "", shorts: true, playlist: false, structured: false, section: "", depth: 0 });
    }
  }
  const feed = findSelectedChipTitle(parseWireMessage(payload) ?? []);
  const query = findSearchQuery(payload);
  return {
    fields: [...new Set(topFields)],
    items,
    page: buildPageContext(page, surface),
    ...(feed !== undefined ? { feed } : {}),
    ...(query !== undefined ? { query } : {}),
  };
}

function rendererMarkers(payload: Uint8Array): Map<string, number> {
  const encoder = new TextEncoder();
  const counts = new Map<string, number>();
  for (const name of SHORTS_MARKER_NAMES) {
    const needle = encoder.encode(name);
    let index = indexOfBytes(payload, needle, 0);
    let count = 0;
    while (index !== -1) {
      count++;
      index = indexOfBytes(payload, needle, index + 1);
    }
    if (count > 0) counts.set("shorts", (counts.get("shorts") ?? 0) + count);
  }
  return counts;
}

function clipText(text: string, max = 80): string {
  const trimmed = text.trim().replace(/\s+/g, " ");
  return trimmed.length > max ? `${trimmed.slice(0, max)}…(${trimmed.length})` : trimmed;
}

function formatTextList(items: string[]): string {
  return `[${items.map((item) => `«${clipText(item, 60)}»`).join(", ")}]`;
}

interface WireDescription {
  fields: number[];
  strings: string[];
}

// Bounded, lenient summary of a protobuf message: top-level field numbers plus
// the first printable text leaves. Used for request-side context (the request
// message itself and its base64url continuation/params tokens).
function describeWire(bytes: Uint8Array, maxStrings = 20): WireDescription | null {
  const fields = parseWireMessage(bytes);
  if (fields === null) return null;
  const strings: string[] = [];
  const seen = new Set<string>();
  const budget = { count: 0 };
  const visit = (segment: Uint8Array, depth: number): void => {
    if (depth > 20 || strings.length >= maxStrings || budget.count > 20_000) return;
    const children = parseWireMessage(segment);
    if (children === null) return;
    for (const field of children) {
      if (++budget.count > 20_000 || strings.length >= maxStrings) return;
      if (field.wire !== 2 || field.bytes === undefined) continue;
      const text = tryDecodeText(field.bytes);
      if (text !== undefined) {
        const value = text.trim();
        if (value.length >= 2 && !seen.has(value)) {
          seen.add(value);
          strings.push(value);
        }
      } else {
        visit(field.bytes, depth + 1);
      }
    }
  };
  visit(bytes, 0);
  return { fields: [...new Set(fields.map((field) => field.field))], strings };
}

function describeToken(label: string, token: string): string {
  const bytes = decodeBase64UrlToken(token);
  if (bytes === null) return `${label}=«${clipText(token, 32)}» (not base64url, ${token.length} chars)`;
  const described = describeWire(bytes, 8);
  if (described === null)
    return `${label}=«${clipText(token, 32)}» (${bytes.length}B, not protobuf)`;
  return `${label}=«${clipText(token, 32)}» (${bytes.length}B fields=[${described.fields.join(",")}]` +
    (described.strings.length > 0 ? ` strings=${formatTextList(described.strings)}` : "") + `)`;
}

// First line for one transform: endpoint + request id + transport metadata and
// the flat request fields, so the call is identifiable before any payload work.
function logIncoming(path: string, env: Envelope, auth: string | null): void {
  const parts = [
    `POST ${path}`,
    env.requestId,
    `auth=${auth ? "yes" : "no"}`,
    `surface=${env.surface}`,
    `phase=${env.phase}`,
    `type=${env.responseType}`,
    `yt=${env.youtubeVersion}`,
  ];
  if (env.videoId !== null) parts.push(`videoId=${env.videoId}`);
  parts.push(`in=${env.payload.length}B(${sha256Prefix(env.payload)})`);
  if (env.requestClass !== null) parts.push(`class=${env.requestClass}`);
  if (env.requestFields.browseId !== null) parts.push(`browseId=${env.requestFields.browseId}`);
  if (env.requestFields.query !== null) parts.push(`query=«${clipText(env.requestFields.query, 80)}»`);
  if (env.requestFields.feedType !== null) parts.push(`feedType=${env.requestFields.feedType}`);
  log(parts.join(" "));
}

// Second line(s): the serialized request message decoded (fields + printable
// strings), then the base64url continuation/params protobuf decoded. These add
// detail beyond the flat fields already shown on the incoming line.
function logRequestDetails(env: Envelope): void {
  if (!options.decode) return;
  if (env.requestPayload !== null) {
    const parts = [`bytes=${env.requestPayload.length}`];
    const described = describeWire(env.requestPayload);
    if (described !== null) {
      parts.push(`fields=[${described.fields.join(",")}]`);
      if (described.strings.length > 0) parts.push(`strings=${formatTextList(described.strings)}`);
    }
    log(`request: ${parts.join(" ")}`);
  }
  for (const [label, token] of [
    ["continuation", env.requestFields.continuation],
    ["params", env.requestFields.params],
  ] as const) {
    if (token !== null) log(`request-token: ${describeToken(label, token)}`);
  }
}

interface PageContext {
  channelName?: string;
  channelId?: string;
  handle?: string;
  description?: string;
  tabs: string[];
  hashtags: string[];
  handles: string[];
}

interface PageContextAccumulator {
  channelName?: string;
  channelDescription?: string;
  headerChannelId?: string;
  headerHandle?: string;
  tabs: Set<string>;
  hashtags: Set<string>;
  handles: Set<string>;
}

function emptyPageContext(): PageContextAccumulator {
  return { tabs: new Set(), hashtags: new Set(), handles: new Set() };
}

// Called for every printable leaf from the main decode walk (single pass, no
// second parse). Field-number paths keep shape checks locale-neutral. Channel
// header container 509923604 (name at f1, about at 524902670>f1) and channel
// tab renderer 58174010 (title at f2) are verified on a real 21.33.6 page;
// the surface already carries the channel id for channel pages.
function collectPageText(page: PageContextAccumulator, path: number[], text: string,
                         metadata: boolean): void {
  const count = path.length;
  const last = path[count - 1];
  const parent = path[count - 2];
  const trimmed = text.trim();
  if (parent === 509923604 && last === 1 && page.channelName === undefined) {
    page.channelName = trimmed;
  }
  if (path.includes(509923604)) {
    if (page.headerChannelId === undefined && /^UC[A-Za-z0-9_-]{22}$/.test(trimmed))
      page.headerChannelId = trimmed;
    if (page.headerHandle === undefined && /^\/@[\p{L}\p{N}._-]{2,40}$/u.test(trimmed))
      page.headerHandle = trimmed;
    if (parent === 1 && last === 1 && path.includes(524902670) &&
        page.channelDescription === undefined) {
      page.channelDescription = trimmed;
    }
  }
  if (parent === 58174010 && last === 2 && page.tabs.size < 12 &&
      trimmed.length > 0 && trimmed.length <= 40) {
    page.tabs.add(trimmed);
  }
  if (metadata) return; // byline/menu text never contributes topics
  if (text.includes("#") && page.hashtags.size < 12) {
    for (const tag of text.match(/#[\p{L}\p{N}_]{2,40}/gu) ?? []) {
      page.hashtags.add(tag);
      if (page.hashtags.size >= 12) break;
    }
  }
  if (text.includes("/@") && page.handles.size < 8) {
    for (const handle of text.match(/\/@[\p{L}\p{N}._-]{2,40}/gu) ?? []) {
      page.handles.add(handle);
      if (page.handles.size >= 8) break;
    }
  }
}

function buildPageContext(page: PageContextAccumulator, surface: string): PageContext {
  const channelId = /^UC[A-Za-z0-9_-]{22}$/.test(surface) ? surface : page.headerChannelId;
  return {
    ...(page.channelName !== undefined ? { channelName: page.channelName } : {}),
    ...(channelId !== undefined ? { channelId } : {}),
    ...(page.headerHandle !== undefined ? { handle: page.headerHandle } : {}),
    ...(page.channelDescription !== undefined ? { description: page.channelDescription } : {}),
    tabs: [...page.tabs],
    hashtags: [...page.hashtags],
    handles: [...page.handles],
  };
}

function logDecoded(payload: Uint8Array, endpoint: string, surface: string): void {
  if (!options.decode) return;
  const decoded = decodePayload(payload, surface);
  if (decoded === null) {
    log(`decoded: [${endpoint}] payload is not valid protobuf wire format (fields unavailable)`);
    return;
  }
  const markers = rendererMarkers(payload);
  const markerText = [...markers.entries()].map(([label, count]) => `${label}Markers=${count}`).join(" ");
  const sections = [...new Set(decoded.items.map((item) => item.section).filter((value) => value.length > 0))];
  const header = `decoded: [${endpoint}] top fields=[${decoded.fields.join(",")}]` +
    (decoded.feed !== undefined ? ` feed=«${decoded.feed}»` : "") +
    (decoded.query !== undefined ? ` query=«${decoded.query}»` : "") +
    ` recommendations=${decoded.items.length}` +
    (sections.length > 0 ? ` sections=${sections.length}` : "") +
    (markerText ? ` ${markerText}` : "");
  const page = decoded.page;
  const contextParts: string[] = [];
  if (page.channelName !== undefined) contextParts.push(`channel=«${clipText(page.channelName, 80)}»`);
  if (page.channelId !== undefined) contextParts.push(`channelId=${page.channelId}`);
  if (page.handle !== undefined) contextParts.push(`handle=${page.handle}`);
  if (page.description !== undefined) contextParts.push(`description=«${clipText(page.description, 120)}»`);
  if (page.tabs.length > 0) contextParts.push(`tabs=${formatTextList(page.tabs)}`);
  if (page.hashtags.length > 0) contextParts.push(`hashtags=[${page.hashtags.join(" ")}]`);
  if (page.handles.length > 0) contextParts.push(`handles=[${page.handles.join(" ")}]`);
  if (sections.length > 0) contextParts.push(`sections=${formatTextList(sections)}`);
  const items = decoded.items.slice(0, 20);
  const lines = [header];
  if (contextParts.length > 0) lines.push(`context: ${contextParts.join(" ")}`);
  let currentSection = "";
  for (const item of items) {
    if (item.section !== currentSection && item.section.length > 0) {
      lines.push(`    [${item.section}]`);
      currentSection = item.section;
    }
    const indent = item.section.length > 0 ? "      " : "    ";
    const label = item.title.length > 0 ? `«${item.title}»` : "(no title in payload)";
    const tags = (item.shorts ? " [shorts]" : "") + (item.playlist ? " [playlist]" : "");
    lines.push(`${indent}- ${item.id} ${label}${tags}`);
  }
  if (decoded.items.length > items.length)
    lines.push(`${currentSection.length > 0 ? "      " : "    "}… (+${decoded.items.length - items.length} more)`);
  log(lines.join("\n"));
}

function decodeStrictBase64(value: unknown): Uint8Array | null {
  if (typeof value !== "string" || value.length === 0) return null;
  const decoded = Buffer.from(value, "base64");
  // Canonical round trip: rejects non-base64 junk the way python's validate=True does.
  if (Buffer.from(decoded.toString("base64")).toString() !== value) return null;
  return new Uint8Array(decoded);
}

interface Envelope {
  requestId: string;
  surface: string;
  phase: string;
  responseType: string;
  youtubeVersion: string;
  videoId: string | null;
  requestClass: string | null;
  requestPayload: Uint8Array | null;
  requestFields: {
    browseId: string | null;
    continuation: string | null;
    params: string | null;
    query: string | null;
    feedType: number | null;
  };
  payload: Uint8Array;
}

function parseEnvelope(raw: string): { ok: true; envelope: Envelope } | { ok: false; error: string } {
  let body: unknown;
  try {
    body = JSON.parse(raw || "{}");
  } catch {
    return { ok: false, error: "body is not JSON" };
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) return { ok: false, error: "envelope is not a JSON object" };
  const envelope = body as Record<string, unknown>;
  if (envelope.protocolVersion !== 1) return { ok: false, error: "unsupported protocolVersion" };
  if (envelope.mode !== "transform") return { ok: false, error: "unsupported mode" };
  if (typeof envelope.requestId !== "string" || envelope.requestId.length === 0) return { ok: false, error: "missing requestId" };
  if (envelope.encoding !== "protobuf-base64") return { ok: false, error: "unsupported encoding" };
  const payload = decodeStrictBase64(envelope.payload);
  if (payload === null || payload.length === 0) return { ok: false, error: "payload is not valid non-empty base64" };
  const context = (typeof envelope.context === "object" && envelope.context !== null ? envelope.context : {}) as Record<string, unknown>;
  const contextString = (key: string, maxLength = 16_384): string | null => {
    const value = context[key];
    return typeof value === "string" && value.length > 0 && value.length <= maxLength ? value : null;
  };
  const rawRequestPayload = contextString("requestPayload", 2 * 1024 * 1024);
  return {
    ok: true,
    envelope: {
      requestId: envelope.requestId,
      surface: typeof envelope.surface === "string" ? envelope.surface : "-",
      phase: typeof envelope.phase === "string" ? envelope.phase : "-",
      responseType: typeof envelope.responseType === "string" ? envelope.responseType : "-",
      youtubeVersion: typeof envelope.youtubeVersion === "string" ? envelope.youtubeVersion : "-",
      videoId: surfaceHasVideo(envelope.surface) && typeof context.videoId === "string" &&
        /^[A-Za-z0-9_-]{11}$/.test(context.videoId) ? context.videoId : null,
      requestClass: contextString("requestClass", 200),
      requestPayload: rawRequestPayload !== null ? decodeStrictBase64(rawRequestPayload) : null,
      requestFields: {
        browseId: contextString("browseId", 4096),
        continuation: contextString("continuation"),
        params: contextString("params"),
        query: contextString("query", 4096),
        feedType: typeof context.feedType === "number" && Number.isFinite(context.feedType)
          ? context.feedType : null,
      },
      payload,
    },
  };
}

function surfaceHasVideo(surface: unknown): boolean {
  return surface === "watch";
}

// Raw request log (JSONL): the received envelope verbatim, including the
// base64 of the untouched original protobuf bytes (never compressed — this is
// the wire payload as YouTube delivered it). One replayable line per transform.
function logApi(env: Envelope, path: string): void {
  if (options.apiLogFile === null) return;
  const record = {
    time: new Date().toISOString(),
    endpoint: path,
    requestId: env.requestId,
    surface: env.surface,
    phase: env.phase,
    youtubeVersion: env.youtubeVersion,
    responseType: env.responseType,
    bytes: env.payload.length,
    sha256: sha256Prefix(env.payload),
    videoId: env.videoId,
    requestClass: env.requestClass,
    requestFields: env.requestFields,
    requestBytes: env.requestPayload !== null ? env.requestPayload.length : 0,
    ...(env.requestPayload !== null
      ? { requestPayload: Buffer.from(env.requestPayload).toString("base64") } : {}),
    payload: Buffer.from(env.payload).toString("base64"),
  };
  try {
    appendFileSync(options.apiLogFile, `${JSON.stringify(record)}\n`);
  } catch (error) {
    console.error(`api log write failed: ${error}`);
  }
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

interface ResponseMeta {
  action?: string;
  outBytes?: number;
}

// Per-response metadata for the single closing access line. A WeakMap keeps
// concurrent requests independent (no shared "current request" state).
const responseMeta = new WeakMap<Response, ResponseMeta>();

function metaJson(data: unknown, status: number, meta: ResponseMeta): Response {
  const response = json(data, status);
  responseMeta.set(response, meta);
  return response;
}

// Compact human size for the access line: 197087 -> "197k", 1656766 -> "1.7M".
function humanBytes(bytes: number): string {
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)}M`;
  if (bytes >= 1000) return `${Math.round(bytes / 1000)}k`;
  return `${bytes}B`;
}

// ---------- server state ----------

const state = { lastAuth: null as string | null, lastPath: null as string | null };

// Playback is inferred from fetch traffic: a /yt-next initial fetch happens when
// a video page opens (start), a second one with a different id is a switch, and
// a Home initial/refresh after a watch session implies the player was left.
// True "stop" actions (pause/close without another fetch) are not observable
// here — that would need a client-side playback hook.
let playback: { videoId: string | null } = { videoId: null };

function trackPlayback(path: string, env: Envelope): void {
  if (!options.inferPlayback) return; // client playback hooks are authoritative
  if (path === "/yt-next" && env.phase === "initial" && env.videoId !== null) {
    const previous = playback.videoId;
    if (previous === env.videoId) {
      log(`play: replay videoId=${env.videoId}`);
    } else if (previous === null) {
      log(`play: start videoId=${env.videoId}`);
    } else {
      log(`play: switch videoId=${env.videoId} previous=${previous}`);
    }
    playback.videoId = env.videoId;
    return;
  }
  if (path === "/yt-browse" && (env.phase === "initial" || env.phase === "refresh") &&
      playback.videoId !== null) {
    log(`play: leave videoId=${playback.videoId} (inferred from ${env.surface} ${env.phase})`);
    playback.videoId = null;
  }
}

// Client playback observations (observation-only hooks in the patch):
// {protocolVersion:1, type:"playback", requestId, event, videoId?, detail?}
async function handlePlayback(request: Request): Promise<Response> {
  let record: Record<string, unknown>;
  try {
    const parsed = JSON.parse(await request.text());
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
      throw new Error("not a JSON object");
    record = parsed as Record<string, unknown>;
  } catch (error) {
    log(`POST /yt-playback rejected: ${error}`);
    return json({ error: "invalid playback event body" }, 400);
  }
  if (record.protocolVersion !== 1 || typeof record.event !== "string" || record.event.length === 0) {
    log(`POST /yt-playback rejected: missing protocolVersion 1 or event`);
    return json({ error: "invalid playback event" }, 400);
  }
  const event = record.event;
  // No legacy or alternate event names: the client reports exactly these
  // three boundaries. Anything else is a protocol violation, not something to
  // translate or silently absorb.
  if (event !== "activate" && event !== "pause" && event !== "finish") {
    log(`POST /yt-playback rejected: unsupported event ${JSON.stringify(event)} ` +
        `(accepted: activate, pause, finish)`);
    return json({ error: "unsupported playback event; accepted events are activate, pause, finish" }, 400);
  }
  const videoId = typeof record.videoId === "string" && /^[A-Za-z0-9_-]{11}$/.test(record.videoId)
    ? record.videoId : null;
  const detail = typeof record.detail === "object" && record.detail !== null ? record.detail : {};
  if (event === "activate" && videoId !== null) playback.videoId = videoId;
  if (event === "pause" || event === "finish") {
    if (videoId !== null) playback.videoId = videoId;
  }
  log(`play(client): event=${event} videoId=${videoId ?? "-"} detail=${JSON.stringify(detail)}`);
  return json({ ok: true });
}

// Client save requests from the watch-page menu:
// {protocolVersion:1, type:"save", requestId, videoId, ai, youtubeVersion}
// Each accepted save is appended to the saves log (one JSON line per save).

// Generic readable-text extraction from a serialized YTITranscriptResponse:
// the segment texts are plain length-delimited strings inside nested
// transcript-segment messages; times are varints and never decode as text.
function extractTranscriptText(payload: Uint8Array, depth = 0): string[] {
  if (depth > 8) return [];
  const fields = parseWireMessage(payload);
  if (fields === null) return [];
  const out: string[] = [];
  for (const f of fields) {
    if (f.wire !== 2 || f.bytes === undefined) continue;
    const text = tryDecodeText(f.bytes);
    if (text !== undefined && text.length >= 2) {
      out.push(text);
      continue;
    }
    out.push(...extractTranscriptText(f.bytes, depth + 1));
    if (out.length > 20000) break;
  }
  return out;
}

// Readable text from a YouTube json3 caption payload: events[].segs[].utf8
// concatenated per event, one line per event (the format the app fetches
// with fmt=json3 from a caption track's signed baseUrl).
function extractJson3Text(bytes: Uint8Array): string | null {
  let root: unknown;
  try {
    root = JSON.parse(Buffer.from(bytes).toString("utf8"));
  } catch {
    return null;
  }
  if (typeof root !== "object" || root === null) return null;
  const events = (root as { events?: unknown }).events;
  if (!Array.isArray(events)) return null;
  const lines: string[] = [];
  for (const event of events) {
    if (typeof event !== "object" || event === null) continue;
    const segs = (event as { segs?: unknown }).segs;
    if (!Array.isArray(segs)) continue;
    let line = "";
    for (const seg of segs) {
      if (typeof seg === "object" && seg !== null && typeof (seg as { utf8?: unknown }).utf8 === "string")
        line += (seg as { utf8: string }).utf8;
    }
    const trimmed = line.trim();
    if (trimmed.length !== 0) lines.push(trimmed);
    if (lines.length > 20000) break;
  }
  return lines.length !== 0 ? lines.join("\n").slice(0, 400_000) : null;
}

async function handleSave(request: Request): Promise<Response> {
  let record: Record<string, unknown>;
  try {
    const parsed = JSON.parse(await request.text());
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
      throw new Error("not a JSON object");
    record = parsed as Record<string, unknown>;
  } catch (error) {
    log(`POST /yt-save rejected: ${error}`);
    return json({ error: "invalid save request body" }, 400);
  }
  if (record.protocolVersion !== 1 || record.type !== "save") {
    log(`POST /yt-save rejected: missing protocolVersion 1 or type "save"`);
    return json({ error: "invalid save request" }, 400);
  }
  const videoId = typeof record.videoId === "string" && /^[A-Za-z0-9_-]{11}$/.test(record.videoId)
    ? record.videoId : null;
  if (videoId === null) {
    log(`POST /yt-save rejected: missing or malformed videoId`);
    return json({ error: "invalid save request; videoId must be 11 characters" }, 400);
  }
  // Optional transcript: base64 payload, either YouTube json3 caption bytes
  // (the app's fetch path) or a raw YTITranscriptResponse protobuf.
  const encoding = typeof record.transcriptEncoding === "string" ? record.transcriptEncoding : null;
  const payloadB64 = typeof record.transcriptPayload === "string" ? record.transcriptPayload : null;
  if (payloadB64 !== null && encoding !== "youtube-json3" && encoding !== "protobuf-base64") {
    log(`POST /yt-save rejected: transcriptPayload requires transcriptEncoding "youtube-json3" or "protobuf-base64"`);
    return json({ error: `invalid save request; transcriptEncoding must be "youtube-json3" or "protobuf-base64"` }, 400);
  }
  let transcript: { encoding: string; bytes: number; b64: string; text: string | null } | undefined;
  if (payloadB64 !== null) {
    const bytes = Buffer.from(payloadB64, "base64");
    if (bytes.length === 0 || bytes.length > 8 * 1024 * 1024) {
      log(`POST /yt-save rejected: transcript payload is empty or over the 8 MiB cap`);
      return json({ error: "invalid save request; transcript payload is empty or over the 8 MiB cap" }, 400);
    }
    const text = encoding === "youtube-json3" ? extractJson3Text(bytes) : extractTranscriptText(bytes)?.join("\n").slice(0, 400_000) ?? null;
    transcript = {
      encoding: encoding ?? "youtube-json3",
      bytes: bytes.length,
      b64: payloadB64,
      text,
    };
  }
  const ai = record.ai === true;
  const transcriptStatus = typeof record.transcriptStatus === "string"
    ? record.transcriptStatus.slice(0, 200) : null;
  const entry = {
    time: new Date().toISOString(),
    requestId: typeof record.requestId === "string" ? record.requestId : null,
    videoId,
    ai,
    youtubeVersion: typeof record.youtubeVersion === "string" ? record.youtubeVersion : null,
    ...(transcriptStatus !== null ? { transcriptStatus } : {}),
    ...(transcript !== undefined ? { transcript } : {}),
  };
  if (options.savesLogFile !== null) {
    try {
      appendFileSync(options.savesLogFile, `${JSON.stringify(entry)}\n`);
    } catch (error) {
      console.error(`saves log write failed: ${error}`);
    }
  }
  const hasTranscript = transcript !== undefined;
  log(`save: videoId=${videoId} ai=${ai} transcript=${hasTranscript ? `${transcript.bytes}B` : "none"}` +
      ` status=${transcriptStatus ?? "-"} requestId=${entry.requestId ?? "-"}`);
  return json({ ok: true, videoId, ai, transcript: hasTranscript });
}

async function handleTransform(request: Request, path: string): Promise<Response> {
  const auth = request.headers.get("Authorization");
  state.lastAuth = auth;
  state.lastPath = path;
  let parsed: { ok: true; envelope: Envelope } | { ok: false; error: string };
  try {
    parsed = parseEnvelope(await request.text());
  } catch (error) {
    parsed = { ok: false, error: `unreadable body: ${error}` };
  }
  if (!parsed.ok) {
    log(`POST ${path} rejected: ${parsed.error}`);
    return metaJson({ error: parsed.error }, 400, { action: "rejected" });
  }
  const env = parsed.envelope;
  logIncoming(path, env, auth);
  if (options.delayMs > 0) await Bun.sleep(options.delayMs);
  if (options.dumpDir !== null) {
    mkdirSync(options.dumpDir, { recursive: true });
    writeFileSync(`${options.dumpDir}/${env.requestId}.bin`, env.payload);
  }
  trackPlayback(path, env);
  logRequestDetails(env);
  logDecoded(env.payload, path, env.surface);
  logApi(env, path);

  // Payload modifications (remove/replace/add) run before the reply is built.
  let replyPayload = env.payload;
  if (options.dropHeadings.length > 0 &&
      (options.action === "replace" || options.action === "recode")) {
    const dropped = removeShelves(replyPayload, options.dropHeadings);
    if (dropped.removed.length > 0) {
      log(`modify: removed shelves ${JSON.stringify(dropped.removed)} ` +
          `bytes ${replyPayload.length}->${dropped.bytes.length}`);
      replyPayload = dropped.bytes;
    } else {
      log(`modify: no shelf matched ${JSON.stringify(options.dropHeadings)}`);
    }
  }

  let reply: Record<string, unknown>;
  let outBytes = 0;
  if (options.action === "http-error") {
    log(`POST ${path} -> HTTP 503 (http-error)`);
    return metaJson({ error: "mock transform failure" }, 503, { action: "http-error" });
  }
  if (options.action === "passthrough") {
    reply = { protocolVersion: 1, requestId: env.requestId, action: "passthrough" };
  } else if (options.action === "recode") {
    const recoded = recodePayload(replyPayload);
    if (recoded === null) {
      log(`recode: payload is not valid protobuf wire format; passthrough delivered`);
      reply = { protocolVersion: 1, requestId: env.requestId, action: "passthrough" };
    } else {
      log(
        `recode: topFields=${recoded.topFields} messages=${recoded.messages} ` +
        `bytesIn=${replyPayload.length} bytesOut=${recoded.bytes.length} ` +
        `identical=${recoded.identical ? "yes" : "no"}` +
        (recoded.identical ? "" : ` firstDiff=${recoded.firstDiff}`),
      );
      reply = {
        protocolVersion: 1,
        requestId: env.requestId,
        action: "replace",
        encoding: "protobuf-base64",
        payload: Buffer.from(recoded.bytes).toString("base64"),
      };
      outBytes = recoded.bytes.length;
    }
  } else {
    reply = {
      protocolVersion: 1,
      requestId: env.requestId,
      action: "replace",
      encoding: "protobuf-base64",
    };
    let transformed = replyPayload; // only reached for non-recode actions from here
    if (options.action === "replace") {
      transformed = new Uint8Array([...replyPayload, ...markerFieldBytes(options.markerField)]);
    } else if (options.action === "invalid-base64") {
      reply.payload = "!!!not-base64!!!";
    } else if (options.action === "request-id-mismatch") {
      reply.requestId = "mismatched-request-id";
    } else if (options.action === "version-mismatch") {
      reply.protocolVersion = 2;
      transformed = new Uint8Array([...replyPayload, ...markerFieldBytes(options.markerField)]);
    } else if (options.action === "unknown-action") {
      reply.action = "scramble";
    } else if (options.action === "oversized") {
      transformed = new Uint8Array(replyPayload.length + 17 * 1024 * 1024).fill(0);
      transformed.set(replyPayload);
    }
    if (typeof reply.payload !== "string") {
      const bytes = transformed as Uint8Array;
      reply.payload = Buffer.from(bytes).toString("base64");
      outBytes = bytes.length;
    }
  }

  return metaJson(reply, 200, { action: String(reply.action), outBytes });
}

// Every request that reaches the server gets exactly one access-log line,
// including health probes, playback reports, unknown paths and handler errors.
// This is the authoritative inventory of API calls; the detailed transform /
// decode lines are supplementary.
async function routeRequest(request: Request, url: URL): Promise<Response> {
  if (request.method === "GET" && url.pathname === "/") {
    const health = {
      protocolVersion: 1,
      service: "bun-recommendation-server",
      defaultAction: options.action,
      markerField: options.markerField,
      endpoints: ["POST /yt-browse", "POST /yt-next", "POST /yt-search", "POST /yt-reels", "POST /yt-playback", "POST /yt-save"],
      lastAuth: state.lastAuth,
      lastPath: state.lastPath,
    };
    log(`GET ${url.pathname} health`);
    return json(health);
  }
  if (request.method === "POST" && url.pathname === "/yt-playback") {
    return handlePlayback(request);
  }
  if (request.method === "POST" && url.pathname === "/yt-save") {
    return handleSave(request);
  }
  if (request.method === "POST" &&
      (url.pathname === "/yt-browse" || url.pathname === "/yt-next" || url.pathname === "/yt-search" ||
       url.pathname === "/yt-reels")) {
    return handleTransform(request, url.pathname);
  }
  log(`${request.method} ${url.pathname} rejected: unknown endpoint`);
  return json(
    { error: "unknown endpoint; this server exposes POST /yt-browse, POST /yt-next, POST /yt-search, POST /yt-reels, POST /yt-playback and POST /yt-save only" },
    404,
  );
}

const server = Bun.serve({
  hostname: options.host,
  port: options.port,
  async fetch(request): Promise<Response> {
    const url = new URL(request.url);
    const target = `${url.pathname}${url.search}`;
    const started = performance.now();
    let response: Response;
    try {
      response = await routeRequest(request, url);
    } catch (error) {
      log(`api: ${request.method} ${target} handler error: ${error}`);
      response = json({ error: "internal server error" }, 500);
    }
    const meta = responseMeta.get(response);
    const details: string[] = [];
    if (meta?.action !== undefined) details.push(`action=${meta.action}`);
    if (meta?.outBytes !== undefined) details.push(`out=${humanBytes(meta.outBytes)}`);
    const suffix = details.length > 0 ? ` ${details.join(" ")}` : "";
    log(`api: ${request.method} ${target}${suffix} -> ${response.status} ${(performance.now() - started).toFixed(1)}ms`);
    return response;
  },
});

mkdirSync(dirname(options.logFile) || ".", { recursive: true });
log(
  `bun-recommendation-server listening on ${server.hostname}:${server.port} action=${options.action} ` +
  `marker_field=${options.markerField} endpoints=POST /yt-browse, POST /yt-next, POST /yt-save log=${options.logFile} ` +
  `apiLog=${options.apiLogFile ?? "(disabled)"} savesLog=${options.savesLogFile ?? "(disabled)"}`,
);

process.on("SIGINT", () => {
  log("stopped");
  server.stop(true);
  process.exit(0);
});
