# Server: run, configure, verify

The patch posts every video recommendation list to the canonical endpoints
under the configured base URL — `POST /yt-browse` (Home, category chips,
teasers, and all other browse feeds: subscriptions, history, channel pages, …),
`POST /yt-next` (watch page + related list), `POST /yt-search` (search
results), `POST /yt-reels` (Shorts feed batches), `POST /yt-playback` (client-side playback observations: activate /
pause / finish, no payloads), and `GET /` (health). Nothing else is
called; `/player` data itself and comment-thread services are not intercepted.
The base URL is `scheme://host[:port]` with no path (the client rejects
path-qualified URLs). This protocol has exactly these endpoints, event names
and URL forms — **no legacy or migration variants**: unknown paths return 404
and `/yt-playback` rejects any event other than `activate`, `pause`, `finish`
with HTTP 400. Contract details:
[overview.md](overview.md) §Server contract. Server implementation and flags:
[../server/README.md](../server/README.md).

The envelope's `surface` field tells the server which list it is looking at:
`home`, the literal browse ID (e.g. `FEsubscriptions`), `browse-teaser`,
`browse-unknown`, `watch`, or `search`.

## Run the server (Mac)

```sh
cd server
bun run start                                  # replace mode, logs to bun-server.log
ipconfig getifaddr en0                          # LAN IP for the phone, e.g. 192.168.3.199
tail -f bun-server.log
```

Default `--action replace` echoes the original bytes plus one extra
length-delimited field: number 90001, value `RECSRV`. It is an unknown field to
YouTube's protobuf parser — preserved, ignored, invisible — so the feed renders
normally while proving the delivered object came from the server. Other modes
exercise the patch's fallback: `passthrough`, `not-modified` (HTTP 304), `http-error`, `invalid-base64`,
`request-id-mismatch`, `version-mismatch`, `unknown-action`, `oversized`,
`--delay-ms` (timeouts). Payloads are logged only as sizes + sha256 prefixes;
`--dump-dir DIR` saves originals for offline work.

## Saves (watch-page menu)

The player's menu button — tap the video; it hangs below the top-right
settings cog — offers **Transcript** / **AI Summary** (download icons). Before posting, the patch
gathers the video's transcript the way the released YTKACE does: the active
video's signed caption-track URL with `fmt=json3` is fetched with a plain
HTTPS GET (the URL signature is the credential; no account plumbing, no
recommendation-toggle dependency). Every step fails soft — no captions means
videoId-only, never a failed save. Each tap POSTs `/yt-save` with
`{protocolVersion:1, type:"save", videoId, ai, transcriptStatus}` plus, when
gathered, `transcriptEncoding:"youtube-json3"` and the raw json3 caption
bytes as `transcriptPayload`. Accepted saves append one JSON line to
`saves.jsonl` next to the server log — the line carries the videoId, `ai`,
the transcript status, and the transcript (raw base64 + extracted readable
text). `--saves-log <path>` relocates the file, `--no-saves-log` disables
persistence. The phone shows a small Saved (+ transcript) / error note.

### Settings menu

The in-app Settings modal (via Settings in the player menu) is organized into:
- **Feeds**:
  - **Customized Feeds** — master toggle
  - **- recommendations** — Home, watch next, browse (subscriptions, history)
  - **- searches** — search results
  - **- video stats** — hooks playback tracking (`/yt-playback`) and Shorts (`/yt-reels`)
- **Server**:
  - **Server URL** — base URL of the custom recommendations server
  - **Recommend Timeout** — server response timeout in milliseconds (default: 300 ms) before immediately falling back to YouTube's response
  - **Token** — optional bearer token
  - **Test connection** — verifies server connectivity and protocol version
- **Transcripts & AI**:
  - **Save transcripts & AI** — controls Transcript and AI Summary in the player menu
  - **- Keep Panel Open** — keeps player menu open after tapping save actions
- **Statistics** & **Diagnostics**

## Configure on the phone

- **YTKACE Settings → RECOMMENDATIONS SERVER** (preferred): the patch adds a
  URL and an Auth-Token row at the bottom of YTKACE's native settings page.
  Detail text shows the current value (token as dots). These are the same
  preference keys the recommendations settings panel edits.
- Base URL only, **with the port**: `http://192.168.3.199:8046` — a portless
  URL probes port 80 and just answers "Connection failed".
- **Test connection** (recommendations panel, Server section) must answer
  `protocolVersion 1 · service bun-recommendation-server`.
- Enable **Customized Feeds**, then the sub-toggles
  (the sub-toggles appear only once the master switch is on, and apply to requests made after the change):
  - **- recommendations** — YouTube-chosen lists (Home, category chips, watch
    page + related list), subscriptions, history, feed teasers.
  - **- searches** — search results.
  - **- video stats** — hooks playback tracking (`/yt-playback`) and Shorts (`/yt-reels`).
- Caching: identical re-fetched content skips the server for **300 s** on
  Recommend and Subs/History pages (20 s for search), so a quick
  pull-to-refresh with unchanged content does not spam the server. Changing
  the server URL clears it immediately.

## Device verification protocol (per build)

Each row = one short session (Home refresh, scroll pages, tap category chips,
switch subscriptions/history, run a search or two, open video A, scroll its
related list, open video B). Watch `bun-server.log` on the Mac side — every
transform now also carries a `decoded:` line with the page's top-level protobuf
field numbers and the recommendation entries (videoId + title pairs) found in
it:

| # | Server action | Expected on device | Expected in log |
| --- | --- | --- | --- |
| 1 | toggles off | stock behavior, no requests | nothing |
| 2 | `replace` | feeds render/paginate/tap normally; diagnostics `replacements` ≈ pages fetched, `markerSeen: 1` each | `action=replace` per page: `/yt-browse` (Home, chips, `surface=FEsubscriptions`/`FEhistory`/…, `browse-teaser`), `/yt-next` (watch + related), `/yt-search` — each followed by its `decoded:` line |
| 3 | `passthrough` | feed unchanged, no replacement parsed | `action=passthrough` per page |
| 4 | `http-error` or `--delay-ms 5000` | feed unchanged after a brief spinner; `fallbacks` rises with reason | timeout / 503 |
| 5 | `invalid-base64`, `version-mismatch`, `request-id-mismatch`, `unknown-action` | same as 4 — violations never reach YouTube | corresponding line |

Also verify: rapid navigation delivers exactly once per page; disabling
toggles stops new server calls (already-rendered feeds stay); playback starts
normally with watch replacements live; diagnostics export is metadata-only.

Expected shape note: watch related-list pages surface at two hooked layers;
the content dedupe and marker guard keep one server call per page — so
watch-continuation *deliveries* outnumber *transforms* in the diagnostics, and
that is correct.

## Troubleshooting

- **Connection failed** — wrong port (bun default is 8046), different network,
  macOS firewall, or you packaged without `--allow-insecure-http-dev` for an
  http:// URL. `http://localhost` on the phone is the phone itself, not the Mac.
- **Reachable but no transforms** — surface toggles off, or base URL wrong
  (remember: no path in the setting).
- **Fallbacks with "timed out"** — LAN latency vs the 2 s default; correct
  behavior, tune `TimeoutMS` if needed.
- **`class-mismatch` / `wrap` events in diagnostics** — a hook boundary saw an
  unexpected response class or callback signature; the original was delivered.
  Report the event; it usually means YouTube changed something on that
  boundary.

## Decoding requests

With decoding enabled (default), each transform is one API call and is logged
as one block, in this order:

1. **Incoming line** — identifiable before any payload work:
   `POST /yt-browse <requestId> auth=no surface=… phase=… type=… yt=… in=197087B(<sha256 prefix>) class=… browseId=… query=«…» feedType=…`
   (`videoId=` is included for watch).
2. **Request detail** — `request: bytes=… fields=[…] strings=[…]` (the
   serialized InnerTube request decoded leniently), then
   `request-token: continuation=«…» (NB fields=[…] strings=[…])` and the same
   for `params`. This is where a continuation's feed lineage and paging state
   show up.
3. **Response detail** — `decoded: [/yt-browse] top fields=[…]` (777 is
   `frameworkUpdates`, excluded as entity-mutation noise), a `context:` line
   with channel name/id/handle/about, tab titles, hashtags, handles and shelf
   headings, then one bullet per recommendation entry:
   `- <videoId> «title»` (deduped by id, up to 20), tagged `[shorts]` /
   `[playlist]` and grouped under its shelf heading. `shortsMarkers=N` appears
   when the payload contains Shorts renderer names. Reel-sequence batches
   carry no title text at all, so those entries list by id as
   `(no title in payload)`.
4. **Processing lines** — `recode:` / `modify:` when applicable.
5. **Closing summary** — exactly one compact line per call:
   `api: POST /yt-browse action=replace out=197k -> 200 253.7ms`
   (`out` uses `2B` / `197k` / `1.7M`). Health probes, playback reports,
   unknown paths and errors also get one `api:` line, without `action`/`out`.

Example (one call, one response body):

```
POST /yt-browse 3A6C9A4B-… auth=no surface=unknown-browse phase=continuation type=YTIBrowseResponse yt=21.33.6 in=570277B(6b74d3058305d42f) class=YTIBrowseRequest browseId=FEwhat_to_watch query=«helios»
request: bytes=25 fields=[1,2] strings=[«FEwhat_to_watch», «helios»]
decoded: [/yt-browse] top fields=[1,9,13,16,30,50,777] feed=«All» recommendations=17 sections=1
context: hashtags=[#uspolitics #midterms] sections=[«Breaking news»]
    - o3IuPEJXXE4 «The Ancients Glitched Reality: Psyops Entities & Consciousness | Chase Hughes»
    [Breaking news]
      - CMH1vWoqK_0 «What Democratic control of Congress means for Canada-U.S. trade»
recode: topFields=9 messages=10457 bytesIn=570277 bytesOut=570277 identical=yes
api: POST /yt-browse action=replace out=570k -> 200 297.4ms
```

A decoded block's bullets are recommendations inside that one response, not
separate API calls: one block per POST, and multiple blocks mean multiple
calls (e.g. initial page + continuations).

The raw request data — the envelope, the untouched original protobuf and the
serialized request, all base64 — is appended to `api.log` next to
`bun-server.log` (JSONL, one replayable line per transform; `--no-api-log`
disables). This is wire-level heuristic inspection, not a schema parse; Stage
C's field maps replace it.
The underlying payload structure — container hierarchy, card field numbers,
and continuation-token format — is documented in
[ytprotocol.md](ytprotocol.md).
