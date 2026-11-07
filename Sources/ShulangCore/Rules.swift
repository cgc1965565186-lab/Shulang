import Foundation
import Darwin

// MARK: - 引擎层路径拒绝清单（M4-08）

/// 拒绝清单在引擎层生效，不依赖 UI 置灰。构造 DeletePlan 时亦会再次校验。
public enum PathGuard {
    private static let hardBlockedPrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/private/var", "/private/etc",
        "/Library/Apple", "/Library/Keychains", "/Network", "/dev", "/cores"
    ]
    private static let protectedHomeFragments: [String] = [
        "/Library/CloudStorage", "/Library/Mobile Documents", "/Library/Keychains",
        "/Library/Mail", "/Library/Messages", "/Library/Safari", "/Library/Accounts",
        "/Library/Cookies", "/Library/Credentials", "/Library/Group Containers/group.com.apple",
        "/Library/Application Support/com.apple.TCC"
    ]

    public static func isProtected(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return isProtected(path: path)
    }

    public static func isProtected(path: String) -> Bool {
        let home = NSHomeDirectory().lowercased()
        let path = path.lowercased()
        if path == "/" || path == home || path == "/library" || path == "/applications" { return true }
        if path.hasPrefix("/volumes/") && path.split(separator: "/").count <= 2 { return true }
        // 废纸篓内容一律不由本应用代为清理：只允许清理本应用自己放入或用户显式选择的项。
        // 该约束在引擎层生效，避免任何规则或自动选择把整个废纸篓列为可删候选（P0-A1）。
        if path.contains("/.trash/") || path.hasSuffix("/.trash") { return true }
        for raw in hardBlockedPrefixes {
            let prefix = raw.lowercased()
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        for fragment in protectedHomeFragments where path.contains(fragment.lowercased()) { return true }
        // 签名应用内部不视为普通可清理目录。
        if path.contains(".app/contents/") { return true }
        // iCloud / File Provider 数据目录。
        if path.contains("/file provider storage/") { return true }
        return false
    }

    /// 删除前的二次校验：路径仍在允许范围、不是符号链接逃逸、不是宽泛主目录。
    public static func allowsDeletion(path: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              !path.split(separator: "/").contains(".") else { return false }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if isProtected(path: path) || isProtected(path: normalized) { return false }
        let components = path.split(separator: "/")
        if components.count <= 2 { return false }
        if path == NSHomeDirectory() { return false }
        // 祖先链上出现符号链接则拒绝，避免 TOCTOU 路径替换。
        var current = ""
        for component in components.dropLast() {
            current += "/" + component
            var st = stat()
            if lstat(current, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        return true
    }
}

// MARK: - 规则模型

public struct Rule: Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var category: CategoryKind
    public var risk: RiskLevel
    public var pathPatterns: [String]
    public var minAgeDays: Int
    public var minSizeBytes: Int64
    public var consequence: String
    public var rebuildable: Bool
    public var enabled: Bool
    public var isBuiltin: Bool

    public init(id: String, title: String, category: CategoryKind, risk: RiskLevel,
                pathPatterns: [String], minAgeDays: Int = 0, minSizeBytes: Int64 = 0,
                consequence: String, rebuildable: Bool, enabled: Bool = true,
                isBuiltin: Bool = true) {
        self.id = id; self.title = title; self.category = category; self.risk = risk
        self.pathPatterns = pathPatterns; self.minAgeDays = minAgeDays
        self.minSizeBytes = minSizeBytes; self.consequence = consequence
        self.rebuildable = rebuildable; self.enabled = enabled; self.isBuiltin = isBuiltin
    }

    public func matches(path: String, size: Int64, ageDays: Int) -> Bool {
        guard enabled else { return false }
        guard size >= minSizeBytes, ageDays >= minAgeDays else { return false }
        return pathPatterns.contains { pattern in
            path.withCString { p in
                pattern.withCString { pat in fnmatch(pat, p, FNM_CASEFOLD) == 0 }
            }
        }
    }
}

public struct RuleSet: Codable, Sendable {
    public static let currentVersion = "1.0.0"
    public var version: String
    public var rules: [Rule]

    public init(version: String = RuleSet.currentVersion, rules: [Rule]) {
        self.version = version; self.rules = rules
    }

    /// 内置规则：只读发现，按工具链分组，全部标注删除后果与是否自动重建。
    public static let builtin = RuleSet(rules: [
        Rule(id: "cache.browser", title: "浏览器缓存", category: .caches, risk: .safe,
             pathPatterns: ["*/Library/Caches/Google/*", "*/Library/Caches/com.apple.Safari/*",
                            "*/Library/Caches/Firefox/*", "*/Library/Caches/com.microsoft.edgemac/*"],
             consequence: "网页资源需重新下载，不影响书签与登录态。", rebuildable: true),
        Rule(id: "log.user", title: "用户日志", category: .logs, risk: .safe,
             pathPatterns: ["*/Library/Logs/*", "*/Library/DiagnosticReports/*"],
             minAgeDays: 7, consequence: "历史诊断记录被移入废纸篓，无法再用于排错。", rebuildable: true),
        // 废纸篓内容不再作为 Safe 候选：计划要求「只清本应用放入或用户显式选择的项」，
        // 自动选择绝不代为清空整个废纸篓（P0-A1）。
        Rule(id: "tmp.user", title: "临时文件", category: .temporary, risk: .safe,
             pathPatterns: ["*/Library/Caches/TemporaryItems/*", "*/tmp/*"],
             minAgeDays: 1, consequence: "正在使用的临时目录不应删除，请确认应用已退出。", rebuildable: true),
        Rule(id: "download.old", title: "旧下载与安装包", category: .downloads, risk: .review,
             pathPatterns: ["*/Downloads/*.dmg", "*/Downloads/*.pkg", "*/Downloads/*.zip", "*/Downloads/*.iso"],
             minAgeDays: 180, consequence: "安装包移除后需重新下载。", rebuildable: false),
        Rule(id: "dev.xcode", title: "Xcode 派生数据", category: .developer, risk: .safe,
             pathPatterns: ["*/Library/Developer/Xcode/DerivedData/*", "*/Library/Developer/Xcode/iOS DeviceSupport/*"],
             consequence: "下次构建会重新索引，首次编译变慢。", rebuildable: true),
        Rule(id: "dev.brew", title: "Homebrew 缓存", category: .developer, risk: .safe,
             pathPatterns: ["*/Library/Caches/Homebrew/*", "*/Library/Caches/pip/*"],
             consequence: "再次安装时需要重新下载。", rebuildable: true),
        Rule(id: "dev.node", title: "Node / 包管理器缓存", category: .developer, risk: .safe,
             pathPatterns: ["*/.npm/*", "*/.cache/yarn/*", "*/.cache/pnpm/*", "*/.bun/install/cache/*"],
             consequence: "下次安装依赖时重新下载。", rebuildable: true),
        Rule(id: "dev.cargo", title: "Rust / Cargo 缓存", category: .developer, risk: .review,
             pathPatterns: ["*/.cargo/registry/cache/*", "*/target/debug/*"],
             consequence: "依赖源码与增量构建产物需重新获取。", rebuildable: false),
        Rule(id: "dev.docker", title: "容器构建缓存", category: .developer, risk: .review,
             pathPatterns: ["*/Library/Containers/com.docker.docker/*/build-cache/*"],
             consequence: "仅清构建缓存，不删除镜像与卷。", rebuildable: true),
        Rule(id: "large.old", title: "长期未打开的大文件", category: .largeFiles, risk: .review,
             pathPatterns: ["*/Documents/*", "*/Desktop/*", "*/Movies/*"],
             minAgeDays: 365, minSizeBytes: 500 * 1024 * 1024,
             consequence: "用户数据，删除前请预览内容。", rebuildable: false),
        Rule(id: "mail.attachments", title: "邮件附件缓存", category: .mediaMail, risk: .caution,
             pathPatterns: ["*/Library/Mail/*", "*/Library/Containers/com.apple.mail/*"],
             consequence: "可能影响离线邮件读取，需逐项确认。", rebuildable: false, enabled: false),
        Rule(id: "cache.user", title: "用户缓存", category: .caches, risk: .safe,
             pathPatterns: ["*/Library/Caches/*", "*/Library/Containers/*/Data/Library/Caches/*"],
             consequence: "应用下次启动时重新生成，可能需要重新登录个别服务。", rebuildable: true)
    ])

    public func enabledRules() -> [Rule] { rules.filter(\.enabled) }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 导入校验：版本字段、规则 id 唯一、路径模式不含可执行内容、风险等级合法。
    public static func importJSON(_ data: Data) throws -> RuleSet {
        let decoder = JSONDecoder()
        var set = try decoder.decode(RuleSet.self, from: data)
        for index in set.rules.indices {
            set.rules[index].isBuiltin = false
            if set.rules[index].risk == .safe { set.rules[index].risk = .review }
        }
        guard !set.version.isEmpty, !set.rules.isEmpty else {
            throw RuleError.invalid("规则集版本或规则列表为空")
        }
        var ids = Set<String>()
        for rule in set.rules {
            guard !rule.id.isEmpty, ids.insert(rule.id).inserted else {
                throw RuleError.invalid("规则 id 重复或为空：\(rule.id)")
            }
            guard !rule.pathPatterns.isEmpty, !rule.consequence.isEmpty else {
                throw RuleError.invalid("规则缺少路径模式或后果说明：\(rule.id)")
            }
            for pattern in rule.pathPatterns where pattern.contains(";") || pattern.contains("`") || pattern.contains("$(") {
                throw RuleError.invalid("规则包含不安全字符：\(rule.id)")
            }
        }
        return set
    }
}

public enum RuleError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let m): return m }
    }
}
