import Foundation
import CryptoKit

// MARK: - 分类引擎

public enum CategoryEngine {
    public static func classify(_ root: ScanNode) {
        func visit(_ node: ScanNode) {
            if !node.isDirectoryLike {
                let (category, ruleID) = classify(path: node.url.path, size: node.logicalSize)
                node.category = category
                node.sourceRule = ruleID
            }
            for child in node.children { visit(child) }
        }
        visit(root)
    }

    /// 确定性纯函数：给定路径与大小返回分类与来源规则 id。
    public static func classify(path: String, size: Int64) -> (CategoryKind, String?) {
        if PathGuard.isProtected(path: path) { return (.protected, "guard.protected") }
        // 废纸篓显示为受保护，不映射到任何可清理规则（P0-A1）。
        if path.contains("/.Trash/") { return (.protected, "guard.trash") }
        if path.contains("/Library/Developer/Xcode/") || path.contains("/.cargo/") ||
           path.contains("/.npm/") || path.contains("/node_modules/") ||
           path.contains("/.gradle/") || path.contains("DerivedData") { return (.developer, "dev.xcode") }
        if path.contains("/Library/Caches/") || path.contains("/Caches/") { return (.caches, "cache.user") }
        if path.contains("/Library/Logs/") || path.contains("/DiagnosticReports/") ||
           path.hasSuffix(".log") { return (.logs, "log.user") }
        if path.contains("/Downloads/") {
            return (size > 100 * 1024 * 1024 ? .largeFiles : .downloads, "download.old")
        }
        if path.hasSuffix(".app") || path.contains(".app/Contents/") { return (.applications, nil) }
        if size >= 500 * 1024 * 1024 { return (.largeFiles, "large.old") }
        if path.contains("/Library/Mail/") || path.contains("/Library/Messages/") { return (.mediaMail, nil) }
        return (.other, nil)
    }
}

// MARK: - 风险与可解释候选（M4-01 / M4-08）

public enum RiskEngine {
    public static func makeCandidates(root: ScanNode, rules: RuleSet = .builtin,
                                     now: Date = Date()) -> [Candidate] {
        let enabled = rules.enabledRules()
        var result: [Candidate] = []
        for file in root.flattenedFiles() {
            guard !file.isProtected, !file.isInaccessible, !file.url.path.lowercased().contains(".app/") else { continue }
            let path = file.url.path
            let ageDays = file.modificationDate.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) } ?? 0
            guard let rule = enabled.first(where: { $0.matches(path: path, size: file.logicalSize, ageDays: ageDays) }) else {
                continue
            }
            let confidence = confidence(for: rule, ageDays: ageDays, size: file.logicalSize)
            result.append(Candidate(
                nodeID: file.id, path: path, displayName: file.name,
                ruleID: rule.id,
                evidence: "规则 \(rule.title) · 路径命中 · 大小 \(ByteFormat.string(file.logicalSize)) · 最近修改 \(ageDays) 天前",
                confidence: confidence, risk: rule.risk, consequence: rule.consequence,
                rebuildable: rule.rebuildable, recoverable: true,
                logicalSize: file.logicalSize, category: rule.category,
                scannedIdentity: file.identity, scannedModificationDate: file.modificationDate, verifiedRule: rule.isBuiltin,
                scannedChangeDate: file.changeDate
            ))
        }
        return result.sorted { $0.logicalSize > $1.logicalSize }
    }

    /// 确定性评分：安全类命中给高置信度，需人工复核的长龄/大文件给中等置信度。
    public static func confidence(for rule: Rule, ageDays: Int, size: Int64) -> Double {
        var score = 0.55
        if rule.rebuildable { score += 0.2 }
        if rule.risk == .safe { score += 0.15 }
        if ageDays >= rule.minAgeDays && rule.minAgeDays > 0 { score += 0.07 }
        if size > rule.minSizeBytes && rule.minSizeBytes > 0 { score += 0.03 }
        return min(0.98, score)
    }

    public static func summary(_ candidates: [Candidate]) -> (safe: Int64, review: Int64, caution: Int64) {
        var s: Int64 = 0, r: Int64 = 0, c: Int64 = 0
        for item in candidates {
            switch item.risk { case .safe: s += item.logicalSize; case .review: r += item.logicalSize; case .caution: c += item.logicalSize }
        }
        return (s, r, c)
    }
}

// MARK: - 三段式重复文件检测（M1-09）

public enum DuplicateEngine {
    private static let partialLength = 4096

    public static func find(root: ScanNode,
                            onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                            shouldContinue: @escaping @Sendable () -> Bool = { true }) -> [DuplicateGroup] {
        let files = root.flattenedFiles().filter { $0.kind == .file && $0.logicalSize > 0 && !$0.isProtected }
        // Pass 1：按逻辑大小分组，淘汰绝大多数候选。
        var bySize: [Int64: [ScanNode]] = [:]
        for file in files { bySize[file.logicalSize, default: []].append(file) }
        let sizeCandidates = bySize.filter { $0.value.count > 1 }
        let totalWork = sizeCandidates.values.reduce(0) { $0 + $1.count }
        var processed = 0

        // Pass 2：首 4 KiB 部分 SHA-256。
        var byPartial: [String: [ScanNode]] = [:]
        for group in sizeCandidates.values {
            for file in group {
                guard shouldContinue() else { return [] }
                processed += 1
                if processed % 200 == 0 { onProgress(processed, totalWork) }
                guard let digest = partialHash(file.url) else { continue }
                byPartial["\(file.logicalSize):\(digest)", default: []].append(file)
            }
        }

        // Pass 3：完整增量 SHA-256，字节完全一致才成组。
        var groups: [DuplicateGroup] = []
        for partial in byPartial.values where partial.count > 1 {
            var byFull: [String: [ScanNode]] = [:]
            for file in partial {
                guard shouldContinue() else { return [] }
                guard let digest = fullHash(file.url, shouldContinue: shouldContinue) else { continue }
                byFull[digest, default: []].append(file)
            }
            for (digest, members) in byFull where members.count > 1 {
                guard let first = members.first else { continue }
                let verified = [first] + members.dropFirst().filter { shouldContinue() && filesEqual(first.url, $0.url, shouldContinue: shouldContinue) }
                guard shouldContinue(), verified.count > 1 else { continue }
                let candidates = verified.map {
                    DuplicateCandidate(nodeID: $0.id, url: $0.url,
                                       logicalSize: $0.logicalSize,
                                       modificationDate: $0.modificationDate, identity: $0.identity, changeDate: $0.changeDate)
                }
                let keepIndex = candidates.enumerated().min { lhs, rhs in
                    let l = lhs.element.modificationDate ?? .distantFuture
                    let r = rhs.element.modificationDate ?? .distantFuture
                    return l < r
                }?.offset ?? 0
                groups.append(DuplicateGroup(digest: digest, candidates: candidates,
                                             recommendedKeepIndex: keepIndex))
            }
        }
        onProgress(totalWork, totalWork)
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    public static func filesEqual(_ a: URL, _ b: URL, shouldContinue: () -> Bool = { true }) -> Bool {
        guard let first = try? FileHandle(forReadingFrom: a), let second = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? first.close(); try? second.close() }
        var firstBefore = stat(), secondBefore = stat()
        guard fstat(first.fileDescriptor, &firstBefore) == 0, fstat(second.fileDescriptor, &secondBefore) == 0 else { return false }
        func unchanged(_ handle: FileHandle, _ url: URL, _ before: stat) -> Bool {
            var after = stat(), current = stat()
            return fstat(handle.fileDescriptor, &after) == 0 && lstat(url.path, &current) == 0 &&
                before.st_dev == current.st_dev && before.st_ino == current.st_ino &&
                before.st_size == after.st_size &&
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
                before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        }
        do {
            while true {
                guard shouldContinue() else { return false }
                let left = try first.read(upToCount: 256 * 1024) ?? Data()
                let right = try second.read(upToCount: 256 * 1024) ?? Data()
                if left != right { return false }
                if left.isEmpty { return unchanged(first, a, firstBefore) && unchanged(second, b, secondBefore) }
            }
        } catch { return false }
    }

    public static func partialHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: partialLength), !data.isEmpty else { return nil }
        return SHA256.hash(data: data).hexString
    }

    public static func fullHash(_ url: URL, shouldContinue: () -> Bool = { true }) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0 else { return nil }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                guard shouldContinue() else { return nil }
                hasher.update(data: chunk)
            }
            var after = stat()
            var current = stat()
            guard fstat(handle.fileDescriptor, &after) == 0, lstat(url.path, &current) == 0,
                  before.st_dev == current.st_dev, before.st_ino == current.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
            return hasher.finalize().hexString
        } catch { return nil }
    }
}

extension Digest {
    fileprivate var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - 卸载残留（M2-09）

public struct LeftoverItem: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let displayName: String
    public let ownerHint: String
    public let estimatedBytes: Int64
    public let reason: String
    /// 识别出的 bundle id；nil 表示仅按目录名推测。
    public let bundleID: String?
    /// 历史兼容字段，不代表经过校准的准确率。
    public let confidence: Double
    /// 判断依据，UI 直接展示，避免「它凭什么说是残留」。
    public let evidence: String
    public let identity: FileIdentity?
    public let modificationDate: Date?
    public let directoryFingerprint: String?
    public let changeDate: Date?

    public init(path: String, displayName: String, ownerHint: String, estimatedBytes: Int64,
                reason: String, bundleID: String? = nil, confidence: Double = 0.55,
                evidence: String = "", identity: FileIdentity? = nil, modificationDate: Date? = nil,
                directoryFingerprint: String? = nil, changeDate: Date? = nil) {
        self.identity = identity; self.modificationDate = modificationDate
        self.directoryFingerprint = directoryFingerprint
        self.changeDate = changeDate
        self.path = path; self.displayName = displayName; self.ownerHint = ownerHint
        self.estimatedBytes = estimatedBytes; self.reason = reason
        self.bundleID = bundleID; self.confidence = confidence; self.evidence = evidence
    }
}

public struct InstalledApplication: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let isSystem: Bool
}

public enum UninstallEngine {
    /// 不用 Group Containers：组标识与 app bundle id 不同源，无法精确反查，容易误报。
    private static let supportDirs: [String] = [
        "Library/Application Support", "Library/Caches", "Library/Preferences",
        "Library/Containers", "Library/LaunchAgents", "Library/Logs",
        "Library/Saved Application State", "Library/HTTPStorages",
        "Library/WebKit", "Library/Cookies", "Library/Application Scripts"
    ]
    public static var appRoots: [String] {
        applicationRoots(custom: UserDefaults.standard.stringArray(forKey: "shulang.applicationRoots") ?? [])
    }

    public static func applicationRoots(custom: [String]) -> [String] {
        let standard = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications",
                        "/System/Cryptexes/App/System/Applications"]
        return standard + custom
    }
    /// 系统数据目录名，不应作为第三方残留提示。
    private static let systemNames: Set<String> = [
        "mobilesync", "icloud", "addressbook", "calendars", "mail", "messages",
        "safari", "siri", "shortcuts", "reminders", "notes", "photos", "music"
    ]

    /// 已安装应用的 bundle id 与小写名称。bundle id 来自每个 .app 的 Info.plist，
    /// 比「目录名里含某个词」精确得多（P0-F 准确性修复）。
    public static func installedIdentifiers(roots: [String]? = nil) -> (bundleIDs: Set<String>, names: Set<String>) {
        let apps = installedApplications(roots: roots)
        return (Set(apps.compactMap { $0.bundleID?.lowercased() }), Set(apps.map { $0.name.lowercased() }))
    }

    public static func installedApplications(roots: [String]? = nil) -> [InstalledApplication] {
        var result: [InstalledApplication] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default
        for root in roots ?? appRoots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let apps = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let app as URL in apps where app.pathExtension.lowercased() == "app" {
                apps.skipDescendants()
                guard seenPaths.insert(app.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { continue }
                let name = app.deletingPathExtension().lastPathComponent
                let plist = app.appendingPathComponent("Contents/Info.plist")
                var identifier: String?
                if let data = try? Data(contentsOf: plist),
                   let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                   let dict = object as? [String: Any],
                   let bundleID = dict["CFBundleIdentifier"] as? String {
                    identifier = bundleID
                }
                result.append(InstalledApplication(path: app.path, name: name, bundleID: identifier,
                                                   isSystem: app.path.hasPrefix("/System/") || identifier?.lowercased().hasPrefix("com.apple.") == true))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 只读发现：在已配置的应用目录中未找到匹配宿主的数据，仍需人工核对。
    public static func findLeftovers() -> [LeftoverItem] {
        let home = NSHomeDirectory()
        let installed = installedIdentifiers()
        var result: [LeftoverItem] = []
        let fm = FileManager.default
        for relative in supportDirs {
            let dir = (home as NSString).appendingPathComponent(relative)
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                let path = (dir as NSString).appendingPathComponent(entry)
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
                let identity = FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: UInt64(st.st_ino))
                let modificationDate = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
                let changeDate = Date(timeIntervalSince1970: Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1_000_000_000)
                let lower = entry.lowercased()
                if lower.hasPrefix("com.apple") || lower.hasPrefix("group.com.apple") { continue }
                if systemNames.contains(lower) { continue }

                if let bundleID = bundleIdentifier(from: lower) {
                    // 精确路径：bundle id 已安装，或目录名匹配某个已安装 app 名，则跳过。
                    if installed.bundleIDs.contains(bundleID) { continue }
                    if installed.names.contains(where: { nameMatches(entry: lower, appName: $0) }) { continue }
                    let capture = DirectoryFingerprint.capture(path)
                    result.append(LeftoverItem(
                        path: path, displayName: displayName(from: entry), ownerHint: bundleID,
                        estimatedBytes: capture?.logicalBytes ?? 0,
                        reason: "常见位置未找到对应应用，可能是残留",
                        bundleID: bundleID, confidence: 0.85,
                        evidence: "在 \(relative) 找到 \(entry)；按 bundle id「\(bundleID)」反查已配置的应用目录，未找到仍安装的应用。", identity: identity, modificationDate: modificationDate, directoryFingerprint: capture?.digest, changeDate: changeDate
                    ))
                } else {
                    // 名称路径：无法精确反查，只在明显不匹配已安装 app 时以较低置信度提示。
                    guard lower.count >= 5 else { continue }
                    if installed.names.contains(where: { nameMatches(entry: lower, appName: $0) }) { continue }
                    let capture = DirectoryFingerprint.capture(path)
                    result.append(LeftoverItem(
                        path: path, displayName: entry, ownerHint: entry,
                        estimatedBytes: capture?.logicalBytes ?? 0,
                        reason: "按名称未找到对应已安装应用，可能是残留",
                        bundleID: nil, confidence: 0.55,
                        evidence: "目录名「\(entry)」不是标准 bundle id，只能按应用名比对；未匹配到仍安装的同名应用，请人工确认。", identity: identity, modificationDate: modificationDate, directoryFingerprint: capture?.digest, changeDate: changeDate
                    ))
                }
            }
        }
        return result.sorted { $0.estimatedBytes > $1.estimatedBytes }
    }

    /// 已知的非 bundle 后缀；只有这些才需要剥掉，避免把 `com.example.app` 的 `.app` 误当扩展名。
    private static let knownSuffixes: Set<String> = ["savedstate", "plist", "binarycookies", "db", "sqlite"]

    static func bundleIdentifier(from name: String) -> String? {  // internal：供单测覆盖
        var lower = name.lowercased()
        var parts = lower.split(separator: ".")
        if let last = parts.last, knownSuffixes.contains(String(last)), parts.count > 3 {
            lower = parts.dropLast().joined(separator: ".")
            parts = lower.split(separator: ".")
        }
        return parts.count >= 3 ? lower : nil
    }

    static func nameMatches(entry: String, appName: String) -> Bool {  // internal：供单测覆盖
        guard appName.count >= 4 else { return false }
        if entry == appName { return true }
        if entry.hasPrefix(appName + ".") || entry.hasSuffix("." + appName) { return true }
        if entry.contains("." + appName + ".") { return true }
        // "Google Chrome" 与 com.google.chrome：去掉点与空格后做包含匹配。
        let compactEntry = entry.replacingOccurrences(of: ".", with: "")
        let compactName = appName.replacingOccurrences(of: " ", with: "")
        return compactName.count >= 4 && compactEntry.contains(compactName)
    }

    private static func displayName(from entry: String) -> String {
        let parts = entry.split(separator: ".")
        if parts.count >= 3 { return parts.suffix(2).joined(separator: ".") }
        return entry
    }

}
