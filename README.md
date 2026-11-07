# 疏朗 Shulang

简体中文 | [English](README_EN.md)

[![CI](https://github.com/cgc1965565186-lab/Shulang/actions/workflows/ci.yml/badge.svg)](https://github.com/cgc1965565186-lab/Shulang/actions/workflows/ci.yml)

**看清空间，安心释放。** 一款开源、不上架 App Store 的 macOS 原生磁盘清理应用。

疏朗只做两件事：把磁盘空间讲清楚，以及把清理做成可复核、可撤销的事务。它不承诺「提速」，不做内存释放、进程杀除、系统参数修改，也不诱导关闭 SIP 或 Gatekeeper。

> 当前版本为 1.0.5。完整应用卸载、全面界面与无障碍验收、正式签名和公证尚未完成；清理前请逐项核对，恢复还受废纸篓状态和路径冲突影响。

- 应用名 / Dock 名 / 界面：**疏朗**
- 工程名 / 模块名：**Shulang** / `ShulangCore`
- Bundle ID：`app.shulang.macos`
- 命令行工具：`shulang`
- 图标：深青蓝渐变上的单块磨砂玻璃透镜，写实质感，由图像模型生成素材后程序化去水印并转成标准 `icns`

> 名称映射：前序调研与开发计划文档中的 `MacCleaner` 是早期占位名，实际交付物以本处的「疏朗 / Shulang / app.shulang.macos」为准。

## 快速开始

已安装版本：打开 **访达 → 应用程序 → 疏朗**，或直接运行

```bash
open -a "/Applications/疏朗.app"
```

从源码构建（需要 Xcode 27 / Swift 6.4+，macOS 14+ 部署目标）：

```bash
git clone https://github.com/cgc1965565186-lab/Shulang.git && cd Shulang
./Scripts/build-app.sh           # 测试 → universal2 release 编译 → 组装 → ad-hoc 签名
open -a "build/疏朗.app"
```

构建脚本产出：

| 产物 | 说明 |
|---|---|
| `build/疏朗.app` | 可直接双击启动的 macOS 应用（universal2：arm64 + x86_64） |
| `build/shulang` | 命令行工具，与 GUI 共用 `ShulangCore` |
| `build/SHA256SUMS.txt` | 主程序、图标、CLI 的 SHA-256 校验和 |

## 功能

**扫描与分析**
- `FileManager.DirectoryEnumerator` 预取元数据为默认基线；`getattrlistbulk(2)` 批量枚举器（64 KiB 缓冲、严格边界校验、不支持时自动回落）作为可选高性能路径
- 逻辑大小与已分配空间估算双口径；APFS 克隆等共享数据可能使逐文件汇总不同于唯一物理占用或可释放空间。整卷扫描跳过 APFS 重复挂载视图（`/System/Volumes/*`）与 swap
- APFS 硬链接按 (device, inode) 只计一次；符号链接不递归；稀疏文件不虚增
- 协作式取消与暂停（暂停不丢已扫描节点）、流式进度、不可读目录跳过并记入报告
- 矩形树图、旭日图、文件列表三种视图共享同一棵扫描树，切换零重扫；容量环是独立的卷使用率视图；小于阈值的项合并为「小文件簇」
- 三段式重复检测：按大小 → 首 4 KiB 部分 SHA-256 → 完整增量 SHA-256，再逐字节比较；执行前复核用户选择的保留项
- 12 条内置清理规则（其中开发者相关 5 条：Xcode、Homebrew、Node、Cargo、Docker），可开关、导入导出，导入时校验 id 唯一性与不安全字符。计划中的「12 类开发者规则包」尚未落地，见迭代计划 P1-04
- 疑似残留发现：在标准及用户添加的应用目录中按 bundle id 或名称查找宿主，结果需人工核对；完整应用卸载尚未接入
- 扫描快照支持同范围、同覆盖条件下比较新增 / 删除 / 增长 / 缩小及可确认的重命名；变化目录更新基于 FSEvents，无法保证可靠覆盖时退回完整扫描
- 清理清单支持批量选择与清空；每项可快速查看；清理后刷新容量，只移除实际移入废纸篓的项目

**安全与可解释**
- 候选项展示规则、命中证据、风险、删除后果和可恢复性；残留判断不使用未经校准的准确率数字
- 默认零勾选；谨慎项和未验证的导入规则不进入批量自动选择
- 引擎层路径拒绝清单：系统目录、宽泛主目录、云盘与 File Provider、凭据存储、签名应用内部、不安全符号链接；绕过界面构造 `DeletePlan` 也会被拦截
- 删除事务：预演 → 二次确认 → 写前日志 → 逐项身份复核 → 移入废纸篓 → 记录结果；可在历史记录中尝试恢复，冲突和无法验证的记录需人工处理
- 废纸篁内容在引擎层受保护：绝不作为安全候选，也不进入自动选择
- 首版不提供永久删除；失败项逐条记录，计划字节与实际移入量分开对账
- 报告可导出 Markdown / JSON，全部本地生成；默认零网络请求、无账号、无遥测

**权限（开源、非沙盒）**
- 不启用 App Sandbox，但仍遵守 TCC、完全磁盘访问（FDA）、Gatekeeper 与代码签名
- FDA 为可选增强：拒绝后完整降级到默认可读范围，未扫描区域明确标记，绝不显示「已扫描」
- 不读写 TCC 数据库，不调用 `tccutil`，不请求 root 之外的越权操作

## 命令行

```bash
shulang volumes                                   # 已挂载卷
shulang fda                                       # 完全磁盘访问状态
shulang scan ~/Downloads --enumerator bulk --json report.json
shulang scan ~/Downloads --snapshot-out snapshot.json
shulang diff ~/Downloads --snapshot snapshot.json
shulang duplicates ~/Downloads
shulang candidates ~/Downloads --markdown report.md
shulang candidates ~/Downloads --include-risky    # 风险项默认隐藏
shulang rules export rules.json | rules import rules.json
shulang benchmark ~/Downloads                     # 对比两种枚举器
```

退出码：`0` 成功、`1` 参数错误、`2` 扫描失败、`3` 路径/权限拒绝、`4` 导出失败、`5` 规则校验失败。

## 工程结构

```
Sources/ShulangCore/     Models · FileSystem · Scanner · Analysis · Rules · Layout · Operations
Sources/Shulang/         SwiftUI 界面（三栏、检查器、设置、引导）与 AppState
Sources/ShulangCLI/      命令行入口
Tests/ShulangCoreTests/  确定性纯函数与行为测试
Resources/               图标源图、iconset、icns
Scripts/                 build-app.sh · make-icon.py · verify-app.sh
docs/                    ROADMAP.md · ARCHITECTURE.md · OPEN_SOURCE_AUDIT.md 等
```

`App` target 只组合模块，业务逻辑全部落在 `ShulangCore`。模型为 `Codable & Sendable` 值类型，扫描树用 class + weak parent 避免百万节点复制开销。

## 签名与分发说明

本机构建使用 **ad-hoc 签名**（`codesign -s -`），因为没有 Developer ID 证书，也未做 Apple 公证。本地构建产物不带 `com.apple.quarantine` 属性，双击即可打开；若从网络下载后系统提示「无法验证开发者」，请在「系统设置 → 隐私与安全性」中允许，或右键 → 打开。项目**不会**用脚本静默剥离 quarantine，也不会引导用户关闭 Gatekeeper。

官方发布应改用：Developer ID Application 签名 + Hardened Runtime + secure timestamp + `notarytool` 公证 + `stapler staple`，签名私钥只保存在受保护 tag 的受控 runner 中。详见 `docs/RELEASE.md`。

## 测试

```bash
swift test --disable-sandbox -j 1
./Scripts/verify-app.sh          # 工程自检；不能代替系统集成与界面验收
```

## 许可证

Apache-2.0，见 `LICENSE` 与 `NOTICE`。第三方代码引入前必须通过 `docs/OPEN_SOURCE_AUDIT.md` 的许可证审计：GPL-2.0 / AGPL-3.0 / 非商业自定义许可证 / Commons Clause 项目只作算法与交互参考，不链接、不复制源码。
