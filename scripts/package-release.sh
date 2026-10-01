#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Power View.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUTPUT="$PWD/dist/releases"
BASENAME="Power-View-${VERSION}-macOS-arm64"
mkdir -p "$OUTPUT"
codesign --verify --deep --strict "$APP"
for binary in "$APP/Contents/MacOS/PowerView" "$APP/Contents/Helpers/PowerFanHelper"; do
    [[ "$(lipo -archs "$binary")" == "arm64" ]] || { echo "Expected arm64-only binary: $binary" >&2; exit 1; }
done
# ditto preserves the app bundle, resource metadata, and executable permissions.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$BASENAME.zip"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/power-view-package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Power View.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Power View" -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT/$BASENAME.dmg"
APP_VERSION="$VERSION" RELEASE_OUTPUT="$OUTPUT" python3 - <<'PY'
import json, os, pathlib, subprocess
sha = os.environ.get('GITHUB_SHA')
if not sha:
    sha = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip() or 'local'
data = {'version': os.environ['APP_VERSION'], 'commit': sha, 'architecture': 'arm64',
        'minimum_macos': '14.0', 'signing': 'ad-hoc', 'notarized': False,
        'run_id': os.environ.get('GITHUB_RUN_ID')}
pathlib.Path(os.environ['RELEASE_OUTPUT'], 'build-info.json').write_text(json.dumps(data, indent=2)+'\n')
PY
(cd "$OUTPUT" && shasum -a 256 "$BASENAME.zip" "$BASENAME.dmg" build-info.json > SHA256SUMS.txt)
echo "Release assets: $OUTPUT"
