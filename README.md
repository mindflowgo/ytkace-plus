# ytkace-plus

An independent, additive patch (`YTKACERecommendations.dylib`) over a supplied
released **YTKACE** app: YouTube's video recommendation responses — Home feed,
category chips, subscriptions/history/other browse feeds, search results, the
watch page and its related list, feed teasers — are posted to your own server,
and the server's validated replacement is what YouTube parses and renders. Any
failure delivers the original response: worst case, the stock app. Playback
(`/player`) is never touched.

- **How it works, injection points, build** → [docs/overview.md](docs/overview.md)
- **YouTube payload structure, card formats, continuation tokens** → [docs/ytprotocol.md](docs/ytprotocol.md)
- **Run the server, configure the phone, verify** → [docs/server.md](docs/server.md) and [server/](server/)

## Build

Requires macOS with Xcode (iPhoneOS SDK); Python 3; Bun to run the server and
its tests. No Theos, no ldid, no YTKACE source build.

`--app` takes either an expanded `.app` directory or a distributable **IPA**
(the zip-with-`Payload/` files published on the YTKACE GitHub releases):

```sh
Scripts/make.sh --app /path/to/YTKACE_1.1.4_YouTube_iOS16_21.33.6.ipa
Scripts/make.sh --app /path/to/YTKACE_1.1.4_YouTube_21.42.ipa
Scripts/make.sh --app /path/to/Expanded.app          # also fine
Scripts/make.sh                                       # defaults to ../ytkace/IPA/YouTube_iOS16.app
Scripts/make.sh --app <path> --skip-tests            # faster iterate
```

`make.sh` compiles the dylib, ABI-verifies all hooks against the target
executable, runs the test suite, and packages:

- `dist/YTKACE_<yt>_Recommendations_vN.ipa` — dev-ATS build (accepts `http://`
  LAN server URLs; this is the one to test with)
- `dist/YTKACE_<yt>_Recommendations_vN_clean.ipa` — no Info.plist change (HTTPS)

**Install the highest `_vN`** via your sideloader (iLoader re-sign). Each build
writes a `.manifest.json` with the patch/IPA hashes.

## Run the server

```sh
cd server
bun run start                       # logs to bun-server.log; tail -f it
```

Each decoded page logs its structure and the recommendations YouTube returned
(videoId + title pairs). Configure the patch on the phone with the **base URL
only** (`http://<mac-ip>:8046` — no path; the client appends `/yt-browse`,
`/yt-next`, `/yt-search` itself).

## Scope

Intercepted and sent to the server: all `/browse`-family pages (Home, tab
chips, subscriptions, history, other browse IDs, teasers, unresolved browse),
watch page + related-list pages, and search results. Not intercepted:
`/player` (actual video playback) and comment-thread services — those keep
stock behavior.

The original `../ytkace` checkout stays unmodified; consult it for the
discovery history (probe sessions, symbolized evidence) that pinned the
injection points.
