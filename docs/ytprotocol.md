# YouTube InnerTube protocol notes (the payloads we intercept)

Everything here is scoped to what the recommendations patch sees: the decoded
protobuf responses of `/browse`, `/next`, and `/search` on YouTube 21.33.6
(iOS 16). Confidence tags:

- **[fixture]** — observed in the captured payloads analyzed in this repo
  (probe Sessions 3–5; see `../ytkace/docs/RECOMMENDATION_PROBE_LOG.md`).
- **[schema]** — field numbers from publicly reconstructed `.proto` schemas
  (`Basket5125/YoutubeLocalProxy`: `android_full_next.proto`,
  `video_list_proto.proto`, `android_search.proto`). Container numbers listed
  here also appear in our fixtures; card-internal numbers marked [schema] are
  from the reconstruction and can drift between app versions.
- **[tool]** — behavior documented by LuanRT/YouTube.js (JSON-side parser),
  yt-dlp/Invidious (JSON consumers), or the decompiled app.

## Transport

The app receives protobuf (`GPBMessage` subclasses) — no compression at this
layer. Unknown fields are preserved by protobuf parsers, which is why the
echo-mode server can append marker field 90001 and YouTube neither sees nor
drops it. Wire types used: 0 (varint), 2 (length-delimited), 1/5 (fixed) —
groups never appear.

## Response envelopes

| Operation | Class | Observed top-level fields | Contents | continuationContents | frameworkUpdates |
| --- | --- | --- | --- | --- | --- |
| `POST /yt-browse` | `YTIBrowseResponse` | `[1,9,13,16,30,50,777]` [fixture] | **9** | **10** [schema] | 777 |
| `POST /yt-next` | `YTIWatchNextResponse` | `[1,7,9,13,14,16,21,25,44,777]` [fixture] | **7** | **8** [schema] | 777 |
| `POST /yt-search` | `YTISearchResponse` | browse-family shape (unverified on device) | 9 | 10 | 777 |

`frameworkUpdates` (777) is entity-mutation metadata, not page content — the
server decoder excludes it from recommendation extraction.

## Container hierarchy

Field paths below are numeric ([fixture] paths verified in the captures;
names [schema]). Repeated fields mean "one per item", so a whole list shares
one path.

**Home `/browse`**

```text
contents(9)
└─ singleColumnBrowseResultsRenderer(58173949)
   └─ tabs(1) → tabRenderer(58174010)
      └─ contentEntry(4) → … → sectionList(49399797)
         └─ itemSectionRenderer(50195462)
            └─ contents item(1) → modern wrapper chain
               └─ video card   (home: lockup-style, videoId observed at .20.9)
```

**Watch `/next`**

```text
contents(7)
└─ singleColumnWatchNextResults / two-column equivalent (51779735)
   ├─ results(49399797) → itemSectionRenderer(50195462)
   │  └─ contents item(1) → wrappers → item list at field 18,
   │     renderer variants at fields 4/5 (compactVideoRenderer-style cards)
   ├─ playlistPanel(2) → playlistPanelRenderer(50631000) → playlistPanelVideoRenderer(51779701)
   ├─ autoplayNext(3) → autoplayRenderer(46659098)
   └─ playerOverlays(14)
```

Modern (2025-era) builds insert wrapper messages with large field numbers
between the item list and the card; observed repeatedly in fixtures:
`153515154 → 172660663 → 168777401 → 5 →` then either `232954548 → 18`
(watch cards) or `312131490 → 20` (home lockup cards). Treat those as
observed structural hops, not stable names.

**Continuation responses**

- Browse: top-level `continuationContents(10)` → `sectionListContinuation
  (49399797)` [schema; matches probe `unknown-browse` payload shape].
- Next: top-level `continuationContents(8)` → `sectionListContinuation
  (49399797)` or `itemSectionContinuation(50195462)`.

## Card formats

`compactVideoRenderer` [schema, id 50630979 in the related-list container]:

| Field | Meaning |
| --- | --- |
| 1 | `videoId` (string) |
| 2 | thumbnails (repeated: url=1, width=2, height=3) |
| 3 | title `textRuns` |
| 4 | author (displayName=1, navigation=5) |
| 5 | published time text |
| 6 | view count text |
| 7 | length text |
| 8 | watch navigation (`videoId` inside `navData`) |

`shelfRenderer` [schema, 51845067]: `title=1`, `content=5` →
`shelfContent(57988071)` → `items(1)` → repeated `compactVideoRenderer
(50630979)`. Shelves carry their own continuation under `loadCommand(2)` →
`nextContinuationData(52047593)` → `token(1)`.

`playlistPanelVideoRenderer` [schema, 51779701]: `title=1`, `thumbnail=3`,
`byline=4`, `selected=6`, `nav=7`, `length=9`, `videoId=10`.

Text is `textRuns { run(1) { text(1), bold(2) } }` or `simpleText { text(4) }`
[schema]. Home lockup cards [fixture] keep the id under the wrapper chain at
`.20.9`; the title text sits in the same card subtree.

**One card repeats its videoId many times** (navigation endpoints, thumbnail
URLs, tracking params, menu endpoints): 15–30 occurrences per page across all
cards in our fixtures. Any substitution must patch every occurrence *within
that card*, not just the first.

## Verified 21.33.6 Home structures (from a real device payload)

Field numbers verified against a 570 KB Home capture pulled from the server's
`api.log` (extract with `Tools/api-log-inspect.py`):

| Structure | Shape |
| --- | --- |
| Modern shelf | `312131490` → entry → `f1` header (menu `f19`, heading `f20`, accessibility `f26`), `f9` repeated cards |
| Lockup card | `f1` media block (`f2` = duration string), `f2` metadata (`f1` = **title**), `f6` `//www.youtube.com/watch?v=<id>`, `f7` id, `f18` id again, menu subtrees (`14`/`7` → `169495254` → `98150882` → button renderers with "Share", "Not interested", "Send feedback"…), navData (`f6` → `…48687757` with `f36` title, `f37` channel) |
| Shorts shelf item | wrapper child `519005951` → `17` item: `1` key (`shorts-shelf-item-<id>`), `6` nav (`…139608561` → id), **`22` overlay → `1` → `1` = title text**, `4` accessibility "«title» - play Short", `14` menu ("Got it…", "Undo", "Send feedback"), `18` "Video removed", `21` "More actions" |
| Legacy shelf | `shelfRenderer 51845067`: title `f1`, content `f5` → wrapper → repeated cards (note: its continuation pages may carry no header — items then have no section) |
| Category chip bar (Home only) | `49399797 → 6 → 213380311` → rows (`f1`) → repeated chips (`91394224`); chip title at `2 → 1 → 1`, **`f9` varint 1 = selected**. The selected chip title is shown as `feed=«…»` in the decode header. Category-feed responses (the payloads fetched when a chip is tapped) do **not** contain the bar or the selected label — verified on a real chip request — so the title is only available on Home payloads that carry the bar. |
| Playlist card | media `f1` holds the first video's thumb + count text (`f1.f6` = "8 videos"), playlist URL at `media.f6` (`…/playlist?list=…`), title at `media.f21 → 8178 → f1 → f1`. The videoId is the thumbnail video; the decode tags the entry `[playlist]`. Note: `8178` is a **title container** (its `f1` holds titles), not metadata — only `514549827` (byline rows) and `75730170` (menus/stats) are suppressed as metadata. |
| Watch-related card variant | `232954548 → 18` entries; no direct `f6/f7` at card level — id, title and channel sit together in the navData node `48687757` (`f1` id, `f36` **title**, `f37` channel). Recognizing this node as a unit is what keeps channel names from becoming titles. |
| Channel Shorts shelf (compact variant) | `471792238 → 4 → 7` items: `f1` = `shorts-shelf-item-<id>`, `f4` = accessibility "«title», «stats» - play Short" (**the only plain title**), `f6 → …139608561` = playback item (id at `f1`), `f22 → 2 → 1` = stats ("2.5M views"). The player label and trailing stats segment are stripped; no title field exists in the item itself. |
| Shorts reel sequence item (`/yt-reels`) | Each top-level `2 → 1 → 139608561` entry: `f1` videoId, `f4` prefetch metadata token, `f5` frame thumbnails, `f53` playback UUID, `f79857908` player response. Verified: the 331 KB batch contains **no prose strings at all**, so these entries decode by id only; titles arrive with the per-item reel watch response. |

The server decodes with dedicated extractors for these shapes (lockup card,
compact card `id=1/title=3`, Shorts item) instead of generic string pairing:

- a recognized card is consumed whole, so menu/accessibility/byline strings can
  never become its title;
- lockup titles come from `card.f2.f1`; Shorts titles come from `item.f22.f1.f1`
  (accessibility `f4` as fallback, " - play Short" stripped); a card that
  genuinely carries no title is reported honestly as `(no title in payload)`;
- shelf headings come from the header entry (`f20`) and stamp every card below
  (`section`), which the log groups as `[Breaking news]` blocks;
- byline rows ("CTV News 3.9K 48 min ago", "… views … ago") are rejected as
  titles by regex even in fallback pairing;
- titles that legitimately start with a number ("4 Signs The Monad…",
  "1 Hour ASMR…") are accepted — only complete stat/duration shapes ("23:04",
  "23 minutes, 4 seconds", "42 minutes", "1.7M views", "130 thousand views",
  "1y ago") are rejected. Embedded detail pages reuse the same title field for
  view counts, so these guards also keep structured title extraction honest;
- title detection is structure-first: lockup `f2.f1`, navData `f36`, Shorts
  `f22.f1.f1`, compact `f3`. **Structural title fields are trusted as-is in
  any language/locale** — only empty strings and encoded protobuf params are
  excluded, so localized titles (accents, non-English script, digit-leading
  titles) need no per-language rules.
- Non-recommendation containers are suppressed structurally too:
  `playerOverlays` (`14 → 78882851`) holds audio-track badges, font/style
  panels and action buttons ("Auto-dubbed"/"Audio Track",
  "YouTubeSans"/"Remix") — never titles or ids. The live-preview block inside
  a card's media (`media.f1 → f23`) holds "Tap to watch live, … channel" plus
  a preview video id (e.g. a live-stream preview); neither is a
  recommendation — the containing live card keeps its own id and title.
  Top-level field `25` holds the engagement panels (transcript/comments/
  chapters), including their font-style blocks ("YouTubeSans") and labels
  ("Transcripts track selection") — also never titles or ids.
- Metadata containers are suppressed structurally: fields `514549827` (byline
  rows), `75730170` (menus/stats) and `78882851` (player overlays) hold
  channel/stat/menu strings in every locale ("Channel 70K 6d ago" / "Canal,
  1,3 mil vistas, hace 5 meses").
  Strings inside them are never title/id candidates, so view/time detection
  is language-independent. (`8178` is a title container — see the playlist
  card above — and is intentionally **not** suppressed.)
- Fallback prose pairing (unknown structures only) still uses the English
  heuristics below: base64url-protobuf strings (params/tokens) are never
  titles, UI badges ("Up next", "Send feedback", …) are denylisted, and
  complete stat/duration shapes ("23:04", "23 minutes, 4 seconds", "1.7M
  views", "130 thousand views", "1y ago") are rejected.

## Reading api.log for reverse engineering

`api.log` (next to `bun-server.log`, JSONL, `--no-api-log` disables) holds the
envelope plus the untouched protobuf per transform. `Tools/api-log-inspect.py`:

```sh
Tools/api-log-inspect.py --log ~/api.log --list
Tools/api-log-inspect.py --log ~/api.log --contains "Breaking news" --out /tmp/mine
Tools/api-log-inspect.py --log ~/api.log --request-id <id> --dump --limit 1
```

`--out` writes `<requestId>.bin` + `.json`; `--dump` prints a lenient wire
walk (field numbers, wire types, printable strings) for structure discovery.

## Request-side context (envelope + continuation tokens)

The client captures the actual InnerTube request at the hook boundary, not
just the response. `context` in the envelope carries:

| Key | Meaning |
| --- | --- |
| `requestClass` | Observed request class (`YTIBrowseRequest`, `YTIWatchNextRequest`, `YTISearchRequest`, …) |
| `requestPayload` | Base64 of the serialized request protobuf — the complete request as YouTube built it |
| `browseId` | Flat browse id when the gateway exposes it (`FEwhat_to_watch`, `FEsubscriptions`, `UC…`, …) |
| `continuation` | Flat continuation token when present |
| `params` | Flat params token when present (tab/feed selector) |
| `query` | Flat search query when present |
| `feedType` | Numeric tab/feed identifier from the tabbed-Home controller |
| `videoId` | Watch video id (also used by the server's playback bookkeeping) |

The server decodes `requestPayload` leniently (top-level fields + printable
strings) and logs `request: …`. It also base64url-decodes `continuation` and
`params` and logs `request-token: …` with the token's fields and strings — a
continuation token reveals the feed lineage (`FEwhat_to_watch`, a channel id)
and paging-state strings (`item_<uuid>…`), which is useful context when
deciding what the replacement list should contain. Neither the request payload
nor the tokens are modified or re-emitted; they are diagnostics only.

## Page-level context in the decode

The `context:` line summarizes what the response itself reveals, independent
of locale:

| Context | Source |
| --- | --- |
| Channel name / about | Channel header container `509923604`: name at `f1`, description at `524902670 → f1` (verified on a real channel page) |
| Channel id / handle | `UC[A-Za-z0-9_-]{22}` and `/@handle` strings inside the channel header; channel pages also expose the id as the surface |
| Tab titles | Channel tab renderer `58174010 → f2` (Videos, Shorts, Posts, …) |
| Hashtags | `#…` tokens found in any text leaf (item titles/descriptions) |
| Handles | `/@…` tokens found in any text leaf |
| Sections | Shelf headings already used to group recommendation bullets (`f20`) |
| Feed / query | Selected Home chip label and search query (as before) |

These are the useful levers for choosing replacement content: the channel
identity, which tab/feed the request belongs to, the page's selected feed and
search query, and the topics present in the payload.

## Shorts feed (reel watch sequence)

The vertical Shorts player does not use `/next` or `/browse` for its feed: it
batches shorts through `YTGetReelWatchSequenceServiceImpl`
(`makeYTIReelWatchSequenceRequest:responseBlock:errorBlock:` and the
`retryEnabled:` variant) — the app's `/reel/reel_watch_sequence` equivalent.
The patch hooks both variants, reports surface `shorts`, and posts to
`/yt-reels`. The response type is not pinned yet (open class gate: replacements
parse into the observed class; decode shows the raw structure for mapping).

Each batch entry is `2 → 1 → 139608561`: videoId at `f1`, prefetch metadata
token at `f4`, frame thumbnails at `f5 → 1 → 1`, playback UUID at `f53`, and
player response at `f79857908`. A 331 KB real batch contained **zero prose
strings**, so the sequence is IDs + prefetch data only; the title/channel/
description arrive with the per-item watch response
(`YTReelPlayerServiceImpl makeReelItemWatchRequest:responseBlock:errorBlock:`),
which is playback data and is deliberately not transformed. The decoder still
lists the batch ids as `(no title in payload)`.

## Search responses

`YTISearchResponse` uses top-level field `4` for contents (plus `2`, `9`,
`13`, `26`, `777`). The search query is not a named field on the request
object statically, but every search filter chip embeds it in its
searchEndpoint: `48687709 → f1` (query) and `f14` (display query). The decoder
takes the most frequent value and shows it as `query=«helios»` in the header.

## Shorts cards in the decode

Shorts items live inside the same item-section containers as regular cards but
use Shorts renderer types; their names appear as feature-marker strings inside
the card bytes (`shortsLockupViewModel`, `reelItemRenderer`, …). The decoder
tags any recommendation found in such a subtree with `[shorts]`, and the
page-level `shortsMarkers=N` header counts the markers. Shorted shelves
usually arrive as `unknown-browse` continuations (their lineage token was
never resolved), which is why the surface name alone cannot identify them.

## Continuation tokens

Observed format [fixture] — a real Home continuation token, decoded:

```text
4qmFsgJnEg9GRXdoYXRfdG9fd2F0Y2ga…          (146 chars, base64url)
→ protobuf (109 bytes)
   field 80226972 (length-delimited, 103 B)
   ├─ field 2: "FEwhat_to_watch"            ← which feed
   └─ field 3: nested protobuf (paging state; contains "item_<uuid>…" ids)
```

- Tokens are **plain base64url-encoded protobuf, not signed or encrypted**.
- In responses they live at `nextContinuationData.token` [schema+fixture]
  (`continuations[0].nextContinuationData.continuation` in JSON [tool]).
- The app sends the token back in the next request's `continuation` field
  [schema].
- They encode the **upstream paging cursor**, not the current page's content.

### Do we need to mint a continuation?

No. For remove/replace/add workflows, **keep the original token in the
replacement message**. Filtering or adding cards does not invalidate it — the
token still points at the next upstream page, so native pagination continues
seamlessly. Omitting it ends pagination after your page; minting a custom
token is technically possible (plain protobuf) but couples you to YouTube's
accepted paging-state shape, which changes between builds. Treat token
minting as unsupported until there is a concrete need.

## Changing the recommendation list (server-side recipe)

1. Parse the envelope; navigate to `itemSectionRenderer(50195462)` contents
   (repeated field 1) or the shelf item list; each card is a contiguous
   length-delimited submessage.
2. **Remove** = drop card segments from the repeated field.
3. **Replace/add** = clone a template card (from the same page or a saved
   fixture of the same YouTube build) and patch inside it:
   - every `videoId` occurrence (navigation endpoints and thumbnail URLs —
     `i.ytimg.com/vi/<id>/…` serves any public video),
   - title text (`run.text` / `simpleText.text`), optionally byline/views/
     length strings (the UI renders whatever text is present),
   - leave tracking params alone (cosmetic; YouTube does not validate them for
     rendering).
4. Re-serialize with a length-recomputing writer (protobufjs dynamic message
   from the extracted schema, or a hand-rolled wire writer); never patch bytes
   in place without recomputing nested lengths.
5. Leave continuation tokens and unknown fields untouched (wire-level splicing
   preserves them naturally). The client patch validates parseability and the
   response class, then delivers; YouTube renders the result.

## Lossless recode (verified)

The Bun server's `--action recode` parses a payload into a field tree
(recursing into nested messages wherever the bytes parse cleanly, keeping
opaque segments raw) and re-serializes it with its own encoder, recomputing
every key varint and length prefix. Result on the captured payloads:

| Payload | Bytes | Nested messages | Re-encode |
| --- | --- | --- | --- |
| Home body | 525,872 | 14,433 | byte-identical |
| Watch completion | 760,474 | 38,762 | byte-identical |

This is the foundation for edits: build the field tree, remove/replace/insert
card segments (or patch strings inside a card, recomputing lengths), and emit.
Non-minimal varints are canonicalized (detected and reported); a payload that
fails wire parsing falls back to passthrough.

## Playback observation boundaries (client-side, 21.33.6)

Verified in the class dump; all hooks are observation-only (arguments are
never modified): `YTPlayerViewController` →
`playbackController:didActivateVideo:withPlaybackData:` (video became active;
videoId probed from the playback-data wrapper),
`playbackControllerDidFinishPlayback:`, and `pauseWithStoppageReason:`.
Events are POSTed to `/yt-playback` as `activate` / `pause` / `finish`. The raw
state hook (`potentiallyMutatedSingleVideo:mediaStateDidChangeFromState:toState:stoppageReason:`)
is intentionally not installed: its transitions are noisy and redundant, and
the server rejects every event name outside those three (no legacy or
alternate forms). Pause/finish carry no video id at the boundary, so the
server keeps the last activated id as the current video.

## Modifying payloads (remove / replace / add)

Implemented in [../server/payload-modifier.ts](../server/payload-modifier.ts)
(the file header carries the full working notes and invariants). Verified
operations, with the wire codec proven byte-identical on real captures:

| Function | Effect |
| --- | --- |
| `findShelves(payload)` | Lists shelves: heading, kind (modern `312131490` / legacy `51845067`), cards |
| `removeShelves(payload, headings)` | Drops matching shelves entirely (heading + cards + tracking) |
| `setShelfCards(payload, heading, cards)` | Replaces the whole card list (display order = array order) |
| `removeShelfCard(payload, heading, i)` | Drops card `i` |
| `replaceShelfCard(payload, heading, i, card)` | Swaps card `i` for prepared bytes |
| `insertShelfCard(payload, heading, i, card)` | Inserts a prepared card at `i` |
| `cloneCardAs(template, {newId, newTitle})` | Clones a real card: patches every occurrence of the old id (thumbnails/navigation/tracking), the metadata title (`f2.f1`) and the navData title (`f36`) |
| `replaceShelfCardWithClone(...)` | Clone + replace in one call |

Recipe for "remove some, add mine": `findShelves` → choose shelf → edit its
card list (`removeShelfCard` / `insertShelfCard`) where inserted cards come
from `cloneCardAs(templateFromTheSameBuild, { newId, newTitle })`. Every edit
re-serializes through the encoder, which recomputes nested lengths.

Invariants: never touch continuation tokens (pagination keeps YouTube's
original cursor), never rebuild messages by hand (splice fields, preserve
tracking/unknown fields), card order is display order. Device check: cards
render, tap through (watchEndpoint ids), and paginate.

The server exposes a device-testable subset: `--drop-heading "Breaking news"`
(repeatable) removes matching shelves before replying in `replace`/`recode`
mode and logs `modify: removed shelves [...] bytes before->after`.

## Tooling map

| Tool | What it gives us | Limitation |
| --- | --- | --- |
| LuanRT/YouTube.js (`youtubei.js`) | JSON-side InnerTube parser; node class names and semantics; continuation handling | parses JSON responses; no wire serializer — semantic reference only |
| Basket5125/YoutubeLocalProxy `.proto` files | reconstructed response schemas with field numbers (cited above) | legacy-era card internals; container numbers match our 21.33.6 fixtures |
| azutake/youtubei-protos | partial proto dump (containers) | incomplete |
| yt-dlp, Invidious, Piped | endpoint behavior, params, continuation flows at JSON level | no protobuf field numbers |
| InnerTube JSON API (`/youtubei/v1/*`) | named fields (`title`, `videoId`, `viewCountText`, `publishedTimeText`) — no heuristics, any locale | web API, not the iOS app's protobuf stream; needs client context/API key (tools like youtube.js manage it) — usable server-side to look up titles/metadata per videoId when building cards |
| Decompiled app (`reverseengineeringer/com.google.android.youtube`) | authoritative generated field numbers when the reconstructions disagree | obfuscated class names; heavy |

Our own captures remain the ground truth for the pinned build; re-verify
numbers per YouTube version the same way hook ABIs are re-verified.
