#!/bin/bash
# 疏朗 · 可复现的 release 构建与 .app 组装
# 用法: ./Scripts/build-app.sh [输出目录，默认 ./build]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-$ROOT/build}"
APP="$OUT/疏朗.app"
VERSION="$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/ShulangCore/Version.swift)"
BUILD_NUMBER="${VERSION//./}"

echo "==> 1/5 单元测试"
swift test --disable-sandbox -j 1 >/dev/null

echo "==> 2/5 Release 编译（universal2: arm64 + x86_64）"
swift build -c release --disable-sandbox -j 1 --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --disable-sandbox --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null | tail -1)"
test -x "$BIN/Shulang" || { echo "缺少主可执行文件"; exit 1; }
test -x "$BIN/shulang-cli" || { echo "缺少 CLI 可执行文件"; exit 1; }
# 主可执行必须真正是 GUI 程序：含界面类名，且不含 CLI 用法字符串。
# APFS 大小写不敏感时曾出现 CLI 覆盖 GUI 的事故，这里做双向特征校验。
if ! grep -aq "ShulangApp" "$BIN/Shulang"; then
  echo "错误：主可执行文件缺少 GUI 特征（可能被 CLI 覆盖）"; exit 1
fi
if grep -aq "shulang volumes" "$BIN/Shulang"; then
  echo "错误：主可执行文件包含 CLI 特征（大小写冲突导致覆盖）"; exit 1
fi

echo "==> 3/5 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"
cp "$BIN/Shulang" "$APP/Contents/MacOS/Shulang"
cp "$BIN/shulang-cli" "$OUT/shulang"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>疏朗</string>
  <key>CFBundleName</key><string>疏朗</string>
  <key>CFBundleExecutable</key><string>Shulang</string>
  <key>CFBundleIdentifier</key><string>app.shulang.macos</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>NSSupportsAutomaticTermination</key><true/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Shulang contributors. Licensed under Apache-2.0.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 4/5 Ad-hoc 签名（开源构建不含 Developer ID，README 已说明）"
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null
codesign --verify --deep --strict --verbose=0 "$APP"

echo "==> 5/5 SPDX SBOM 与产物校验"
python3 "$ROOT/Scripts/generate-sbom.py" "$OUT/SBOM.spdx.json" >/dev/null
file "$APP/Contents/MacOS/Shulang"
shasum -a 256 "$APP/Contents/MacOS/Shulang" "$APP/Contents/Resources/AppIcon.icns" \
  "$OUT/shulang" "$OUT/SBOM.spdx.json" > "$OUT/SHA256SUMS.txt"
echo "构建完成：$APP"
echo "CLI：$OUT/shulang"
cat "$OUT/SHA256SUMS.txt"
