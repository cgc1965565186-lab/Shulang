# 参与贡献

## 构建

需要 Xcode 27 / Swift 6.4+，macOS 14+ 部署目标。

```bash
swift test --disable-sandbox -j 1
./Scripts/build-app.sh
open -a "build/疏朗.app"
```

受限执行环境中 SwiftPM 需要 --disable-sandbox；并发构建偶发
「unable to open dependencies file」，用 -j 1 规避。

## 分层约定

- Sources/ShulangCore：全部业务逻辑，不依赖 SwiftUI（Operations.swift 用 AppKit/Quartz 做系统交互）
- Sources/Shulang：只组合界面，不写扫描与删除逻辑
- Sources/ShulangCLI：命令行入口，与 GUI 共用 Core
- 模型为 Codable & Sendable 值类型；扫描树用 class + weak parent

## 提交前

1. swift test --disable-sandbox -j 1 全绿
2. ./Scripts/verify-app.sh 全绿
3. 新增规则必须补 fixture 测试，写清「删除后果」与「是否自动重建」
4. 涉及删除的改动必须保持「默认零勾选 + 引擎层拒绝清单 + 先入废纸篓」

## DCO

使用 git commit -s 添加 Signed-off-by 行。
规则包是纯 JSON 数据，禁止可执行内容，详见 CONTRIBUTING_RULES.md。
