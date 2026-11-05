#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/.build/recommendations"

# Foundation-only module sources (runtime, codec, client protocol, delivery
# state) compiled against the macOS SDK for host checks.
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra \
  -Wno-unused-parameter -Wno-nonnull -framework Foundation \
  "$ROOT/Tweak/Features/Recommendations/RecommendationRuntime.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationCodec.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationClient.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationDelivery.mm" \
  "$ROOT/Tests/recommendation_runtime.mm" \
  -o "$ROOT/.build/recommendations/module-tests"
"$ROOT/.build/recommendations/module-tests"

# Payload-modifier unit tests (pure wire/shelf functions, no server).
if command -v bun >/dev/null 2>&1; then
  bun test "$ROOT/Tests/payload_modifier.test.ts"
fi

# All Python tests: mock-server contract, bun-server contract, tooling
# (run once, after the end-to-end smoke below).

# End-to-end: the real client against the real mock server on localhost.
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra \
  -Wno-unused-parameter -Wno-nonnull -framework Foundation \
  "$ROOT/Tweak/Features/Recommendations/RecommendationRuntime.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationCodec.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationClient.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationDelivery.mm" \
  "$ROOT/Tests/recommendation_client_smoke.mm" \
  -o "$ROOT/.build/recommendations/client-smoke"
"$ROOT/Tools/mock-recommendation-server.py" --host 127.0.0.1 --port 18362 --action replace \
  > "$ROOT/.build/recommendations/mock-server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "mock-recommendation-server on" "$ROOT/.build/recommendations/mock-server.log" 2>/dev/null; then break; fi
  sleep 0.2
done
REC_SERVER_URL="http://127.0.0.1:18362" REC_SERVER_TOKEN="smoke-test-token" \
  "$ROOT/.build/recommendations/client-smoke"

python3 -m unittest discover -s "$ROOT/Tests" -p 'test_*.py'
