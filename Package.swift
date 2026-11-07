// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shulang",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShulangCore", targets: ["ShulangCore"]),
        .executable(name: "Shulang", targets: ["Shulang"]),
        // APFS 默认大小写不敏感：CLI 产物不能叫 shulang，否则会与 GUI 的 Shulang
        // 落在同一个文件名上相互覆盖。构建脚本再把它改名为用户可见的 shulang。
        .executable(name: "shulang-cli", targets: ["ShulangCLI"]),
    ],
    targets: [
        .target(name: "ShulangCore", path: "Sources/ShulangCore"),
        .executableTarget(name: "Shulang", dependencies: ["ShulangCore"], path: "Sources/Shulang"),
        .executableTarget(name: "ShulangCLI", dependencies: ["ShulangCore"], path: "Sources/ShulangCLI"),
        .testTarget(name: "ShulangCoreTests", dependencies: ["ShulangCore"], path: "Tests/ShulangCoreTests"),
    ],
    // 代码按并发安全规范编写（值类型 Sendable、actor 扫描、@MainActor UI），
    // 语言模式保持 v5 以兼容 CI 中较旧的 Xcode；Swift 6 strict concurrency 迁移见 docs/ROADMAP.md。
    swiftLanguageModes: [.v5]
)
