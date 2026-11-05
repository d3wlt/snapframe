#!/bin/bash
# Builds a signed universal Snapframe and publishes it to a self-hosted update feed folder (serve it over HTTPS
# yourself; the build needs SNAPFRAME_UPDATE_URL, see build-app.sh). Writes a versioned zip + update.json
# (atomically) and keeps the 3 newest zips.
# Usage: scripts/publish-update.sh ["release notes"]   (set SNAPFRAME_VERSION to bump the version)
set -euo pipefail
cd "$(dirname "$0")/.."

FEED="${SNAPFRAME_FEED_DIR:-$PWD/updates}"
NOTES="${1:-}"

scripts/build-app.sh
APP="dist/Snapframe.app"
# Refuse ad-hoc builds: installed copies verify updates against the signing certificate.
if ! codesign -dr - "$APP" 2>&1 | grep -q "certificate leaf"; then
  echo "error: $APP is ad-hoc signed; updates must be signed with a stable identity (SNAPFRAME_SIGN_IDENTITY)" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c "Print :SnapframeUpdateURL" "$APP/Contents/Info.plist" 2>/dev/null)" != https://* ]]; then
  echo "error: no https update URL in this build (set SNAPFRAME_UPDATE_URL)" >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

mkdir -p "$FEED"
ZIP="Snapframe-$VERSION-$BUILD.zip"
cp dist/Snapframe.zip "$FEED/$ZIP.tmp" && mv "$FEED/$ZIP.tmp" "$FEED/$ZIP"
SHA=$(shasum -a 256 "$FEED/$ZIP" | awk '{print $1}')

python3 - "$FEED" "$VERSION" "$BUILD" "$ZIP" "$SHA" "$NOTES" <<'PY'
import json, os, sys
feed, version, build, zipname, sha, notes = sys.argv[1:]
m = {"version": version, "build": build, "url": zipname, "sha256": sha}
if notes: m["notes"] = notes
tmp = os.path.join(feed, "update.json.tmp")
with open(tmp, "w") as f: json.dump(m, f, indent=2)
os.replace(tmp, os.path.join(feed, "update.json"))
PY

ls -t "$FEED"/Snapframe-*.zip 2>/dev/null | tail -n +4 | while read -r old; do rm -f "$old"; done
echo "Published Snapframe $VERSION ($BUILD) to $FEED"
cat "$FEED/update.json"
