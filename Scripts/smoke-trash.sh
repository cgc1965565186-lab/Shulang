#!/bin/bash
# P0-A1 冒烟：即便强制扫描隐藏目录，废纸篁内容也不得成为清理候选，
# 且正常缓存仍应被识别（防止保护规则误伤）。退出码 0 = 通过。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/build/shulang"
FIX=/tmp/shulang-trash-smoke

test -x "$CLI" || { echo "缺少 CLI：$CLI"; exit 1; }
rm -rf "$FIX"
mkdir -p "$FIX/.Trash" "$FIX/Library/Caches" "$FIX/Downloads"
dd if=/dev/zero of="$FIX/.Trash/old-installer.dmg" bs=1024 count=40 2>/dev/null
dd if=/dev/zero of="$FIX/Library/Caches/demo-cache.bin" bs=1024 count=80 2>/dev/null
dd if=/dev/zero of="$FIX/Downloads/old.dmg" bs=1024 count=20 2>/dev/null

SCAN="$("$CLI" scan "$FIX" --hidden --enumerator foundation)"
printf '%s' "$SCAN" | grep -q '文件 3 项' || { echo "FAIL 隐藏目录未被扫描：$SCAN"; exit 1; }
printf '%s' "$SCAN" | grep -q '140.0 KB' || { echo "FAIL 扫描总量不含废纸篁：$SCAN"; exit 1; }

OUT="$("$CLI" candidates "$FIX" --hidden --include-risky)"
if printf '%s' "$OUT" | grep -q '/.Trash/'; then
  echo "FAIL 废纸篁内容被列为候选：$OUT"; exit 1
fi
if ! printf '%s' "$OUT" | grep -q 'Library/Caches/demo-cache.bin'; then
  echo "FAIL 正常缓存被误伤：$OUT"; exit 1
fi
rm -rf "$FIX"
echo "PASS 强制扫描隐藏目录：废纸篁不可清理、正常缓存仍可识别"
