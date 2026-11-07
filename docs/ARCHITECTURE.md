# 架构

## 分层

App (SwiftUI) → AppState (@MainActor @Observable) → ShulangCore →
Scanner / Analysis / Rules / Layout / Operations → FileSystem / Darwin。

- 控制器层（Views）只呈现状态、转发动作，不含业务规则
- 服务层（AppState + ShulangCore）承载扫描、分析、删除编排
- 数据访问层（FileSystem / VolumeProvider）封装 Darwin 与 Foundation

## 关键实现

- 双轨枚举：FoundationEnumerator 为默认；BulkEnumerator 用 getattrlistbulk(2)
  + 64 KiB 缓冲按固定布局零拷贝解析，EINVAL/ENOTSUP/ENOSYS、字段缺失或
  任何边界异常都返回 nil 并回落
- 扫描树：ScanNode class + weak parent；effectiveSize 递归求和；
  flattenedFiles() 供去重、列表与报告复用
- 硬链接：linkCount > 1 且 (device, inode) 已出现时把该节点容量置零，节点仍保留
- 树图：Squarified 布局（Bruls 等，2000），小于阈值的项合并为「小文件簇」；
  旭日图按 effectiveSize 分配角度；两视图共用同一棵树
- 删除事务：BuildPlan → dryRun → MoveToTrash → Verify → AuditLog；
  每 50 项重校验路径，身份变化即中止当前批次；撤销从废纸篓移回原路径
- 路径拒绝清单：PathGuard.isProtected / allowsDeletion 在引擎层，
  后者额外检查祖先链是否含符号链接以缓解 TOCTOU

## 并发

扫描在 Task.detached 执行，进度通过 @Sendable 回调回到 @MainActor；
取消与暂停由 NSLock 保护的状态位协作完成；共享模型为不可变值快照。

## 已知取舍

- 语言模式为 Swift 5（swiftLanguageModes: [.v5]），代码按并发安全规范编写；
  Swift 6 strict concurrency 迁移列为后续项
- 扫描快照与历史用 JSON 持久化，尚未切换到计划中的 SQLite WAL
- 未实现 XPC 特权 helper；系统级删除能力保持不提供
