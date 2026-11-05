#!/bin/bash
# Builds Snapframe.app (universal arm64 + x86_64), signs it and zips it into dist/.
# Usage: scripts/build-app.sh [--native] [--public]
#   --native  host architecture only, faster for local testing
#   --public  ignore the local build config: no update feed, ad-hoc signature
#
# Optional settings come from the environment or from a local file that is never part of the repo,
# ${SNAPFRAME_BUILD_CONFIG:-~/.config/snapframe/build.env} (sourced as bash):
#   SNAPFRAME_SIGN_IDENTITY            codesign identity; a stable one lets macOS keep permissions across updates
#   SNAPFRAME_SIGN_KEYCHAIN            keychain holding that identity (optional)
#   SNAPFRAME_SIGN_KEYCHAIN_PASSWORD   unlocks that keychain (optional)
#   SNAPFRAME_UPDATE_URL               https URL of a self-hosted update.json; empty = no updater in the build
# Without an identity the app is signed ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

NATIVE=0 PUBLIC=0
for arg in "$@"; do
  case "$arg" in
    --native) NATIVE=1 ;;
    --public) PUBLIC=1 ;;
    *) echo "usage: scripts/build-app.sh [--native] [--public]" >&2; exit 2 ;;
  esac
done
if [[ $PUBLIC == 1 ]]; then
  unset SNAPFRAME_SIGN_IDENTITY SNAPFRAME_SIGN_KEYCHAIN SNAPFRAME_SIGN_KEYCHAIN_PASSWORD SNAPFRAME_UPDATE_URL
else
  CONFIG="${SNAPFRAME_BUILD_CONFIG:-$HOME/.config/snapframe/build.env}"
  # shellcheck source=/dev/null
  if [[ -f "$CONFIG" ]]; then source "$CONFIG"; fi
fi

VERSION="${SNAPFRAME_VERSION:-0.1.4}"
BUILD="${SNAPFRAME_BUILD:-$(date +%Y%m%d%H%M)}"
APP="dist/Snapframe.app"

if [[ $NATIVE == 1 ]]; then
  swift build -c release --product Snapframe
  BIN="$(swift build -c release --show-bin-path)/Snapframe"
else
  swift build -c release --product Snapframe --triple arm64-apple-macosx15.0
  swift build -c release --product Snapframe --triple x86_64-apple-macosx15.0
  mkdir -p .build/universal
  lipo -create .build/arm64-apple-macosx/release/Snapframe .build/x86_64-apple-macosx/release/Snapframe \
       -output .build/universal/Snapframe
  BIN=".build/universal/Snapframe"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snapframe"
UPDATE_URL="${SNAPFRAME_UPDATE_URL:-}"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s|__UPDATE_URL__|$UPDATE_URL|" \
    scripts/Info.plist > "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

SIGN_ID="${SNAPFRAME_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_ID" ]]; then
  KEYCHAIN_ARGS=()
  if [[ -n "${SNAPFRAME_SIGN_KEYCHAIN:-}" ]]; then
    if [[ -n "${SNAPFRAME_SIGN_KEYCHAIN_PASSWORD:-}" ]]; then
      security unlock-keychain -p "$SNAPFRAME_SIGN_KEYCHAIN_PASSWORD" "$SNAPFRAME_SIGN_KEYCHAIN"
    fi
    KEYCHAIN_ARGS=(--keychain "$SNAPFRAME_SIGN_KEYCHAIN")
  fi
  codesign --force --sign "$SIGN_ID" "${KEYCHAIN_ARGS[@]}" --timestamp=none \
           --entitlements scripts/Snapframe.entitlements "$APP"
  echo "Signed with \"$SIGN_ID\""
else
  echo "note: no SNAPFRAME_SIGN_IDENTITY, using an ad-hoc signature" >&2
  codesign --force --sign - --entitlements scripts/Snapframe.entitlements "$APP"
fi
codesign --verify --verbose=1 "$APP"

(cd dist && rm -f Snapframe.zip && ditto -c -k --keepParent Snapframe.app Snapframe.zip)
lipo -info "$APP/Contents/MacOS/Snapframe"
echo "Built $APP ($VERSION build $BUILD) and dist/Snapframe.zip${UPDATE_URL:+ (with update feed)}"
