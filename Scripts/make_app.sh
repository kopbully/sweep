#!/bin/zsh
# Build Sweep.app bundle (ad-hoc signed)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
swift build --disable-sandbox --cache-path .build/cache -c "$CONFIG" 2>&1 | tail -5

BINARY=".build/${CONFIG}/Sweep"
APP="Sweep.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/Sweep"
mkdir -p "$APP/Contents/Resources"
ditto "Sources/Sweep/Resources/BlackHole" "$APP/Contents/Resources/BlackHole"
ditto "Sources/Sweep/Resources/ThirdParty" "$APP/Contents/Resources/ThirdParty"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Sweep</string>
    <key>CFBundleDisplayName</key>
    <string>Sweep</string>
    <key>CFBundleIdentifier</key>
    <string>com.sweep.macos</string>
    <key>CFBundleVersion</key>
    <string>0.6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Sweep</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "✅ Built $APP — 双击运行，或: open $APP"
