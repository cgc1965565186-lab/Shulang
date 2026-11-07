# 开源项目审计

核查方式：2026-11-05 通过 GitHub REST API 逐仓读取元数据、LICENSE 与 README，
关键实现读取源码（Radix BulkDirectoryEnumerator.swift）。

## 可安全参考 / 可评估引入（MIT / 官方）

| 项目 | 许可证 | 参考内容 |
|---|---|---|
| colinvkim/Radix | MIT | getattrlistbulk 批量枚举、扁平树与索引、扫描对比 |
| 137137137/OpenDisk | MIT | 增量扫描、Collector 复核流程 |
| Lcharvol/MacSift | MIT | 按所属 App 分组、引擎层硬阻断、默认 dry-run |
| leibnizli/LittleClean | MIT | 卸载残留发现路径清单 |
| phalladar/MacDirStat | MIT | 树图配色与命中测试、签名交付基线 |
| guhcostan/mac-cleaner-cli | MIT | 规则分类、dry-run、风险项默认隐藏 |
| pkolaczk/fclones | MIT | 分层去重与输出格式 |
| rofl0r/ncdu / imsnif/diskonaut / inket/FullDiskAccess | MIT | 双口径术语、TUI 导航、FDA 状态 |
| Apple 官方 | — | SwiftUI、AppKit、CryptoKit、Foundation |

本项目实际依赖：无第三方 SwiftPM 依赖（仅系统框架），Package.resolved 纳入版本控制。

## 与自有 Apache-2.0 项目不兼容 / 不可复制

| 项目 | 许可证 | 结论 |
|---|---|---|
| Ratiug-99/disk-space-analyzer | 无 LICENSE | 默认保留全部权利，仅参考架构思路 |
| 18jad/spaceman / JadeSnow7/SwiftSweep | 无 LICENSE | 同上 |
| Prot10/MyMacCleaner | AGPL-3.0 | 强传染性，禁止链接或复制 |
| harry0703/MangoDisk / tkslucas/Neodisk / arsenetar/dupeguru | GPL-3.0 | 仅算法与交互参考 |
| shundhammer/qdirstat / GrandPerspective | GPL-2.0 | 与 Apache-2.0 不兼容 |
| georgekhananaev/spark-clean / AlexGladkov/Spacie | 非商业自定义 | 仅参考安全模型与文案 |
| alienator88/Pearcleaner | Apache-2.0 + Commons Clause | 禁止商业销售，仅参考路径清单 |
| sevmorris/maclean | 仓库 404 | 不可引用 |

## 门禁

CI 扫描 Package.resolved，出现上表禁用许可证即失败。任何「待验证」项结论出来前
不得有对应代码合入。若未来接受企业赞助、提供商业支持或做双授权，
非商业自定义许可证与 Commons Clause 项目的结论需重新评估。
