#!/bin/bash
# ============================================================
#  合盖不休眠 — 构建脚本
#
#  用法：
#    ./scripts/build.sh        # 编译并打包 .app
#    ./scripts/build.sh dmg    # 编译并创建 DMG 安装包
# ============================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="合盖不休眠"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "🔧 开始构建 $APP_NAME..."

# 1. 清理
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 2. 创建 App Bundle 结构
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 3. 编译 menulet
echo "📝 编译 menulet.swift..."
swiftc -o "$APP_DIR/Contents/MacOS/menulet" \
    "$PROJECT_DIR/Sources/menulet.swift" \
    -framework Cocoa

# 4. 复制脚本
cp "$PROJECT_DIR/Sources/launch" "$APP_DIR/Contents/MacOS/launch"
cp "$PROJECT_DIR/Sources/backlightctl" "$APP_DIR/Contents/MacOS/backlightctl"
chmod +x "$APP_DIR/Contents/MacOS/launch"
chmod +x "$APP_DIR/Contents/MacOS/menulet"
chmod +x "$APP_DIR/Contents/MacOS/backlightctl"

# 5. 复制配置
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# 6. 生成图标
ICON_SRC="$PROJECT_DIR/Resources/AppIcon.jpg"
if [ ! -f "$ICON_SRC" ]; then
    ICON_SRC="$PROJECT_DIR/Resources/AppIcon.png"
fi

if [ -f "$ICON_SRC" ] && command -v python3 &>/dev/null; then
    echo "🎨 生成图标..."
    ICONSET_DIR="/tmp/nosleep_build_icon_$$"
    mkdir -p "$ICONSET_DIR"
    python3 << PYEOF
from PIL import Image
import subprocess, os

src = "$ICON_SRC"
iconset_dir = "$ICONSET_DIR"
app_dir = "$APP_DIR"

img = Image.open(src).convert("RGBA")
for s in [16, 32, 64, 128, 256, 512, 1024]:
    img.resize((s, s), Image.LANCZOS).save(os.path.join(iconset_dir, f"icon_{s}x{s}.png"))
    s2 = s * 2
    if s2 <= 2048:
        img.resize((s2, s2), Image.LANCZOS).save(os.path.join(iconset_dir, f"icon_{s}x{s}@2x.png"))

icns_path = os.path.join(app_dir, "Contents/Resources/AppIcon.icns")
subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", icns_path], check=True)
print(f"图标: {os.path.getsize(icns_path)//1024}KB")
PYEOF
    rm -rf "$ICONSET_DIR"
else
    echo "⚠️ 跳过图标生成（需要 python3 + Pillow）"
fi

# 7. 签名
echo "✍️ 签名..."
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"

# 8. 验证
echo "🔍 验证..."
codesign --verify --deep --strict "$APP_DIR" && echo "✅ 签名验证通过" || echo "❌ 签名验证失败"

echo ""
echo "✅ 构建完成！"
echo "   App: $APP_DIR"
echo "   大小: $(du -sh "$APP_DIR" | cut -f1)"

# 9. 可选：创建 DMG
if [ "$1" = "dmg" ]; then
    echo ""
    echo "📦 创建 DMG 安装包..."
    DMG_NAME="${APP_NAME}_v15.dmg"
    DMG_PATH="$BUILD_DIR/$DMG_NAME"
    DMG_STAGING="/tmp/dmg_staging_$$"

    rm -f "$DMG_PATH"
    mkdir -p "$DMG_STAGING"

    cp -R "$APP_DIR" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

    if [ -f "$PROJECT_DIR/Resources/使用说明.txt" ]; then
        cp "$PROJECT_DIR/Resources/使用说明.txt" "$DMG_STAGING/"
    fi

    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_PATH"

    rm -rf "$DMG_STAGING"

    echo "✅ DMG 创建完成！"
    echo "   文件: $DMG_PATH"
    echo "   大小: $(du -sh "$DMG_PATH" | cut -f1)"
fi
