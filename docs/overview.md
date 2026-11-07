# YTKACE+ recommendations patch — overview

An independent, additive patch (`YTKACERecommendations.dylib`) that is injected
into a supplied released **YTKACE** app and reroutes video recommendation
responses — Home feed, category chips, subscriptions/history/other browse
feeds, search results, the watch page and its related list, feed teasers —
through **your own server** before YouTube renders them. YouTube's fetch, UI, navigation, and playback are
untouched; on any server failure the original response is delivered instead,
so the worst case is the stock app.

```text
YouTube fetch
  -> patch hook snapshots the original response bytes (on the delivering thread)
  -> POST <server-base>/yt-browse   (Home feed, tab chips)   or   <server-base>/yt-next   (watch page + related)
     JSON envelope: {protocolVersion:1, requestId, surface, phase,
                     context:{videoId?, browseId?, continuation?, params?, query?, feedType?,
                              requestClass?, requestPayload?}, responseType,
                     encoding:"protobuf-base64", payload:<original bytes>}
     Authorization: Bearer <token>                    (only when a token is configured)
  -> server answers  {protocolVersion:1, requestId, action:"replace"|"passthrough", payload?}
  -> patch validates (version, requestId, action, encoding, size), parses the
     replacement with YouTube's own protobuf parser + extension registry,
     and delivers it ONCE on the main thread into YouTube's original callback
  -> YouTube parses and renders exactly those bytes
```

Fallback rule: timeout (2 s default), HTTP error, protocol violation, wrong
class, or parse failure ⇒ the **original** response is delivered. The delivered
object is authoritative — probe sessions 3–5 proved render bytes equal
completion bytes byte-for-byte under substitution (see the ytkace repo's
`docs/RECOMMENDATION_PROBE_LOG.md` for the evidence trail).

This repo is self-contained. The original `../ytkace` checkout is kept
unmodified and is referenced only for the discovery history (probe sessions,
symbolized backtraces) and as the source of the supplied test app
(`../ytkace/IPA/YouTube_iOS16.app`, YTKACE 21.33.6 / iOS 16 baseline).

## Where the patch injects itself

Two layers: a Mach-O load command and runtime Objective-C hooks.

1. **Binary injection (packaging time).** `Scripts/package-recommendations.py`
   copies the supplied `.app`, appends a `LC_LOAD_DYLIB` for
   `@rpath/YTKACERecommendations.dylib` to the YouTube executable (exactly one),
   drops the ad-hoc-signed dylib into `Frameworks/`, re-signs everything
   ad-hoc, and zips the result for sideloader (iLoader) re-signing. The
   supplied YTKACE dylib and resources are byte-preserved and verified by
   hash. Optionally (`--allow-insecure-http-dev`, the packaged copy only) it
   adds `NSAppTransportSecurity/NSAllowsArbitraryLoads` so a plain-http LAN
   dev server works; clean builds keep stock ATS for HTTPS.
   A C constructor (`YTRCStart`) runs at dylib load, registers preference
   defaults, installs the hooks (with retries for late-loading classes), and
   attaches the player-controls **recommendation menu** button (a
   semi-transparent square below the settings cog of the tap-the-video
   chrome: Transcript / AI Summary / Settings).

2. **Runtime hooks (30, ABI-checked, fail-closed).** Each hook verifies the
   method's full type encoding before installing (`YTRCMethodMatches`); a
   missing or changed method is logged and left unhooked — the app keeps
   running stock. `Scripts/verify-recommendation-signatures.py` checks all 30
   encodings against the target executable before you package.

   | # | Class / selector (encoding) | Purpose |
   | --- | --- | --- |
   | 1 | `YTAppBrowseService makeRequest:refresh:reloadContinuationData:initialResponseBlock:responseBlock:errorBlock:` (`v@:@B@@?@?@?`) | **All browse-family pages.** Every response block is wrapped: `FEwhat_to_watch` surfaces as `home`, other browse IDs (`FEsubscriptions`, `FEhistory`, `FEshorts`, channel pages, …) surface under their own browse ID, unresolved continuations as `browse-unknown` — all sent to `/yt-browse`. The ~105 B Home stub block passes through untouched. |
   | 2 | `YTAppBrowseService selectBrowseIDForRequestForBrowseID:andContinuation:` (`@@:@@`) | Continuation → surface lineage (in-memory token index). |
   | 3 | `YTAppBrowseService addBrowseIdToCacheIfRequiredForContinuationKey:browseID:` (`v@:@@`) | Same lineage cache writes. |
   | 4 | `YTInnerTubeFeedControllerDataSource requestContinuationWithType:initialResponseBlock:block:errorResponseBlock:` (`v@:Q@?@?@?`) | **Tabbed-Home category chips** ([All] [Podcasts] [News] …) — initial page + continuations per tab id (`feedType`). These bypass `YTAppBrowseService` entirely. |
   | 5–6 | `YTInnerTubeFeedControllerDataSource requestInnerTubeContinuationWithContinuationToken:…` (two variants, `v@:@Q@B@B@?@?` / `v@:@B@B@?@?`) | **Feed teaser prefetch continuations** — recommendation-adjacent feeder content, sent to `/yt-browse` as `browse-teaser`. Response type not pinned: the class gate is open and replacements parse into the observed class. |
   | 7 | `YTWatchService setWatchNextRequest:willMakeRequestBlock:completionBlock:` (`v@:@@?@?`) | **Watch page** (player overlays, up-next sidebar, panels). The completion is the authoritative boundary: what it delivers is what YouTube renders. |
   | 8 | `YTWatchService setWatchNextRequest:willMakeRequestBlock:valueHandler:completionHandler:` (`v@:@@?@?@?`) | Same coordinator, alternate ABI — dormant on 21.33.6, kept for coverage. |
   | 9–11 | `YTAppWatchNextService makeRequest:refresh:responseBlock:errorBlock:` (`v@:@B@?@?`), `…timeoutInterval…` (`v@:@Bd@?@?`), `makeFallbackEnabledRequest…` (`v@:@Bd@?@?`) | **Watch related-list continuations.** One fetch surfaces at multiple layered hooks; content-hash dedupe + the server marker guard keep exactly one server call per page. |
   | 12–13 | `YTWatchNextServiceImpl makeRequest:refresh:responseBlock:errorBlock:` + `…timeoutInterval…` | Base-class variants of 9/10 (same dedupe). |
   | 14 | `YTCompositeWatchNextService makeRequest:refresh:responseBlock:errorBlock:` (`v@:@B@?@?`) | Silent on 21.33.6; hooked for coverage. |
   | 15–16 | `YTAppSearchService makeRequest:refresh:responseBlock:errorBlock:` (`v@:@B@?@?`), `YTSearchServiceImpl makeRequest:…` (same encoding) | **Search results** → `/yt-search` as surface `search` (expected `YTISearchResponse`). |
   | 17 | `YTSettingsViewController setSectionItems:forCategory:title:icon:titleDescription:headerHidden:` (`v@:@Q@@@B`) | Not a fetch boundary: splices the **RECOMMENDATIONS SERVER** section (URL + Auth-Token inputs) into released YTKACE's native settings page, before its footer. Uses YTKACE's own settings category (`0x796b6361`); no YTKACE source or hook registry is touched, no selector overlap. |
   | 18–19 | `YTGetReelWatchSequenceServiceImpl makeYTIReelWatchSequenceRequest:responseBlock:errorBlock:` (`@@:@@?@?`) + `…retryEnabled:responseBlock:errorBlock:` (`@@:@B@?@?`) | **Shorts feed batches** — the vertical player's `/reel/reel_watch_sequence` equivalent; surface `shorts`, sent to `/yt-reels`. |
   | 20–22 | `YTPlayerViewController playbackController:didActivateVideo:withPlaybackData:` (`v@:@@@`), `playbackControllerDidFinishPlayback:` (`v@:@`), `pauseWithStopageReason:` (`v@:i`) | Observation-only playback events (`activate` / `pause` / `finish`) to `/yt-playback`. Raw media-state transitions are deliberately not reported. |
   | 23–26 | `YTMainAppControlsOverlayView` + `YTMainAppVideoPlayerOverlayView` `layoutSubviews` (`v@:`), `setOverlayVisible:` / `setControlsOverlayVisible:` (`v@:B`) | Not fetch boundaries: player-controls chrome. Layout ticks host the launcher button at window level, constrained under the discovered settings cog (hint match in the top-right region, whole-window search fallback); visibility selectors fade it with the chrome and collapse any open menu. |
   | 27–28 | `YTAssistantServiceImpl makeRequest:refresh:responseBlock:errorBlock:` (`v@:@B@?@?`) + `…timeoutInterval:` (`v@:@B@?@?d`) | Observation-only: records the AI ("Ask"/Assistant) request/response the first time the server-gated feature is used, including the live account-configured service instance — the basis for replaying the AI request programmatically. App traffic is untouched. |
   | 29–30 | `YTStreamingPanelServiceImpl makeStreamingRequest:refresh:timeoutInterval:engagementType:valueHandler:completionHandler:` (`@@:@Bdi@?@?`) + `cancelContinuationRequestWithToken:` (`v@:@`) | Observation-only trace for the AI panel's concrete service: request dispatch (class/size/token presence), handler delivery (argument class/size), and continuation cancellation. Distinguishes dispatch failure from lost response forwarding; callbacks pass through untouched. |

   Deliberately **not** hooked: `/player` (actual video playback — it is not a
   recommendation list), comment-thread services, `/guide`, `/att/get`,
   `/log_event`, and every other non-recommendation operation. Replacements
   for boundaries whose response type is not pinned yet (teasers) are parsed
   into the observed response's own class, so a delivered object always
   matches what the original callback expected.

## Delivery pipeline (per response delivery)

1. Admission: the master toggle plus per-category toggles (Recommend feed /
   Subs-History / Search; "Video stats" is reserved) read at request time,
   mapped from the request surface (`home`, `watch`, `FE*`, `browse-teaser`,
   `browse-unknown`, `search`);
   response class must be exactly `YTIBrowseResponse` / `YTIWatchNextResponse`;
   `nil` responses and errors pass through immediately.
2. Serialize on the delivering thread (cap 8 MiB default) and fingerprint
   (sha256 prefix).
3. Dedupe: a per-key-TTL LRU of recent fingerprints collapses the multi-layer
   watch continuation path to one server call and skips identical re-fetches
   (pull-to-refresh with unchanged content) — 300 s for Recommend and
   Subs/History pages, 20 s for search; payloads already carrying the server
   marker are passed through too.
4. In-flight cap (8): excess deliveries get the original immediately.
5. Transform: POST the envelope; validate; parse the replacement into the
   observed class. A terminal-once state (`YTRCDeliveryState`) guarantees
   exactly one of {replacement, original} is delivered, on the main queue,
   regardless of reply/timeout/config races.
6. Diagnostics: metadata only — counters, request ids, byte counts,
   fingerprints, decisions, fallback reasons. Payloads are never stored.
   Export via the player menu's Settings panel; the same values are settable in YTKACE settings
   (RECOMMENDATIONS SERVER section) — both write
   `YTKACE.Recommendations.ServerURL` / `.ServerToken`
   (`NSUserDefaults`), read at invocation time.

## Server contract

Configured **base URL only** (`scheme://host[:port]`, no path — the patch
rejects path-qualified URLs; there are no alternate or legacy endpoint forms):
- `POST /yt-browse` — every browse-family page: Home (main, refresh,
  continuations), tabbed-Home category chips, teasers, and all other browse
  IDs (subscriptions, history, shorts feed, channel pages, unresolved browse).
  The envelope's `surface` field names which: `home`, the literal browse ID,
  `browse-teaser`, or `browse-unknown`.
- `POST /yt-next` — watch page and its related-list continuations (`surface: watch`).
- `POST /yt-search` — search results (`surface: search`).
- `POST /yt-reels` — Shorts feed batches from the reel watch-sequence fetch
  (`surface: shorts`; the app's `/reel/reel_watch_sequence` equivalent).
- `POST /yt-playback` — client playback observations, exactly `activate` /
  `pause` / `finish` (no legacy or alternative event names; anything else is
  rejected with HTTP 400) reported by the patch's player hooks; no payloads.
- `POST /yt-save` — explicit save requests from the player-controls menu
  (`Transcript` / `AI Summary`): `{protocolVersion:1, type:"save", videoId, ai,
  transcriptStatus}` and, when the caption fetch succeeded, the raw YouTube
  json3 caption bytes as `transcriptPayload` (base64, declared by
  `transcriptEncoding:"youtube-json3"`). Each accepted save is appended to
  `saves.jsonl` next to the server log (`--saves-log <path>` relocates it,
  `--no-saves-log` disables it).
- `GET /` — health document advertising `protocolVersion: 1` (the connection probe).

Request: §5 envelope (JSON; `payload` = untouched original protobuf, base64;
`context.videoId` for watch; `phase` = initial/refresh/continuation). The
`context` also carries request-side debug data captured at the hook: the
serialized InnerTube request (`requestClass` + base64 `requestPayload`) and
the flat fields `browseId`, `continuation`, `params`, `query`, `feedType`.
The server decodes these into a `request:` line plus decoded
continuation/params token detail; they are context only and never modify the
transform.
Response: HTTP 200 `{"protocolVersion":1,"requestId":<same>,"action":"replace",
"encoding":"protobuf-base64","payload":<complete compatible replacement>}` or
`{"protocolVersion":1,"requestId":<same>,"action":"passthrough"}`. Original
continuation tokens must be preserved inside replacements so pagination keeps
working. Anything else ⇒ original delivered. See [server.md](server.md) for
the run/test protocol and [../server/](../server/) for the reference Bun server.
The Bun server also decodes every incoming payload's protobuf wire structure
and logs the recommendations it finds (videoId + title pairs) — see
[server/README.md](server/README.md).

## Build on a provided YTKACE app

Prerequisites: macOS with Xcode (iPhoneOS SDK) for the dylib; Python 3 for
packaging/verification; Bun ≥ 1.0 to run the server and its tests. No Theos,
no ldid, no YTKACE source build.

One command — `--app` takes an expanded `.app` directory or a distributable
IPA (zip with `Payload/`, e.g. the release files on the YTKACE GitHub):

```sh
Scripts/make.sh --app /path/to/YTKACE_1.1.4_YouTube_iOS16_21.33.6.ipa
Scripts/make.sh --app /path/to/YTKACE_1.1.4_YouTube_21.42.ipa
Scripts/make.sh --app /path/to/Expanded.app
Scripts/make.sh                          # defaults to ../ytkace/IPA/YouTube_iOS16.app
Scripts/make.sh --skip-tests             # faster iterate
```

That compiles the dylib, ABI-verifies all 22 hooks against the target
executable, runs the test suite (all module/smoke/server tests), and packages
both artifacts with an auto-incrementing version:

- `dist/YTKACE_<yt>_Recommendations_vN.ipa` — dev-ATS (http:// LAN testing)
- `dist/YTKACE_<yt>_Recommendations_vN_clean.ipa` — no Info.plist change (HTTPS)

**Install the highest `_vN`.** Import into iLoader (re-signs on install);
confirm the player-controls menu button (tap the video: a semi-transparent
square below the top-right settings cog). Each IPA has a `.manifest.json` beside
it with patch/IPA hashes and the variant.

Manual steps, if you want them:

```sh
bash Scripts/build-recommendations.sh                                   # compile dylib
python3 Scripts/verify-recommendation-signatures.py APP/YouTube          # ABI check
bash Scripts/test-recommendations.sh                                     # suite
python3 Scripts/package-recommendations.py APP --allow-insecure-http-dev # dev-ATS IPA
python3 Scripts/package-recommendations.py APP --clean                   # clean IPA
bash Tools/verify-artifacts.sh dist/recommendations/YTKACERecommendations.dylib <ipa>
```

Packaging internals: app copied to a temp tree → dylib copied into
`Frameworks/` → `LC_LOAD_DYLIB` appended to the executable → ad-hoc re-sign →
optional ATS dev exception → zip → source app + YTKACE hashes re-verified
unchanged → manifest written. The app you point at is never modified.

## Repo layout

```text
Tweak/Features/Recommendations/   the patch dylib sources (Runtime, Codec,
                                  Client, Delivery, Hooks)
Scripts/                          build engine: make.sh (one-shot),
                                  build/test/verify/package steps
Tools/                            macho_inject + class-dump inspector (used by
                                  the engine), artifact verifier, python mock
                                  server (CI contract reference)
server/                           the Bun transform server (self-contained)
Tests/                            host module checks, end-to-end smoke, server
                                  contract tests
docs/                             overview.md (this file), server.md (run/test
                                  protocol), ytprotocol.md (InnerTube payload
                                  structure, renderer cards, continuation tokens)
```

Compatibility: the 22 hook ABIs are pinned per YouTube build — re-run
`Scripts/verify-recommendation-signatures.py` against any new supplied app
before packaging; hooks fail closed on mismatch, leaving the app stock.
