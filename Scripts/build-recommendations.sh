#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/dist/recommendations}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUTPUT"

xcrun --sdk iphoneos clang++ \
  -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 \
  -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror=return-type \
  -Wno-unused-parameter -O1 -g -dynamiclib \
  "$ROOT/Tweak/Features/Recommendations/RecommendationRuntime.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationCodec.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationClient.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationDelivery.mm" \
  "$ROOT/Tweak/Features/Recommendations/RecommendationHooks.mm" \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -Wl,-install_name,@rpath/YTKACERecommendations.dylib \
  -o "$OUTPUT/YTKACERecommendations.dylib"

codesign --force --sign - "$OUTPUT/YTKACERecommendations.dylib"
xcrun lipo -info "$OUTPUT/YTKACERecommendations.dylib"
echo "$OUTPUT/YTKACERecommendations.dylib"
