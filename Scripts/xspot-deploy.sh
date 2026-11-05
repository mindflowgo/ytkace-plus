#!/usr/bin/env bash
# Deploy the recommendations IPA to XSpot (iPhone 8 Plus)
#
# Usage:
#   Scripts/xspot-deploy.sh                 # deploys the newest IPA in dist/
#   Scripts/xspot-deploy.sh path/to/app.ipa # deploys an explicit IPA
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Target device (XSpot) & Developer signing settings
DEVICE_UDID="${DEVICE_UDID:-a0db1cb93df7b788df78d121301d97c4ba6c2888}"
TEAM_ID="${TEAM_ID:-U5492M2JQ5}"
BUNDLE_ID="${BUNDLE_ID:-com.google.ios.youtube.$TEAM_ID}"
SIGN_ID="${SIGN_IDENTITY:-Apple Development: Filipe Laborde-Basto (28NLHDL7UD)}"
PROFILE="${PROVISIONING_PROFILE:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/b87e9fd1-00bc-4013-9444-17c2fcc3dfc8.mobileprovision}"

# Check prerequisites
command -v ios-deploy >/dev/null 2>&1 || {
  echo "Error: 'ios-deploy' is required but not installed." >&2
  exit 1
}
[[ -f "$PROFILE" ]] || {
  echo "Error: Provisioning profile not found at: $PROFILE" >&2
  exit 1
}

# Resolve target IPA
IPA="${1:-}"
if [[ -z "$IPA" ]]; then
  IPA="$(ls -t "$ROOT"/dist/*.ipa 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "Error: No IPA found to deploy (checked dist/*.ipa)" >&2
  exit 1
fi

echo "== Target IPA: $IPA"
echo "== Target Device: XSpot ($DEVICE_UDID)"
echo "== Bundle ID: $BUNDLE_ID"
echo "== Signing ID: $SIGN_ID"

WORK_DIR="$(mktemp -d -t xspot_deploy_XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "== [1/4] Extracting IPA..."
unzip -q "$IPA" -d "$WORK_DIR"
APP_PATH="$(find "$WORK_DIR/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP_PATH" ]] || {
  echo "Error: No .app bundle found in IPA Payload/" >&2
  exit 1
}

echo "== [2/4] Configuring Bundle ID & Entitlements..."
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Info.plist"
cp "$PROFILE" "$APP_PATH/embedded.mobileprovision"

security cms -D -i "$APP_PATH/embedded.mobileprovision" > "$WORK_DIR/profile.plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK_DIR/profile.plist" > "$WORK_DIR/entitlements.plist"
/usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM_ID.$BUNDLE_ID" "$WORK_DIR/entitlements.plist"

# Strip App Extensions if present (wildcard profiles cannot match extension bundle IDs)
if [[ -d "$APP_PATH/PlugIns" ]]; then
  rm -rf "$APP_PATH/PlugIns"
fi

echo "== [3/4] Re-signing frameworks, dylibs, and app bundle..."
if [[ -d "$APP_PATH/Frameworks" ]]; then
  find "$APP_PATH/Frameworks" -mindepth 1 -maxdepth 1 \( -name '*.dylib' -o -name '*.framework' \) | while read -r item; do
    codesign -fs "$SIGN_ID" "$item"
  done
fi

codesign -fs "$SIGN_ID" --entitlements "$WORK_DIR/entitlements.plist" "$APP_PATH"
codesign -v "$APP_PATH"

echo "== [4/4] Deploying to XSpot..."
ios-deploy -i "$DEVICE_UDID" -b "$APP_PATH" --nostart

echo "== Successfully installed on XSpot!"
