# Recommendation server (Bun)

The dev/production transform server for the YTKACE+ recommendations patch.
Self-contained: **Bun >= 1.0, zero packages** — nothing to install.

## Endpoints (the only ones)

- `POST /yt-browse` — Home feed pages, including the tabbed-Home category chips
- `POST /yt-next` — watch page + related-list pages
- `POST /yt-search` — search results
- `POST /yt-reels` — Shorts feed batches (reel watch sequence)
- `POST /yt-playback` — client playback observations (no payloads)
- `GET /` — health document (also the patch's connection probe)

Any other path answers 404. The wire contract (envelope, replace/passthrough,
marker) is documented in [../docs/overview.md](../docs/overview.md) §Server
contract; the patch itself only ever calls these three routes.

## Recode mode (lossless re-encode test)

```sh
bun run bun-recommendation-server.ts --action recode --port 8046 --log-file bun-server.log
```

Each incoming payload is fully parsed into a field tree (recursing into every
nested message the bytes parse cleanly as) and re-serialized by our own
encoder, which recomputes every key and length. The log reports
`recode: topFields=… messages=… bytesIn=… bytesOut=… identical=yes|no`. On
YouTube 21.33.6 captures it is byte-identical (Home 525,872 B / 14,433 nested
messages; watch 760,474 B / 38,762 messages), which is what makes later
remove/replace/insert edits safe: a modified tree re-serializes correctly.
Non-minimal varints are canonicalized (reported as `identical=no
firstDiff=…`); unparseable payloads fall back to `passthrough`.

## Run

```sh
bun run start                 # replace mode (echo + marker), logs to bun-server.log
# or, with the LAN IP the phone needs:
bun run bun-recommendation-server.ts --action replace --port 8046 \
    --log-file ~/yt-rec-server.log --host 0.0.0.0
tail -f ~/yt-rec-server.log
```

Then configure the patch on the phone with the **base URL only**
(`http://<mac-ip>:8046` — no path; the client appends `/yt-browse` and
`/yt-next` itself).

## Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--action` | `replace` | `replace` (echo + marker), `passthrough`, **`recode`** (decode and re-encode the payload with our own encoder, no marker — proves losslessness), or the fallback-exercise modes: `http-error`, `invalid-base64`, `request-id-mismatch`, `version-mismatch`, `unknown-action`, `oversized` |
| `--port` / `--host` | `8046` / `0.0.0.0` | bind address |
| `--log-file` | `bun-server.log` | append-only review log (one line per event) |
| `--delay-ms` | `0` | artificial latency; above the patch's timeout exercises its original-response fallback |
| `--marker-field` | `90001` | protobuf field number of the appended `RECSRV` marker (0 disables) |
| `--dump-dir` | off | save received original payloads for offline debugging |
| `--no-decode` | decoding on | by default each transform logs the request context (serialized request + decoded continuation/params tokens), the page context (channel/id/handle, tabs, hashtags, handles, sections), the payload's top-level field numbers, Shorts-renderer markers, and one bullet per recommendation entry (videoId + title, up to 20). Disable with `--no-decode`. |
| `--api-log FILE` | `api.log` next to `--log-file` | JSONL of the raw request data: one replayable line per transform with the envelope and the base64 of the untouched original protobuf (never compressed). `--no-api-log` disables it. |
| `--drop-heading TITLE` | off | Removes shelves with that heading from the payload before replying (`replace`/`recode` modes; repeatable). Logs `modify: removed shelves … bytes in->out`. Payload modification functions (remove/replace/insert cards, card cloning) live in [payload-modifier.ts](payload-modifier.ts) — notes and invariants in its header plus [../docs/ytprotocol.md](../docs/ytprotocol.md). |

Example decode block (real search response):

```
2026-11-04T08:42:12.029Z decoded: [/yt-search] top fields=[1,2,4,9,13,26,777] query=«helios» recommendations=44
    - iWUG1qOCAWg «The Horrifying Story of the Helios Ghost Flight.»
    …
```

Example block for one call (real channel page; incoming → request detail →
decode → closing summary):

```
2026-11-04T18:26:53.798Z POST /yt-browse 8C7E… auth=no surface=UCHhAPWPrNJscVPZArCYLm7g phase=initial type=YTIBrowseResponse yt=21.33.6 in=1656766B(a7e035baf8678052) class=YTIBrowseRequest browseId=UCHhAPWPrNJscVPZArCYLm7g
2026-11-04T18:26:53.799Z request: bytes=53 fields=[1,2,3] strings=[«FEwhat_to_watch», «helios», «UCHhAPWPrNJscVPZArCYLm7g»]
2026-11-04T18:26:53.800Z request-token: continuation=«4qmFsgIdEg9GRXdoYXRfdG9fd2F0Y2ga…(47)» (35B fields=[80226972] strings=[«FEwhat_to_watch», «item_123»])
2026-11-04T18:26:54.428Z decoded: [/yt-browse] top fields=[1,9,13,16,28,40,51,777] recommendations=45
context: channel=«Aged Skills» channelId=UCHhAPWPrNJscVPZArCYLm7g handle=/@agedskills description=«Aged Skills explores the art of traditional craftsmanship…» tabs=[«Videos», «Shorts», «Posts»] handles=[/@agedskills]
    - QpOZ6mFDwEo «This is How a Mill Axle Was Made!» [shorts]
  …
2026-11-04T18:26:55.001Z api: POST /yt-browse action=replace out=1.7M -> 200 1203.4ms
```

The incoming line identifies the call before any payload work (endpoint,
requestId, auth, surface, phase, response type, input size/hash, request class
and flat browseId/query/feedType). `request:` is the serialized request
decoded (browseId/params/continuation/query/client info); `request-token:`
decodes the base64url continuation/params protobuf, revealing the feed lineage
(`FEwhat_to_watch`, a channel id, paging cursor strings). The `context:` line
is what the response reveals about the page: channel name/id/handle/about,
tab titles, hashtags and handles found in item titles, and shelf headings. The
final `api:` line is the only closing line per call and carries the chosen
action and human-readable output size.

Example decode block (real Home feed page, shelf-grouped):

```
2026-11-04T06:18:19.051Z decoded: [/yt-browse] top fields=[1,9,13,16,30,50,777] recommendations=22 sections=1
context: hashtags=[#uspolitics #midterms] handles=[/@THIRDEYEDROPS /@astralclub5964] sections=[«Breaking news»]
    - LasUujrNBs8 «I don't usually make them this nervous.…» [shorts]
    - ky70FAboadY «She canceled her wedding a week before the date, then did something that shocked everyone» [shorts]
    [Breaking news]
      - CMH1vWoqK_0 «What Democratic control of Congress means for Canada-U.S. trade»
      - K0ywyEB_OHc «Voters hand Democrats Senate control in sharp rebuke to Trump’s power»
      - ZGrj_k60feM (no title in payload)
  …
```

Cards are decoded with structure extractors (lockup cards, compact cards,
Shorts shelf items) instead of generic string pairing, so menu labels and
channel names cannot become titles. Shelf headings are detected from the
header entry and group their cards; Shorts cards that carry no title text in
the browse payload are reported as `(no title in payload) [shorts]`.
Channel/tab Shorts shelves use a compact card (`f1` =
`shorts-shelf-item-<id>`) whose only plain title is the accessibility line at
`f4` ("«title», «stats» - play Short"); the play label and stats tail are
stripped there. `/yt-reels` batches carry no title strings at all (verified:
zero prose strings in a 331 KB capture), so their entries list by id only.
`YTRC_DEBUG_STRUCT=1` prints extraction decisions. For offline analysis,
`Tools/api-log-inspect.py --log api.log --list | --contains TEXT --out DIR | --dump`
lists, filters, extracts and wire-dumps captured payloads.

Shorts content is flagged two ways: the header counts the Shorts renderer
markers found in the payload (`shortsMarkers=3` — continuation pages for Shorts
shelves arrive named `unknown-browse` because their lineage token was never
seen), and every recommendation entry whose card subtree contains those
markers gets a `[shorts]` suffix. Shorts titles are read from the verified
overlay field (`item.f22.f1.f1`, accessibility `f4` as fallback):

```
    - mevTdoiDF6o «Just a big cat.😻…» [shorts]
    - lnXZDoEb5kU «Tough man get humbled in public» [shorts]
```

Menu labels (`Send feedback`, `Got it…`, `Show fewer Shorts`, …) are filtered
from title candidates. A Shorts card that genuinely has no title text (some
shelf variants) is reported as `(no title in payload)` rather than paired with
a menu string.

## Playback events

The patch (v7+) reports real playback events from client-side observation
hooks on `YTPlayerViewController` — observation-only, they never modify
playback. Events arrive on `POST /yt-playback` and are logged as:

```
play(client): event=activate videoId=48YfC8VCIsY detail={"ad":false,...}
play(client): event=pause videoId=- detail={"reason":5}
play(client): event=finish videoId=-
```

`activate` = a video became the active playback (open or switch),
`pause` = pause with its reason code, `finish` = playback ended. These are the
only accepted event names — there are no legacy or alternate forms, and any
other event (including raw `state` transitions from older builds) is rejected
with HTTP 400 and logged as a rejection.

Fetch-based inference (`play: start/switch/leave … (inferred …)`) is still
available for older clients but **off by default**: enable with
`--infer-playback`. With v7+ installed, the client events are authoritative
and no inference is needed.

## What gets logged

One line per event, appended to the log file and mirrored to stdout. Every
request has exactly one closing `api:` line — for transforms it includes the
action and output size (`api: POST /yt-browse action=replace out=197k -> 200
253.7ms`); health probes, playback reports and unknown paths get
`api: <METHOD> <path> -> <status> <duration>ms`. A transform logs in this order:
incoming request line (endpoint, requestId, auth, surface, phase, type,
version, input size/hash, request class and flat browseId/query/feedType),
request details (serialized request decoded + continuation/params tokens), the
`decoded:` block with the payload's top-level field numbers, Shorts-renderer
markers, page context and one bullet per recommendation entry (videoId +
title), processing lines (`recode:` / `modify:`), then the closing summary.
The raw request data (envelope + untouched original protobuf + serialized
request, base64) is appended to `api.log` (JSONL, one replayable line per
transform); `--dump-dir` additionally writes the original payloads as binary
files.
