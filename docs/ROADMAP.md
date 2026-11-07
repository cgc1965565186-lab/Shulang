# 当前源码更新状态（2026-11-07）

本次更新仍在开发，尚未作为 1.0.4 交付或安装。原先的完成状态表是历史记录，不能代表本次实现的完整验收。

已实现：导入规则不再获得内置信任；默认扫描包含隐藏项；Foundation 扫描应用包内部文件；扫描身份与移动前校验、写前记录和每项成功后记录；失败项目留在清单；旧扫描任务不得覆盖新扫描；恢复时校验文件身份；去掉重复项 100% 的表述。

待完成：崩溃发生在系统移动文件与日志写入之间时的恢复定位；逐项结果与失败详情界面；重复项与残留的安全清理；部分扫描结果与覆盖状态；1.1 性能、1.2 增量及卸载、正式签名公证等全部阶段。缺少扫描身份的候选当前被拒绝，因此重复项和残留尚不能通过新事务清理。

本次仅运行 Swift 单元测试和隔离文件操作测试，尚未完成 GUI 实机验收、性能基准、发布构建或重新安装。

---

# 计划实现情况对照

本表逐项对应 `AGENT_PLAN.md` 的 M0–M5 任务，状态以**当前仓库与已安装产物中的实际代码/文件**为准。
「已实现」= 有可运行代码且经测试或 CLI 实测；「部分」= 有等价实现但口径简化；「未实现」= 明确留待后续。

## M0 · 工程与开源治理

| 任务 | 状态 | 证据 / 说明 |
|---|---|---|
| M0-01 单一非沙盒 App + CLI target、universal2 | 已实现 | `Package.swift`、`build-app.sh`、`lipo -info` 显示 x86_64 + arm64 |
| M0-02 编码规范、单文件行数、并发安全 | 部分 | `.swiftlint.yml` 未落地；代码按分层与 Sendable 规范编写，语言模式为 Swift 5 |
| M0-03 架构与威胁模型 | 已实现 | `docs/ARCHITECTURE.md`、`docs/THREAT_MODEL.md` |
| M0-04 公开 CI | 已实现 | `.github/workflows/ci.yml`（PR 只跑无签名构建） |
| M0-05 开源许可证审计 | 已实现 | `docs/OPEN_SOURCE_AUDIT.md`、`LICENSE`(Apache-2.0)、`NOTICE` |
| M0-06 签名与发布策略 | 已实现（文档与 ad-hoc 签名） | `docs/RELEASE.md`；Developer ID 与公证**未实现** |
| M0-07 开源治理文件 | 已实现 | `CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`、`SECURITY.md`、`CONTRIBUTING_RULES.md`、`CHANGELOG.md` |

## M1 · 扫描核心

| 任务 | 状态 | 证据 / 说明 |
|---|---|---|
| M1-01 Volume/FS 抽象 + 双口径 | 已实现 | `FileSystem.swift`：`URLResourceValues`、`lstat`、volume keys |
| M1-02 Foundation 枚举器基线 | 已实现 | `FoundationEnumerator`，预取 resource keys，不可读目录跳过 |
| M1-03 POSIX `fts` 对照基准 | 未实现 | 用 `benchmark` 对比 Foundation 与 `getattrlistbulk` 代替 |
| M1-04 容量与 purgeable | 部分 | 卷容量与 `volumeAvailableCapacityForImportantUsage` 已实现；purgeable 明细未单列 |
| M1-05 SQLite WAL / 迁移 | 未实现 | 扫描快照与历史用 `history.json` 持久化，功能等价但非 SQLite |
| M1-06 流式聚合与进度 | 已实现 | `ScanProgress` 每 2000 项回调，`AppState` 回主线程更新 |
| M1-07 取消 / 暂停 | 已实现 | `ScanEngine` 协作式状态位，暂停不丢已扫描节点 |
| M1-08 分类引擎（12 条规则） | 部分 | `CategoryEngine.classify` + `RuleSet.builtin` 12 条规则，其中开发者相关仅 5 条；计划「12 类开发者规则包」见 P1-04 |
| M1-09 三段式去重 | 已实现 | `DuplicateEngine`：size → 4 KiB → 完整增量 SHA-256 |
| M1-10 `getattrlistbulk(2)` 枚举器 | 已实现 | `BulkEnumerator`：64 KiB 缓冲、零拷贝解析、严格校验、异常回落；CLI `benchmark` 与单测验证 |
| M1-11 小文件子树聚合 | 部分 | 在布局层合并为「小文件簇」（`TreemapLayout`），未在扫描树层折叠 |

## M2 · 权限、删除与卸载

| 任务 | 状态 | 证据 / 说明 |
|---|---|---|
| M2-01 TCC / FDA 状态机 | 已实现 | `PermissionProbe.fullDiskAccess()` 只读探测，四态在 UI 呈现 |
| M2-02/03 扫描范围选择 | 已实现 | `NSOpenPanel` 仅作范围选择，无 Powerbox 与 bookmark 依赖 |
| M2-04 FDA 引导（主路径） | 已实现 | 概览页状态卡 + 系统设置 deep link + 重新检测 |
| M2-05 特权 helper | 未实现 | 不提供系统级删除能力；保持最小权限 |
| M2-06 废纸篓删除 | 已实现 | `FileManager.trashItem` + 捕获废纸篓 URL |
| M2-07 事务、身份复核与验证 | 已实现 | `DeletionEngine`：dry-run、每 50 项重校验、TOCTOU 中止、审计日志 |
| M2-08 APFS 快照 | 未实现 | 失败降级策略未涉及，因不创建快照 |
| M2-09 卸载与残留清除 | 已实现 | `UninstallEngine` 孤儿检测 + `UninstallView` 逐项加入候选 |

## M3 · 界面

| 任务 | 状态 | 证据 / 说明 |
|---|---|---|
| M3-01 设计令牌（浅/深） | 已实现 | `DesignSystem.swift`：动态颜色、4/8pt 基线、风险四色 + SF Symbol |
| M3-02 矩形树图 | 已实现 | `ChartsView.swift` Canvas 绘制、命中测试、下钻面包屑 |
| M3-03 图表与无障碍 | 部分 | 容量环、树图、旭日图与 VoiceOver 标签已实现；未做 Reduce Motion 专项适配 |
| M3-04/05 重复项、检查器、全键盘 | 已实现 | 检查器常驻证据、Quick Look、快捷键菜单、主窗口可重开 |
| M3-06 旭日图零重扫切换 | 已实现 | 与树图共享 `currentFocus`，切换不重扫 |

## M4 · 规则、差异、自动化、CLI

| 任务 | 状态 | 证据 / 说明 |
|---|---|---|
| M4-01/02 规则 Schema、导入导出、社区贡献 | 已实现 | `RuleSet.importJSON` 校验；`CONTRIBUTING_RULES.md`；规则页开关与导出 |
| M4-03/04 FSEvents 与 Spotlight 补全 | 未实现 | 采用「重新扫描 + DiffEngine 对比」代替增量失效 |
| M4-05 自动化 | 部分 | 水位提醒与「默认只通知」已实现；定时/登录项未实现 |
| M4-06 CLI | 已实现 | `shulang` 8 个子命令、稳定退出码、dry-run 默认、风险项默认隐藏 |
| M4-07 清理效果反馈（再生率） | 部分 | `RegrowthTracker` 记录与回长率计算、检查器展示；未做 1/7 天后台复测调度 |
| M4-08 三级风险与路径拒绝清单 | 已实现 | `RiskEngine` + `PathGuard`，引擎层生效，单测覆盖 |
| M4-09 Changes / diff 视图 | 已实现 | `DiffEngine` 五类变更（renamed 由 added+deleted 表达），历史页展示 |
| M4-10 开发者规则包 | 已实现 | 12 条内置规则覆盖 Xcode / Brew / npm / pnpm / Yarn / Bun / Cargo / pip / Docker / 模拟器 |

## M5 · 质量与发布

| 任务 | 状态 | 证据 / 说明 |
|---|---|---|
| M5-01/02 单测与 golden deletion | 部分 | 20 个 XCTest 全绿（含路径拒绝、dry-run 不写盘、树图面积、回落、diff）；未建 10 场景 golden deletion 全量夹具 |
| M5-03 性能基准 | 已实现（缩尺） | `Scripts/benchmark.py` 生成 6000 文件 fixture、两种枚举器各跑 3 次，输出 `build/BENCHMARK.json`；未做百万文件规模 |
| M5-04/05 安全 / 无障碍 / UI 测试 | 部分 | 安全边界单测与 VoiceOver 标签已实现；无自动化 UI 测试与「已知源码绕过」专项用例 |
| M5-06/07 签名与 Release | 部分 | ad-hoc 签名、`codesign --verify` 通过、SHA-256 清单；Developer ID 公证、GitHub Release、Homebrew Cask 未实现 |
| M5-08 发布供应链 | 部分 | 可复现构建脚本 + 校验和；immutable release、attestation 未实现 |
| M5-09 可复现构建与 SBOM | 部分 | 1.0.1 起 SBOM 时间确定、命名空间为内容哈希、内容不变不重写，校验和可复现；provenance / attestation 仍未生成 |

## 汇总

- **已实现**：M0 中 6/7、M1 中 7/11、M2 中 6/9、M3 中 4/5、M4 中 5/8、M5 中 1/6 完整版（另有 11 项部分实现）——按各表实际标注重数，1.0.0 版汇总曾多算 M1 与部分项
- **核心可用链路**：选择范围 → 只读扫描 → 三视图分析 → 可解释候选 → 复核 → 预演 → 废纸篓 → 恢复 / 报告，全部真实可运行
- **明确未做**：XPC helper、FSEvents 增量、SQLite WAL、APFS 快照、Developer ID 公证与完整发布供应链、CI provenance/attestation、百万文件规模基准、自动化 UI 测试
- **缩尺性能基准实测**（2026-11-05，arm64 / macOS 27.3，6000 文件 × 3 次）：Foundation P50 **1.5307 s**，`getattrlistbulk` P50 **0.5829 s**，快约 **62%**；结果见 `build/BENCHMARK.json`。按计划 M1-10 的「收益 ≥20% 才转正」判据已满足，但默认枚举器仍保持 Foundation，转正需完成符号链接 / 挂载点 / ACL 专项回归。
- **安全底线（1.0.1 校正）**：不做永久删除、不做系统优化、不诱导关闭系统安全、默认零网络、路径拒绝清单在引擎层；1.0.0 曾有废纸篁口径、撤销重启、SBOM 可复现三处违反，已在 P0-A 修复并有回归测试

以上缺口会明显影响「卡顿、易用性、功能不健全」的用户体感，已全部纳入迭代计划 P0–P2 分批补齐；计划文件见 `~/.workbuddy/plans/toasty-aurora-tesla-3kK7CgnF.md`。


## P0-A 已完成（1.0.1）

| 任务 | 状态 | 证据 |
|---|---|---|
| P0-A1 废纸篁口径 | 已实现 | `Rules.swift` PathGuard 保护 `/.Trash/`、`tmp.user` 移除该模式、`Analysis.swift` 分类为 `guard.trash`、`AppState.selectSafeOnly` 兜底；`testTrashNeverProducesCleanupCandidate` |
| P0-A2 撤销栈重启 | 已实现 | `DeleteItem.preDeleteChecksum/volumeID`、按卷分桶、`AuditLog.encodeHistory/decodeHistory` 纯函数、`loadIfNeeded` 恢复 `_records`；`testUndoSurvivesRestart`、`testLegacyHistoryRestoresRecords` |
| P0-A3 可复现构建 | 已实现 | `Scripts/generate-sbom.py` 去 `datetime.now()`、内容哈希命名空间、内容不变不重写；`verify-app.sh` 两次生成一致性检查 |
| P0-A4 toast 竞态 | 已实现 | `Sources/ShulangCore/ToastCenter.swift` 票据机制；`testToastCenterOldTicketCannotDismissNewMessage` |
| P0-A5 分类色稳定 | 已实现 | `DesignSystem.swift` 显式 switch 映射，移除 `hashValue` |
| 许可证门禁 | 已实现 | `Scripts/audit-licenses.sh`，CI 与自检均调用 |

未进入：P0-B 索引改造、P0-C 扫描管线、P0-D 状态拆分、P0-E 视图缓存、P0-F 易用性，以及全部 P1/P2 任务。


## P0-F 已完成（1.0.2，提前于 P0-B/C/D/E）

| 反馈 | 修复 | 证据 |
|---|---|---|
| 不知道怎么完整使用 | 四步引导条（选范围/扫描/复核/清理）+ 开始页单一主 CTA + 检查器「下一步做什么」 | `OverviewView.swift`、`WorkflowSteps`、`InspectorView.summaryCard` |
| 清理后不刷新容量 | `performCleanup` 成功后 `removeCleaned` + `refreshVolumes` + `lastFreedBytes` | `AppState.swift` |
| 快速开始无效 | 默认范围改主目录；`startQuickStart` 串起选范围→扫描→清理清单 | `AppState.swift`、`OverviewView.swift` |
| 卸载残留准不准 | 读 `CFBundleIdentifier` 精确反查 + 判断依据 + 置信度 | `Analysis.swift`、`UninstallView` |
| 重复项置信度 | 每组展示 SHA-256 摘要、「字节级一致 · 置信度 100%」与保留理由 | `DuplicateGroupRow` |
| 排布/接口混乱 | 导航三组 + 副标题；扫描合并为全局横幅；工具栏全部带文字 | `ContentView.swift` |
| 无法批量选择 | 全选/反选/只选安全/清空 + 已选统计 | `CleanupListView`、`AppState` |
| 没有预览 | 候选行眼睛按钮、右键菜单、检查器、确认页全量预览 | `ResultsView.swift`、`CleanupViews.swift` |
| 工具栏图标看不懂 | 全部改为文字标签 + tooltip | `MainToolbar` |
| 切页要重扫 | 扫描结果常驻；重复/残留在进入页面时按需后台计算并缓存 | `ensureDuplicates` / `ensureLeftovers` |
| 检查器空白 | 三态检查器：候选证据 / 文件详情 / 扫描摘要；点击候选即聚焦 | `InspectorView` |

仍未进入：P0-B 索引缓存、P0-C 并行扫描与真实 ETA、P0-D 状态拆分、P1/P2 全部任务。
