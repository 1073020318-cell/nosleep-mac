#!/bin/bash
# ============================================================
#  合盖不休眠 — 构建脚本
#
#  用法：
#    ./scripts/build.sh        # 编译并打包 .app（Intel + Apple 芯片通用）
#    ./scripts/build.sh dmg    # 编译并创建 DMG 安装包
#
#  只需要 Xcode 命令行工具（xcode-select --install），不需要 Python。
# ============================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="合盖不休眠"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MIN_MACOS="11.0"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Resources/Info.plist")

echo "🔧 开始构建 $APP_NAME v$VERSION..."

# 1. 清理
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 2. 编译（分别编译两种架构再合并；必须指定最低系统版本，
#    否则 swiftc 默认以构建机的系统版本为最低要求，旧系统打不开）
for ARCH in arm64 x86_64; do
    echo "📝 编译 menulet ($ARCH)..."
    swiftc -O -swift-version 5 \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -o "$TMP_DIR/menulet_$ARCH" \
        "$PROJECT_DIR/Sources/menulet.swift" \
        -framework Cocoa -framework IOKit -framework ServiceManagement -framework UserNotifications
done
lipo -create "$TMP_DIR/menulet_arm64" "$TMP_DIR/menulet_x86_64" -output "$APP_DIR/Contents/MacOS/menulet"
chmod +x "$APP_DIR/Contents/MacOS/menulet"

# 3. 配置
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# 4. 图标（用系统自带的 sips，不需要 Pillow）
ICON_SRC="$PROJECT_DIR/Resources/AppIcon.jpg"
[ -f "$ICON_SRC" ] || ICON_SRC="$PROJECT_DIR/Resources/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    echo "🎨 生成图标..."
    ICONSET="$TMP_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for S in 16 32 128 256 512; do
        sips -s format png -z $S $S "$ICON_SRC" --out "$ICONSET/icon_${S}x${S}.png" >/dev/null
        sips -s format png -z $((S * 2)) $((S * 2)) "$ICON_SRC" --out "$ICONSET/icon_${S}x${S}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "⚠️ 没找到图标源文件，跳过"
fi

# 5. 签名（ad-hoc）
echo "✍️ 签名..."
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
if codesign --verify --deep --strict "$APP_DIR"; then echo "✅ 签名验证通过"; else echo "❌ 签名验证失败"; exit 1; fi

echo ""
echo "✅ 构建完成！"
echo "   App: $APP_DIR"
echo "   架构: $(lipo -archs "$APP_DIR/Contents/MacOS/menulet")"
echo "   大小: $(du -sh "$APP_DIR" | cut -f1)"

# 6. 可选：创建 DMG
if [ "${1:-}" = "dmg" ]; then
    echo ""
    echo "📦 创建 DMG 安装包..."
    DMG_PATH="$BUILD_DIR/${APP_NAME}_v${VERSION}.dmg"
    STAGING="$TMP_DIR/dmg"
    mkdir -p "$STAGING"
    cp -R "$APP_DIR" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    [ -f "$PROJECT_DIR/Resources/使用说明.txt" ] && cp "$PROJECT_DIR/Resources/使用说明.txt" "$STAGING/"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
    echo "✅ DMG 创建完成：${DMG_PATH}（$(du -sh "$DMG_PATH" | cut -f1)）"
fi
