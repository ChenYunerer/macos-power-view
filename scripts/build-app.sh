#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export APP_VERSION="${APP_VERSION:-$(cat VERSION)}"
export BUILD_NUMBER="${BUILD_NUMBER:-4}"
python3 - <<'PY'
import os, re
if not re.fullmatch(r'\d+\.\d+\.\d+', os.environ['APP_VERSION']):
    raise SystemExit('APP_VERSION must contain major.minor.patch')
if not re.fullmatch(r'[1-9]\d*', os.environ['BUILD_NUMBER']):
    raise SystemExit('BUILD_NUMBER must be a positive integer')
PY
# Ship Apple Silicon only; no Intel slice or Rosetta dependency.
swift build -c release --arch arm64
APP="dist/Power View.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/PowerView "$APP/Contents/MacOS/PowerView"
cp .build/release/PowerFanHelper "$APP/Contents/Helpers/PowerFanHelper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.yun.PowerView</string>
    <key>CFBundleName</key><string>Power View</string>
    <key>CFBundleDisplayName</key><string>Power View</string>
    <key>CFBundleExecutable</key><string>PowerView</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundleIconFile</key><string>PowerIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
python3 - <<'PY'
import os, pathlib, plistlib
path = pathlib.Path('dist/Power View.app/Contents/Info.plist')
with path.open('rb') as handle:
    info = plistlib.load(handle)
info['CFBundleShortVersionString'] = os.environ['APP_VERSION']
info['CFBundleVersion'] = os.environ['BUILD_NUMBER']
with path.open('wb') as handle:
    plistlib.dump(info, handle)
PY
swift scripts/make-icon.swift "$APP/Contents/Resources"
rm -f "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/Helpers/PowerFanHelper"
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
