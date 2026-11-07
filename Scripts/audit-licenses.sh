#!/bin/bash
# 开源许可证门禁（P0-A）：禁止强 copyleft / 非商业 / 无 LICENSE 项目的代码或依赖进入仓库。
# 命中任一禁止项即 exit 1；CI 与 verify-app.sh 均调用本脚本。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0

# 只借鉴设计、绝不复制或链接的仓库（许可证原文结论见 docs/OPEN_SOURCE_AUDIT.md）
BLOCKED_REPOS=(
  "Tencent/lemon-cleaner"          # LemonDaemon GPL-2.0，其余 GPL-3.0
  "harry0703/MangoDisk"            # GPL-3.0
  "tkslucas/Neodisk"               # GPL-3.0
  "arsenetar/dupeguru"             # GPL-3.0
  "shundhammer/qdirstat"           # GPL-2.0
  "alienator88/Pearcleaner"        # Apache-2.0 with Commons Clause，禁止 Sell
  "AlexGladkov/Spacie"             # Non-Commercial License
  "Ratiug-99/disk-space-analyzer"  # 无 LICENSE 文件
  "sevmorris/maclean"              # 仓库 404，不得引用
)

# 允许的 import：Apple 系统框架、本仓模块、测试框架、标准工具模块。
# 新增任何第三方模块都必须先经人工审计并加入白名单，避免静默引入依赖。
ALLOWED_MODULES='^(Foundation|SwiftUI|AppKit|Quartz|CryptoKit|Observation|Darwin|CoreGraphics|CoreServices|Combine|os|UniformTypeIdentifiers|Security|ServiceManagement|SQLite3|XCTest|ShulangCore|Shulang|ShulangCLI|ImageIO|Accelerate|NaturalLanguage)$'

echo "== 1. 依赖清单检查 =="
if [ -f "$ROOT/Package.resolved" ]; then
  for repo in "${BLOCKED_REPOS[@]}"; do
    if grep -qi "$repo" "$ROOT/Package.resolved"; then
      echo "  FAIL  Package.resolved 命中禁止依赖：$repo"
      FAIL=1
    fi
  done
  echo "  PASS  Package.resolved 无禁止依赖"
else
  echo "  PASS  当前为零第三方 SwiftPM 依赖（无 Package.resolved）"
fi

echo "== 2. 源码 import 白名单检查 =="
IMPORT_LINES="$(grep -rhoE '^import [A-Za-z0-9_]+' "$ROOT/Sources" "$ROOT/Tests" 2>/dev/null || true)"
if [ -n "$IMPORT_LINES" ]; then
  while IFS= read -r line; do
    module="${line#import }"
    [ -z "$module" ] && continue
    if ! printf '%s\n' "$module" | grep -qE "$ALLOWED_MODULES"; then
      echo "  FAIL  未经审计的模块：${module}（请更新 docs/OPEN_SOURCE_AUDIT.md 与白名单）"
      FAIL=1
    fi
  done <<< "$IMPORT_LINES"
fi
[ "$FAIL" -eq 0 ] && echo "  PASS  所有 import 均为系统框架或本仓模块"

echo "== 3. 禁止仓库名作为依赖引用检查 =="
for repo in "${BLOCKED_REPOS[@]}"; do
  owner="${repo%%/*}"
  name="${repo##*/}"
  if grep -rqE "(github\.com/$repo|/$name\.git|package\(.*$owner)" \
      "$ROOT/Package.swift" "$ROOT/Sources" "$ROOT/Tests" 2>/dev/null; then
    echo "  FAIL  源码或清单中出现禁止仓库引用：$repo"
    FAIL=1
  fi
done
[ "$FAIL" -eq 0 ] && echo "  PASS  源码与清单无禁止仓库引用"

echo "== 4. 借鉴标注检查 =="
if grep -rq "设计参考:" "$ROOT/Sources"; then
  echo "  PASS  借鉴标注存在：$(grep -rl '设计参考:' "$ROOT/Sources" | wc -l | tr -d ' ') 个文件"
else
  echo "  INFO  当前源码无借鉴标注（若后续引入算法参考需补充）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "许可证审计通过。"
else
  echo "许可证审计未通过，禁止合入。"
fi
exit "$FAIL"
