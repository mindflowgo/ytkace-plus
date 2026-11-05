#!/usr/bin/env bash
# One-shot build engine for the recommendations patch (ytkace-plus).
#
#   Scripts/make.sh [--app PATH] [--skip-tests]
#
# --app accepts either an expanded .app directory or a distributable .ipa
# (a zip with a Payload/ directory containing the app — e.g. the release
# files published on the YTKACE GitHub, like
# YTKACE_1.1.4_YouTube_iOS16_21.33.6.ipa).
#
# Steps: compile the dylib -> verify all hook ABIs against the target
# executable -> run the host + server test suite -> package the dev-ATS IPA
# (for http:// LAN testing) and the clean IPA (for HTTPS), auto-incrementing
# the _vN version -> verify the artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/../ytkace/IPA/YouTube_iOS16.app"
SKIP_TESTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Resolve the app directory from either a .app or a .ipa input.
EXTRACTED=""
if [[ "$APP" == *.ipa ]]; then
  [[ -f "$APP" ]] || { echo "IPA not found: $APP" >&2; exit 2; }
  EXTRACTED="$ROOT/.build/extracted-app"
  rm -rf "$EXTRACTED"
  mkdir -p "$EXTRACTED"
  echo "== extracting IPA: $APP"
  unzip -q "$APP" -d "$EXTRACTED"
  APP="$(find "$EXTRACTED/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
  [[ -n "$APP" ]] || { echo "no .app found in Payload/ inside the IPA" >&2; exit 2; }
else
  [[ -d "$APP" ]] || { echo "app not found: $APP (pass --app /path/to/app.ipa or /path/to/Expanded.app)" >&2; exit 2; }
fi
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"

echo "== target app: $APP"
echo "== [1/5] compile dylib"
bash "$ROOT/Scripts/build-recommendations.sh" "$ROOT/dist/recommendations"

echo "== [2/5] verify hook ABIs against the target executable"
python3 "$ROOT/Scripts/verify-recommendation-signatures.py" "$APP/$EXECUTABLE"

echo "== [3/5] test suite (host module checks, client<->server smoke, python)"
if [[ "$SKIP_TESTS" == "1" ]]; then
  echo "   skipped (--skip-tests)"
else
  bash "$ROOT/Scripts/test-recommendations.sh"
fi

echo "== [4/5] package IPAs (auto-incrementing _vN)"
DEV_IPA="$(python3 "$ROOT/Scripts/package-recommendations.py" "$APP" --allow-insecure-http-dev | tail -1)"
CLEAN_IPA="$(python3 "$ROOT/Scripts/package-recommendations.py" "$APP" --clean | tail -1)"

echo "== [5/5] verify artifacts"
bash "$ROOT/Tools/verify-artifacts.sh" "$ROOT/dist/recommendations/YTKACERecommendations.dylib" "$DEV_IPA"

if [[ -n "$EXTRACTED" ]]; then rm -rf "$EXTRACTED"; fi

echo
echo "== done"
echo "   dev-ATS (http LAN testing): $DEV_IPA"
echo "   clean (HTTPS endpoints):    $CLEAN_IPA"
echo "   install the highest _vN via your sideloader (iLoader re-sign required)"
