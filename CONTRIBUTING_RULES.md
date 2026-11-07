# 清理规则贡献指南

内置规则位于 Sources/ShulangCore/Rules.swift 的 RuleSet.builtin，也可在「规则」页导入 JSON。

| 字段 | 含义 |
|---|---|
| id | 全局唯一，小写点分，如 dev.xcode |
| title / category | 界面名称；caches / logs / temporary / downloads / developer / applications / trash / mediaMail / largeFiles / duplicates / other / protected |
| risk | safe / review / caution；caution 永不进入「全选」 |
| pathPatterns | fnmatch 模式数组；禁止 ; 与反引号、$( 等可执行字符 |
| minAgeDays / minSizeBytes | 命中下限，用于降低误报 |
| consequence | 必填，写清删除后会发生什么 |
| rebuildable | 是否自动重建，影响置信度与「只选安全项」 |
| enabled | 是否默认启用 |

审核标准：规则必须是纯数据；必须给出可复现 fixture；涉及用户数据的规则默认
risk 为 review / caution 且 enabled 为 false；通过 shulang rules import 校验；
由维护者签名后才进内置集。用户自行导入的第三方规则标记「未验证」，不参与 Safe 自动选择。
