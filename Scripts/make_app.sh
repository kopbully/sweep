#!/bin/zsh
# Build Sweep.app bundle（默认用本地固定证书签名，见 Scripts/setup_signing.sh）
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
    <string>0.6.5</string>
    <key>CFBundleShortVersionString</key>
    <string>0.6.5</string>
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
    <key>NSDesktopFolderUsageDescription</key>
    <string>Sweep 需要读取桌面以统计大文件与重复文件；只在你打开的模块里使用，不上传任何内容。</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Sweep 需要读取文稿以统计大文件与重复文件；只在你打开的模块里使用，不上传任何内容。</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Sweep 需要读取下载目录以找出安装包与重复文件；只在你打开的模块里使用，不上传任何内容。</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Sweep 仅在你选择外接磁盘做空间分析时读取该磁盘。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>少数维护动作（刷新 DNS、修剪系统日志）需要提权执行一条命令；点击后系统会请求一次密码。</string>
</dict>
</plist>
PLIST

# 稳定签名：固定证书让 TCC 授权可跨重打包复用；没有证书时退回 ad-hoc。
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Sweep Local Signing"; then
    codesign --force --sign "Sweep Local Signing" --identifier com.sweep.macos "$APP"
    echo "🔏 签名身份：Sweep Local Signing"
else
    codesign --force --sign - "$APP"
    echo "🔏 签名身份：ad-hoc（运行 Scripts/setup_signing.sh 可改用固定证书）"
fi
echo "✅ Built $APP — 双击运行，或: open $APP"
