#!/bin/bash
# 疏朗 · 交付前确定性自检（D8/D9：可复跑、不靠运行时推断、报绿前先证覆盖）
# 用法: ./Scripts/verify-app.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/疏朗.app"
CLI="$ROOT/build/shulang"
INSTALLED="/Applications/疏朗.app"
PASS=0; FAIL=0

check() { # check <名称> <命令...>
  local name="$1"; shift
  if "$@" >/tmp/shulang-verify.out 2>&1; then
    printf '  PASS  %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s\n' "$name"; sed 's/^/        /' /tmp/shulang-verify.out | head -6; FAIL=$((FAIL+1))
  fi
}
has() { grep -q "$1" "$2"; }

echo "== 1. 源码与编译 =="
check "单元测试通过" swift test --disable-sandbox -j 1
check "release universal2 编译" swift build -c release --disable-sandbox -j 1 --arch arm64 --arch x86_64
check "主程序含 GUI 特征" bash -c "grep -aq ShulangApp '$APP/Contents/MacOS/Shulang'"
check "主程序不含 CLI 特征" bash -c "! grep -aq 'shulang volumes' '$APP/Contents/MacOS/Shulang'"
check "主程序为 universal2" bash -c "lipo -info '$APP/Contents/MacOS/Shulang' | grep -q x86_64 && lipo -info '$APP/Contents/MacOS/Shulang' | grep -q arm64"

echo "== 2. 命名一致性 =="
check "Info.plist 语法合法" plutil -lint "$APP/Contents/Info.plist"
check "CFBundleName 为疏朗" bash -c "defaults read '$APP/Contents/Info' CFBundleName | grep -qx 疏朗"
check "CFBundleDisplayName 为疏朗" bash -c "defaults read '$APP/Contents/Info' CFBundleDisplayName | grep -qx 疏朗"
check "Bundle ID 为 app.shulang.macos" bash -c "defaults read '$APP/Contents/Info' CFBundleIdentifier | grep -qx app.shulang.macos"
check "CFBundleIconFile 指向 AppIcon" bash -c "defaults read '$APP/Contents/Info' CFBundleIconFile | grep -qx AppIcon"
check "CLI 名为 shulang" test -x "$CLI"
check "README 使用最终名称" bash -c "grep -q 疏朗 '$ROOT/README.md' && grep -q 'app.shulang.macos' '$ROOT/README.md'"
check "源码中无旧占位名 MacCleaner" bash -c "! grep -rq 'MacCleaner' '$ROOT/Sources'"

echo "== 3. 图标资源 =="
check "AppIcon.icns 存在且非空" test -s "$APP/Contents/Resources/AppIcon.icns"
check "iconset 含 10 个尺寸" bash -c "test \$(ls '$ROOT/Resources/AppIcon.iconset'/*.png | wc -l | tr -d ' ') -eq 10"
check "1024 源图尺寸正确" python3 -c "from PIL import Image; import sys; sys.exit(0 if Image.open('$ROOT/Resources/AppIcon-1024.png').size==(1024,1024) else 1)"
check "图标为彩色（非灰阶）" python3 -c "
from PIL import Image
import sys
im=Image.open('$ROOT/Resources/AppIcon-1024.png').convert('RGB')
w,h=im.size
pts=[im.getpixel((int(w*x),int(h*y))) for x in (.15,.35,.5,.65,.85) for y in (.15,.35,.5,.65,.85)]
sys.exit(0 if sum(1 for c in pts if max(c)-min(c)>18)>=5 else 1)"
check "icns 可反向解出全部尺寸" bash -c "rm -rf /tmp/shulang-verify.iconset && iconutil -c iconset '$APP/Contents/Resources/AppIcon.icns' -o /tmp/shulang-verify.iconset >/dev/null 2>&1 && test \$(ls /tmp/shulang-verify.iconset/*.png | wc -l | tr -d ' ') -ge 10"
check "图标无生成水印文字" bash -c "! grep -rq 'WORKBUDDY' '$ROOT/Resources/AppIcon-1024.png'"

echo "== 4. 构建产物与签名 =="
check "bundle 结构完整" bash -c "test -f '$APP/Contents/PkgInfo' && test -x '$APP/Contents/MacOS/Shulang' && test -f '$APP/Contents/Info.plist'"
check "ad-hoc 签名有效" codesign --verify --deep --strict "$APP"
check "SHA-256 清单存在" test -s "$ROOT/build/SHA256SUMS.txt"
check "清单覆盖 4 个产物" bash -c "test \$(wc -l < '$ROOT/build/SHA256SUMS.txt' | tr -d ' ') -eq 4"
check "构建脚本可执行" test -x "$ROOT/Scripts/build-app.sh"
check "SPDX 2.3 SBOM 有效" python3 -c "
import json,sys
d=json.load(open('$ROOT/build/SBOM.spdx.json'))
sys.exit(0 if d.get('spdxVersion')=='SPDX-2.3' and len(d.get('files',[]))>=15 else 1)"
check "SBOM 覆盖全部 Swift 源码" python3 -c "
import json,glob,sys
d=json.load(open('$ROOT/build/SBOM.spdx.json'))
listed={f['fileName'][2:] for f in d['files']}
src={p.replace('$ROOT/','') for p in glob.glob('$ROOT/Sources/**/*.swift',recursive=True)}
sys.exit(0 if src <= listed else 1)"
check "性能基准结果存在" test -s "$ROOT/build/BENCHMARK.json"
check "基准显示两种枚举器均完成 3 次" python3 -c "
import json,sys
d=json.load(open('$ROOT/build/BENCHMARK.json'))
e=d['enumerators']
sys.exit(0 if all(len(e[k]['runs_seconds'])==3 for k in ('foundation','bulk')) else 1)"
check "批量枚举器快于 Foundation" python3 -c "
import json,sys
d=json.load(open('$ROOT/build/BENCHMARK.json'))['enumerators']
sys.exit(0 if d['bulk']['p50_seconds'] < d['foundation']['p50_seconds'] else 1)"
check "图标脚本可复跑" python3 "$ROOT/Scripts/make-icon.py"

echo "== 5. 功能链路（合成 fixture） =="
FIX=/tmp/shulang-verify-fixture
rm -rf "$FIX"; mkdir -p "$FIX"/{Library/Caches,Duplicates}
python3 - <<'PY'
from pathlib import Path
import os
r=Path("/tmp/shulang-verify-fixture")
(r/"Library/Caches/demo-cache.bin").write_bytes(b"x"*40960)
p=b"same-content\n"*100
(r/"Duplicates/a.txt").write_bytes(p); (r/"Duplicates/b.txt").write_bytes(p)
(r/"Duplicates/c.txt").write_bytes(p+b"diff")
(r/"old.dmg").write_bytes(b"0"*20480)
os.symlink(r/"Duplicates/a.txt", r/"link-a")
PY
check "CLI version" "$CLI" version
check "CLI volumes" "$CLI" volumes
check "CLI fda" "$CLI" fda
check "Foundation 扫描" "$CLI" scan "$FIX" --enumerator foundation
check "getattrlistbulk 扫描" "$CLI" scan "$FIX" --enumerator bulk
check "两种枚举器结果一致" bash -c "
  a=\$('$CLI' scan '$FIX' --enumerator foundation | head -1);
  b=\$('$CLI' scan '$FIX' --enumerator bulk | head -1);
  test \"\$a\" = \"\$b\""
check "重复文件检测" "$CLI" duplicates "$FIX"
check "候选清单" "$CLI" candidates "$FIX"
check "Markdown 报告导出" "$CLI" candidates "$FIX" --markdown /tmp/shulang-verify-report.md
check "报告含口径说明" bash -c "grep -q '不等于立即可释放空间' /tmp/shulang-verify-report.md"
check "规则导出" "$CLI" rules export /tmp/shulang-verify-rules.json
check "规则导入校验" "$CLI" rules import /tmp/shulang-verify-rules.json
check "非法规则被拒绝" bash -c "printf 'not json' > /tmp/shulang-verify-bad.json && ! '$CLI' rules import /tmp/shulang-verify-bad.json >/dev/null 2>&1"
check "benchmark 双枚举器" "$CLI" benchmark "$FIX"

echo "== 6. 安装准备 =="
check "已安装到 /Applications" test -d "$INSTALLED"
check "已安装版本签名有效" codesign --verify --deep --strict "$INSTALLED"
check "已安装版本图标存在" test -s "$INSTALLED/Contents/Resources/AppIcon.icns"
check "已安装版本为 universal2" bash -c "lipo -info '$INSTALLED/Contents/MacOS/Shulang' | grep -q arm64"
check "计划实现情况文档存在" bash -c "grep -q '计划实现情况' '$ROOT/docs/ROADMAP.md'"
check "许可证与治理文件齐备" bash -c "for f in LICENSE NOTICE CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CONTRIBUTING_RULES.md CHANGELOG.md docs/ARCHITECTURE.md docs/THREAT_MODEL.md docs/OPEN_SOURCE_AUDIT.md docs/RELEASE.md .github/workflows/ci.yml Scripts/audit-licenses.sh Scripts/generate-sbom.py Scripts/benchmark.py; do test -s '$ROOT/'\$f || exit 1; done"

echo "== 7. P0-A 回归门禁 =="
check "许可证审计通过" "$ROOT/Scripts/audit-licenses.sh"
check "SBOM 生成确定性（不改动正式产物）" bash -c "
  python3 '$ROOT/Scripts/generate-sbom.py' /tmp/shulang-sbom-a.json >/dev/null &&
  python3 '$ROOT/Scripts/generate-sbom.py' /tmp/shulang-sbom-b.json >/dev/null &&
  cmp -s /tmp/shulang-sbom-a.json /tmp/shulang-sbom-b.json"
check "SBOM 不含运行时时间戳" bash -c "! grep -qE 'now[[:space:]]*=[[:space:]]*datetime\.now\(' '$ROOT/Scripts/generate-sbom.py'"
check "SHA-256 清单可校验" shasum -a 256 -c "$ROOT/build/SHA256SUMS.txt"
check "废纸篁不再作为 Safe 规则" bash -c "! grep -q '\*/.Trash/\*' '$ROOT/Sources/ShulangCore/Rules.swift'"
check "引擎层保护废纸篁" bash -c "grep -q '/.Trash/' '$ROOT/Sources/ShulangCore/Rules.swift'"
check "废纸篁分类不产生清理规则" bash -c "grep -q 'guard.trash' '$ROOT/Sources/ShulangCore/Analysis.swift'"
check "撤销栈重启可恢复" bash -c "grep -q '_records = decoded.records' '$ROOT/Sources/ShulangCore/Operations.swift'"
check "DeleteItem 含校验和与卷标识" bash -c "grep -q 'preDeleteChecksum' '$ROOT/Sources/ShulangCore/Models.swift' && grep -q 'volumeID' '$ROOT/Sources/ShulangCore/Models.swift'"
check "ToastCenter 票据逻辑存在" test -f "$ROOT/Sources/ShulangCore/ToastCenter.swift"
check "视图不再自带 toast 定时任务" bash -c "! grep -q 'Task.sleep(nanoseconds: 5_000_000_000)' '$ROOT/Sources/Shulang/ContentView.swift'"
check "分类色不使用 hashValue" bash -c "! grep -qE 'palette\[.*hashValue' '$ROOT/Sources/Shulang/DesignSystem.swift'"
check "隐藏目录废纸篁冒烟" "$ROOT/Scripts/smoke-trash.sh"
check "P0-A 回归测试存在" bash -c "for t in testTrashNeverProducesCleanupCandidate testUndoSurvivesRestart testLegacyHistoryRestoresRecords testToastCenterOldTicketCannotDismissNewMessage; do grep -q "\$t" '$ROOT/Tests/ShulangCoreTests/ShulangCoreTests.swift' || exit 1; done"

echo "== 8. 易用性回归门禁 =="
check "导航含清理清单与空间地图" bash -c "grep -q 'cleanup' '$ROOT/Sources/Shulang/AppState.swift' && grep -q 'struct CleanupListView' '$ROOT/Sources/Shulang/Views/ResultsView.swift' && grep -q 'struct SpaceMapView' '$ROOT/Sources/Shulang/Views/ResultsView.swift'"
check "批量选择入口存在" bash -c "grep -q 'selectAllVisible' '$ROOT/Sources/Shulang/AppState.swift' && grep -q 'invertVisibleSelection' '$ROOT/Sources/Shulang/AppState.swift'"
check "候选列表可预览" bash -c "grep -q 'state.preview(candidate)' '$ROOT/Sources/Shulang/Views/ResultsView.swift' && grep -q '预览选中' '$ROOT/Sources/Shulang/Views/ResultsView.swift'"
check "检查器随候选聚焦" bash -c "grep -q 'focusedCandidate' '$ROOT/Sources/Shulang/Views/ResultsView.swift' && grep -q 'selectedCandidateID' '$ROOT/Sources/Shulang/AppState.swift'"
check "清理后刷新容量与树" bash -c "grep -q 'removeCleaned' '$ROOT/Sources/Shulang/AppState.swift' && grep -q 'lastFreedBytes' '$ROOT/Sources/Shulang/AppState.swift'"
check "默认扫描主目录" bash -c "grep -q 'scanURL = URL(fileURLWithPath: NSHomeDirectory()' '$ROOT/Sources/Shulang/AppState.swift'"
check "卸载残留按 bundle id 反查" bash -c "grep -q 'installedIdentifiers' '$ROOT/Sources/ShulangCore/Analysis.swift' && grep -q 'knownSuffixes' '$ROOT/Sources/ShulangCore/Analysis.swift'"
check "引导含真实动作" bash -c "grep -q 'state.pickFolder()' '$ROOT/Sources/Shulang/Views/ConfigViews.swift' && grep -q 'startQuickStart' '$ROOT/Sources/Shulang/Views/ConfigViews.swift'"
check "旧页面路由已清理" bash -c "! grep -q 'case results' '$ROOT/Sources/Shulang/AppState.swift' && ! grep -q 'runDuplicates' '$ROOT/Sources/Shulang/AppState.swift' && ! grep -q 'loadLeftovers' '$ROOT/Sources/Shulang/AppState.swift'"
check "候选列表不再截断 40 项" bash -c "! grep -q 'prefix(40)' '$ROOT/Sources/Shulang/Views/CleanupViews.swift'"
check "确认页支持逐项移除" bash -c "grep -q 'state.unselect(item)' '$ROOT/Sources/Shulang/Views/CleanupViews.swift'"

echo "== 9. 计量与性能门禁 =="
check "整卷扫描跳过重复挂载视图" bash -c "grep -q 'enum ScanSkipPolicy' '$ROOT/Sources/ShulangCore/Scanner.swift' && grep -q 'ScanSkipPolicy.shouldSkip' '$ROOT/Sources/ShulangCore/Scanner.swift'"
check "聚合尺寸为一次计算" bash -c "grep -q 'recomputeAggregates' '$ROOT/Sources/ShulangCore/Scanner.swift' && ! grep -q 'children.reduce(0) { \$0 + \$1.effectiveSize }' '$ROOT/Sources/ShulangCore/Models.swift'"
check "候选过滤已缓存" bash -c "grep -q 'private(set) var visibleCandidates' '$ROOT/Sources/Shulang/AppState.swift' && grep -q 'candidateTotalBytes' '$ROOT/Sources/Shulang/AppState.swift'"
check "树图布局按 key 缓存" bash -c "grep -q 'cacheKey' '$ROOT/Sources/Shulang/Views/ChartsView.swift' && grep -q 'task(id:' '$ROOT/Sources/Shulang/Views/ChartsView.swift'"
check "文件列表按 key 缓存" bash -c "grep -q 'cacheKey' '$ROOT/Sources/Shulang/Views/ResultsView.swift'"
check "界面以实际占用为主" bash -c "grep -q 'scannedAllocatedBytes' '$ROOT/Sources/Shulang/ContentView.swift' && grep -q '实际占用' '$ROOT/Sources/Shulang/Views/OverviewView.swift'"
check "扫描边界与聚合测试存在" bash -c "grep -q 'testScanSkipPolicyProtectsVolumeBoundaries' '$ROOT/Tests/ShulangCoreTests/ShulangCoreTests.swift' && grep -q 'testNodeAggregatesAreCached' '$ROOT/Tests/ShulangCoreTests/ShulangCoreTests.swift'"

echo
echo "==================== 自检结果 ===================="
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "结论：全部检查通过，应用可交付与体验。"
else
  echo "结论：存在未通过项，需修复后重跑。"
  exit 1
fi
