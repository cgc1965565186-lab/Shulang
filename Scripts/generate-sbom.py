#!/usr/bin/env python3
"""生成 SPDX 2.3 SBOM（纯标准库，列出源码文件、许可证与校验和）。

可复现性（P0-A3）：
- 时间取自 SOURCE_DATE_EPOCH，其次 git 最新提交时间，都没有则用固定值；
  绝不使用 datetime.now()，否则每次构建的 SBOM 与 SHA256SUMS.txt 必然变化。
- documentNamespace 用「文件名 + 内容 SHA-256」的内容哈希，而非时间戳。
- 内容未变化时不重写文件，避免不必要的 mtime 变动。
"""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import subprocess
import sys
import re

ROOT = Path(__file__).resolve().parent.parent
VERSION = re.search(r'current = "([^"]+)"', (ROOT / "Sources/ShulangCore/Version.swift").read_text()).group(1)
# 允许传入临时输出路径，供自检脚本在不触碰正式产物的前提下验证确定性。
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "build" / "SBOM.spdx.json"
FALLBACK_TIME = "1970-01-01T00:00:00Z"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def reproducible_time() -> str:
    """确定性时间：环境变量 > git 提交时间 > 固定值。"""
    def fmt(epoch: int) -> str:
        return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    epoch = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    if epoch.isdigit():
        return fmt(int(epoch))
    try:
        raw = subprocess.check_output(
            ["git", "-C", str(ROOT), "log", "-1", "--format=%ct"],
            stderr=subprocess.DEVNULL, text=True, timeout=5,
        ).strip()
        if raw.isdigit():
            return fmt(int(raw))
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return FALLBACK_TIME


def main():
    files = sorted(
        [p for pattern in ("Sources/**/*.swift", "Tests/**/*.swift", "Scripts/**/*",
                           "docs/**/*.md", "*.md", "LICENSE", "NOTICE", "Package.swift")
         for p in ROOT.glob(pattern) if p.is_file()]
    )
    files = list(dict.fromkeys(files))

    now = reproducible_time()
    content_digest = hashlib.sha256()
    spdx_files, relationships = [], []
    for p in files:
        rel = p.relative_to(ROOT).as_posix()
        file_hash = sha256(p)
        content_digest.update(rel.encode("utf-8"))
        content_digest.update(file_hash.encode("ascii"))
        spdx_id = "SPDXRef-File-" + hashlib.sha1(rel.encode()).hexdigest()[:12]
        spdx_files.append({
            "SPDXID": spdx_id,
            "fileName": "./" + rel,
            "checksums": [{"algorithm": "SHA256", "checksumValue": file_hash}],
            "licenseConcluded": "Apache-2.0",
            "copyrightText": "Copyright 2026 Shulang contributors",
        })
        relationships.append({
            "spdxElementId": "SPDXRef-Package-Shulang",
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": spdx_id,
        })

    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "Shulang-" + VERSION,
        "documentNamespace": "https://shulang.app/spdx/Shulang-" + VERSION + "-" + content_digest.hexdigest()[:16],
        "creationInfo": {"created": now, "creators": ["Tool: Shulang generate-sbom.py"]},
        "documentDescribes": ["SPDXRef-Package-Shulang"],
        "packages": [{
            "SPDXID": "SPDXRef-Package-Shulang",
            "name": "Shulang",
            "versionInfo": VERSION,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": True,
            "licenseConcluded": "Apache-2.0",
            "licenseDeclared": "Apache-2.0",
            "copyrightText": "Copyright 2026 Shulang contributors",
            "supplier": "Organization: Shulang contributors",
            "externalRefs": [],
            "comment": "无第三方 SwiftPM 依赖；仅链接 Apple 系统框架（SwiftUI/AppKit/Quartz/CryptoKit/Foundation/Darwin）。",
        }],
        "files": spdx_files,
        "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT",
                           "relationshipType": "DESCRIBES",
                           "relatedSpdxElement": "SPDXRef-Package-Shulang"}] + relationships,
        "hasExtractedLicensingInfos": [],
    }
    text = json.dumps(doc, ensure_ascii=False, indent=2) + "\n"
    if not OUT.parent.exists():
        OUT.parent.mkdir(parents=True)
    try:
        label = str(OUT.relative_to(ROOT))
    except ValueError:
        label = str(OUT)  # 自检用的临时输出不在仓库内
    if OUT.exists() and OUT.read_text(encoding="utf-8") == text:
        print(f"SPDX 2.3 SBOM 内容未变化，未重写：{label}（{len(spdx_files)} 个文件）")
        return 0
    OUT.write_text(text, encoding="utf-8")
    print(f"SPDX 2.3 SBOM 已生成：{label}（{len(spdx_files)} 个文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
