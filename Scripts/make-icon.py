#!/usr/bin/env python3
"""疏朗 AppIcon 构建脚本（可复现，仅依赖 Pillow + 系统 iconutil）。

Resources/AppIcon-source.png 为图像模型生成的原始素材（右下角带生成水印）；
Resources/AppIcon-1024.png 是已用内容感知修复去除水印后的正式 1024 源图，
已随仓库提交。本脚本只负责把它转换成标准 macOS iconset 与 icns。

手动重做源图时的去水印步骤（需要 opencv-python / numpy）：
    mask = 右下角 (852, 928)–(1024, 1024) 内灰度 > 118 的像素，膨胀后
    cv2.inpaint(img, mask, 7, cv2.INPAINT_TELEA)
"""
from pathlib import Path
from PIL import Image
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "Resources"
SOURCE = RES / "AppIcon-1024.png"

SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}


def main():
    if not SOURCE.exists():
        print(f"缺少图标源图：{SOURCE}", file=sys.stderr)
        sys.exit(1)
    img = Image.open(SOURCE).convert("RGB")
    if img.size != (1024, 1024):
        print(f"源图尺寸应为 1024x1024，实际 {img.size}", file=sys.stderr)
        sys.exit(1)

    iconset = RES / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()
    for name, size in SIZES.items():
        img.resize((size, size), Image.LANCZOS).save(iconset / name, "PNG")

    out = RES / "AppIcon.icns"
    if out.exists():
        out.unlink()
    result = subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print("iconutil 失败:", result.stderr, file=sys.stderr)
        sys.exit(1)
    print(f"已生成 {iconset.name}/（{len(SIZES)} 个尺寸）")
    print(f"已生成 {out.name}（{out.stat().st_size} bytes）")


if __name__ == "__main__":
    main()
