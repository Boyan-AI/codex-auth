#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/../.." && pwd)"

BUILD_ROOT="${CODEX_AUTH_APP_BUILD_ROOT:-${TMPDIR:-/tmp}/codex-auth-menu-app-build}"
APP_BUNDLE="${CODEX_AUTH_APP_BUNDLE_PATH:-$BUILD_ROOT/Codex Switch.app}"
SWIFT_BUILD_DIR="$BUILD_ROOT/swift"
ZIG_INSTALL_DIR="$BUILD_ROOT/zig-install"
ZIG_CACHE_DIR="$BUILD_ROOT/zig-cache"
ZIG_GLOBAL_CACHE_DIR="$BUILD_ROOT/zig-global-cache"
ICON_SOURCE="$APP_DIR/Resources/AppIconSource.png"

echo "Building codex-auth CLI..."
zig build \
  --cache-dir "$ZIG_CACHE_DIR" \
  --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
  -p "$ZIG_INSTALL_DIR"

echo "Building Codex Switch menu app..."
swift build \
  --package-path "$APP_DIR" \
  --scratch-path "$SWIFT_BUILD_DIR" \
  -c release \
  --product CodexAuthApp

echo "Packaging app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$SWIFT_BUILD_DIR/release/CodexAuthApp" "$APP_BUNDLE/Contents/MacOS/CodexAuthApp"
cp "$ZIG_INSTALL_DIR/bin/codex-auth" "$APP_BUNDLE/Contents/Resources/codex-auth"
cp "$SCRIPT_DIR/configure-newapi-cpa-channel.sh" "$APP_BUNDLE/Contents/Resources/configure-newapi-cpa-channel.sh"
cp "$SCRIPT_DIR/runtime-update.sh" "$APP_BUNDLE/Contents/Resources/runtime-update.sh"
chmod +x \
  "$APP_BUNDLE/Contents/MacOS/CodexAuthApp" \
  "$APP_BUNDLE/Contents/Resources/codex-auth" \
  "$APP_BUNDLE/Contents/Resources/configure-newapi-cpa-channel.sh" \
  "$APP_BUNDLE/Contents/Resources/runtime-update.sh"

echo "Generating app icon..."
swift "$SCRIPT_DIR/generate-icon.swift" "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Switch</string>
  <key>CFBundleExecutable</key>
  <string>CodexAuthApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.loongphy.codex-auth.menu</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Switch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# 为本地构建的 App Bundle 生成一致的临时签名，确保 Finder 和 Launch Services 能识别启动入口。
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

echo "$APP_BUNDLE"
